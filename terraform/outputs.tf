output "landing_bucket" {
  value = aws_s3_bucket.landing.bucket
}

output "snowflake_iam_role_arn" {
  value = aws_iam_role.snowflake_landing_reader.arn
}

output "snowpipe_sqs_queue" {
  value = { for k, p in snowflake_pipe.feed : k => p.show_output[0].notification_channel }
}
