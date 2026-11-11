data "aws_caller_identity" "current" {}

locals {
  snowflake_role_name = "snowflake-landing-reader-${var.environment}"
  snowflake_role_arn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.snowflake_role_name}"
}

# ---------------------------------------------------------------- landing bucket
resource "aws_s3_bucket" "landing" {
  bucket        = var.landing_bucket_name
  force_destroy = var.force_destroy_bucket
}

resource "aws_s3_bucket_public_access_block" "landing" {
  bucket                  = aws_s3_bucket.landing.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "landing" {
  bucket = aws_s3_bucket.landing.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_kms_key" "landing" {
  description         = "Landing zone encryption (contains PII)"
  enable_key_rotation = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "landing" {
  bucket = aws_s3_bucket.landing.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.landing.arn
    }
    bucket_key_enabled = true
  }
}

# Raw files are replayable for 90 days hot, then cheaper storage, deleted after ~13 months.
# Customer (PII) files expire sooner so erased data does not linger in the lake.
resource "aws_s3_bucket_lifecycle_configuration" "landing" {
  bucket = aws_s3_bucket.landing.id

  rule {
    id     = "events-tiering"
    status = "Enabled"
    filter {
      prefix = "landing/"
    }
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    expiration {
      days = 400
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  rule {
    id     = "pii-short-retention"
    status = "Enabled"
    filter {
      prefix = "landing/customers/"
    }
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

# ---------------------------------------------------------------- IAM role for Snowflake
data "aws_iam_policy_document" "snowflake_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [snowflake_storage_integration_aws.s3_landing.describe_output[0].iam_user_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [snowflake_storage_integration_aws.s3_landing.describe_output[0].external_id]
    }
  }
}

resource "aws_iam_role" "snowflake_landing_reader" {
  name               = local.snowflake_role_name
  assume_role_policy = data.aws_iam_policy_document.snowflake_trust.json
}

data "aws_iam_policy_document" "landing_read" {
  statement {
    sid       = "ReadLandingObjects"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.landing.arn}/landing/*"]
  }
  statement {
    sid       = "ListLandingPrefix"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.landing.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["landing/*"]
    }
  }
  statement {
    sid       = "DecryptLanding"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.landing.arn]
  }
}

resource "aws_iam_role_policy" "landing_read" {
  name   = "snowflake-landing-read"
  role   = aws_iam_role.snowflake_landing_reader.id
  policy = data.aws_iam_policy_document.landing_read.json
}

# ---------------------------------------------------------------- Snowpipe notifications
# All auto-ingest pipes in an account share one SQS queue (notification_channel).
resource "aws_s3_bucket_notification" "snowpipe" {
  bucket = aws_s3_bucket.landing.id

  dynamic "queue" {
    for_each = toset(keys(local.raw_tables))
    content {
      id            = "snowpipe-${queue.value}"
      queue_arn     = snowflake_pipe.feed[queue.value].show_output[0].notification_channel
      events        = ["s3:ObjectCreated:*"]
      filter_prefix = "landing/${queue.value}/"
      filter_suffix = ".parquet"
    }
  }
}
