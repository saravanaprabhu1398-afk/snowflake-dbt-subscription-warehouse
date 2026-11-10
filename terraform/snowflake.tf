# ---------------------------------------------------------------- databases and schemas
resource "snowflake_database" "raw" {
  name                        = "RAW"
  comment                     = "Landing data loaded by Snowpipe"
  data_retention_time_in_days = 1
}

resource "snowflake_schema" "landing" {
  database = snowflake_database.raw.name
  name     = "LANDING"
}

resource "snowflake_database" "analytics" {
  name    = "ANALYTICS"
  comment = "dbt-managed models"
}

resource "snowflake_database" "governance" {
  name    = "GOVERNANCE"
  comment = "Tags, policies, privacy procedures"
}

resource "snowflake_schema" "governance" {
  for_each = toset(["TAGS", "POLICIES", "PRIVACY"])
  database = snowflake_database.governance.name
  name     = each.key
}

# ---------------------------------------------------------------- warehouses per workload
locals {
  warehouses = {
    LOAD_WH = {
      size    = "XSMALL", auto_suspend = 60, max_clusters = 1, monitor = "transform"
      comment = "COPY INTO backfills"
    }
    TRANSFORM_WH_S = {
      size    = "SMALL", auto_suspend = 60, max_clusters = 1, monitor = "transform"
      comment = "dbt default + CI"
    }
    TRANSFORM_WH_M = {
      size    = "MEDIUM", auto_suspend = 60, max_clusters = 1, monitor = "transform"
      comment = "dbt heavy models only"
    }
    BI_WH = {
      size    = "SMALL", auto_suspend = 300, max_clusters = 3, monitor = "bi"
      comment = "Dashboards; multi-cluster for concurrency"
    }
  }
}

resource "snowflake_resource_monitor" "this" {
  for_each                  = var.monthly_credit_quota
  name                      = "RM_${upper(each.key)}"
  credit_quota              = each.value
  frequency                 = "MONTHLY"
  start_timestamp           = "IMMEDIATELY"
  notify_triggers           = [75, 90]
  suspend_trigger           = 100
  suspend_immediate_trigger = 110
  notify_users              = var.notify_users
}

resource "snowflake_warehouse" "this" {
  for_each                     = local.warehouses
  name                         = each.key
  warehouse_size               = each.value.size
  auto_suspend                 = each.value.auto_suspend
  auto_resume                  = "true"
  initially_suspended          = true
  min_cluster_count            = 1
  max_cluster_count            = each.value.max_clusters
  scaling_policy               = each.value.max_clusters > 1 ? "ECONOMY" : null
  resource_monitor             = snowflake_resource_monitor.this[each.value.monitor].name
  statement_timeout_in_seconds = 3600
  comment                      = each.value.comment
}

# ---------------------------------------------------------------- roles
resource "snowflake_account_role" "this" {
  for_each = toset(["LOADER", "TRANSFORMER", "ANALYST", "ANALYST_EU", "PII_READER", "PRIVACY_OFFICER"])
  name     = each.key
}

resource "snowflake_grant_privileges_to_account_role" "transformer_wh" {
  for_each          = toset(["TRANSFORM_WH_S", "TRANSFORM_WH_M"])
  account_role_name = snowflake_account_role.this["TRANSFORMER"].name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.this[each.key].name
  }
}

resource "snowflake_grant_privileges_to_account_role" "analyst_wh" {
  for_each          = toset(["ANALYST", "ANALYST_EU"])
  account_role_name = snowflake_account_role.this[each.key].name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.this["BI_WH"].name
  }
}

# ---------------------------------------------------------------- S3 integration, stage, pipes
resource "snowflake_storage_integration_aws" "s3_landing" {
  name                      = "S3_LANDING_INT"
  storage_provider          = "S3"
  enabled                   = true
  storage_aws_role_arn      = local.snowflake_role_arn # constructed, avoids a dependency cycle with the role
  storage_allowed_locations = ["s3://${var.landing_bucket_name}/landing/"]
}

resource "snowflake_file_format_parquet" "parquet" {
  name             = "FF_PARQUET"
  database         = snowflake_database.raw.name
  schema           = snowflake_schema.landing.name
  use_logical_type = "true"
}

resource "snowflake_stage_external_s3" "landing" {
  name                = "LANDING_STAGE"
  database            = snowflake_database.raw.name
  schema              = snowflake_schema.landing.name
  url                 = "s3://${var.landing_bucket_name}/landing/"
  storage_integration = snowflake_storage_integration_aws.s3_landing.name
  comment             = "Landing zone, one prefix per feed, partitioned by _load_date"
  file_format {
    format_name = "${snowflake_database.raw.name}.${snowflake_schema.landing.name}.${snowflake_file_format_parquet.parquet.name}"
  }
}

# RAW tables are created by snowflake/02_ingestion.sql (schema-on-read VARCHAR tables).
resource "snowflake_pipe" "feed" {
  for_each       = toset(var.feeds)
  name           = "PIPE_${upper(each.key)}"
  database       = snowflake_database.raw.name
  schema         = snowflake_schema.landing.name
  auto_ingest    = true
  comment        = "Auto-ingest ${each.key} from S3"
  copy_statement = <<-SQL
    copy into ${snowflake_database.raw.name}.${snowflake_schema.landing.name}.${upper(each.key)}
    from @${snowflake_database.raw.name}.${snowflake_schema.landing.name}.${snowflake_stage_external_s3.landing.name}/${each.key}/
    file_format = (format_name = ${snowflake_database.raw.name}.${snowflake_schema.landing.name}.${snowflake_file_format_parquet.parquet.name})
    match_by_column_name = case_insensitive
    include_metadata = (_source_file = metadata$filename, _ingested_at = metadata$start_scan_time)
    on_error = skip_file
  SQL
}
