# Ownership model
#   ACCOUNTADMIN (provider alias "admin"): account-level objects that need it: storage
#     integration, resource monitors, warehouses (a monitor can only be attached by
#     ACCOUNTADMIN), roles, users and all grants.
#   SYSADMIN (default provider): databases, schemas, RAW tables, file format, stage, pipes.
#   TRANSFORMER (dbt service user): everything inside ANALYTICS, created by dbt at run time.
# Governance objects (tags, masking/row access policies, erasure procedure) are SQL:
# snowflake/04_governance.sql, applied after this.

locals {
  db_raw     = snowflake_database.raw.name
  sch_land   = snowflake_schema.landing.name
  landing_fq = "\"${snowflake_database.raw.name}\".\"${snowflake_schema.landing.name}\""

  # RAW tables: all VARCHAR (schema-on-read; dbt staging casts) + load metadata.
  raw_tables = {
    customers = {
      comment   = "Customer profile CDC feed. PII."
      retention = 1 # short Time Travel so erased PII ages out (GDPR)
      columns = ["customer_id", "email", "first_name", "last_name", "phone", "country_code",
      "marketing_opt_in", "created_at", "updated_at"]
    }
    plans = {
      comment   = "Plan catalogue from the billing service."
      retention = 1
      columns = ["plan_id", "plan_name", "tier", "billing_period", "list_price_usd", "max_devices",
      "includes_vpn", "includes_identity_protection", "is_family_plan"]
    }
    subscription_events = {
      comment   = "Subscription lifecycle events."
      retention = 1
      columns = ["event_id", "subscription_id", "customer_id", "plan_id", "previous_plan_id",
      "event_type", "event_ts", "channel", "utm_source", "cancel_reason"]
    }
    payments = {
      comment   = "PSP tokens + last4 only. No PAN/CVV/expiry: keeps the warehouse out of PCI cardholder-data scope."
      retention = 1
      columns = ["payment_id", "subscription_id", "customer_id", "plan_id", "payment_ts",
        "payment_type", "status", "amount", "currency", "payment_method", "card_brand",
      "card_last4", "psp_token", "refund_of_payment_id"]
    }
    feature_usage = {
      comment   = "App telemetry, one row per feature interaction."
      retention = 1
      columns = ["usage_event_id", "customer_id", "device_id", "platform", "feature", "event_ts",
      "duration_sec", "threats_blocked"]
    }
  }

  functional_roles = {
    LOADER          = "COPY INTO backfills into RAW"
    TRANSFORMER     = "dbt service role: reads RAW, owns ANALYTICS"
    ANALYST         = "BI users: marts only, PII masked, no GDPR-scope rows"
    ANALYST_EU      = "BI users cleared for GDPR-scope rows, PII masked"
    PII_READER      = "Support/privacy staff who may see unmasked PII"
    PRIVACY_OFFICER = "Runs the right-to-erasure procedure"
  }
}

# ---------------------------------------------------------------- databases and schemas
resource "snowflake_database" "raw" {
  name                        = "RAW"
  comment                     = "Landing data loaded by Snowpipe. Source of truth for replays."
  data_retention_time_in_days = 1
}

resource "snowflake_schema" "landing" {
  database = snowflake_database.raw.name
  name     = "LANDING"
}

resource "snowflake_database" "analytics" {
  name    = "ANALYTICS"
  comment = "dbt-managed models: staging, snapshots, core, subscription, product."
}

resource "snowflake_database" "governance" {
  name    = "GOVERNANCE"
  comment = "Tags, masking/row access policies, privacy procedures, audit."
}

resource "snowflake_schema" "governance" {
  for_each = toset(["TAGS", "POLICIES", "PRIVACY"])
  database = snowflake_database.governance.name
  name     = each.key
}

# ---------------------------------------------------------------- resource monitors + warehouses
locals {
  warehouses = {
    LOAD_WH = {
      size    = "XSMALL", auto_suspend = 60, max_clusters = 1, monitor = "transform"
      comment = "COPY INTO backfills. Snowpipe is serverless and does not use this."
    }
    TRANSFORM_WH_S = {
      size    = "SMALL", auto_suspend = 60, max_clusters = 1, monitor = "transform"
      comment = "dbt default: staging, dims, incremental facts."
    }
    TRANSFORM_WH_M = {
      size    = "MEDIUM", auto_suspend = 60, max_clusters = 1, monitor = "transform"
      comment = "dbt heavy models only (snowflake_warehouse config in prod)."
    }
    BI_WH = {
      size    = "SMALL", auto_suspend = 300, max_clusters = var.bi_max_clusters, monitor = "bi"
      comment = "Dashboards. Longer auto-suspend keeps the local cache warm."
    }
  }
}

resource "snowflake_resource_monitor" "this" {
  provider                  = snowflake.admin
  for_each                  = var.monthly_credit_quota
  name                      = "RM_${upper(each.key)}"
  credit_quota              = each.value
  frequency                 = "MONTHLY"
  start_timestamp           = "IMMEDIATELY"
  notify_triggers           = [50, 75, 90]
  suspend_trigger           = 100
  suspend_immediate_trigger = 110
  notify_users              = var.notify_users
}

resource "snowflake_warehouse" "this" {
  provider                     = snowflake.admin
  for_each                     = local.warehouses
  name                         = each.key
  warehouse_size               = coalesce(var.warehouse_size_override, each.value.size)
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

# ---------------------------------------------------------------- roles and hierarchy
resource "snowflake_account_role" "this" {
  provider = snowflake.admin
  for_each = local.functional_roles
  name     = each.key
  comment  = each.value
}

# Every functional role rolls up to SYSADMIN so admins can manage what the roles own.
resource "snowflake_grant_account_role" "to_sysadmin" {
  provider         = snowflake.admin
  for_each         = local.functional_roles
  role_name        = snowflake_account_role.this[each.key].name
  parent_role_name = "SYSADMIN"
}

# Users can only activate roles granted to them directly, so the admin gets the consumer
# roles to test what each one sees.
resource "snowflake_grant_account_role" "admin_test_roles" {
  provider  = snowflake.admin
  for_each  = toset(["ANALYST", "ANALYST_EU", "PII_READER", "PRIVACY_OFFICER"])
  role_name = snowflake_account_role.this[each.key].name
  user_name = var.admin_user
}

# ---------------------------------------------------------------- warehouse grants
locals {
  warehouse_grants = {
    loader_load     = { role = "LOADER", wh = "LOAD_WH" }
    transformer_s   = { role = "TRANSFORMER", wh = "TRANSFORM_WH_S" }
    transformer_m   = { role = "TRANSFORMER", wh = "TRANSFORM_WH_M" }
    analyst_bi      = { role = "ANALYST", wh = "BI_WH" }
    analyst_eu_bi   = { role = "ANALYST_EU", wh = "BI_WH" }
    pii_reader_bi   = { role = "PII_READER", wh = "BI_WH" }
    privacy_officer = { role = "PRIVACY_OFFICER", wh = "TRANSFORM_WH_S" }
  }
}

resource "snowflake_grant_privileges_to_account_role" "warehouse_usage" {
  provider          = snowflake.admin
  for_each          = local.warehouse_grants
  account_role_name = snowflake_account_role.this[each.value.role].name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.this[each.value.wh].name
  }
}

# ---------------------------------------------------------------- database / schema grants
resource "snowflake_grant_privileges_to_account_role" "raw_db_usage" {
  provider          = snowflake.admin
  for_each          = toset(["LOADER", "TRANSFORMER"])
  account_role_name = snowflake_account_role.this[each.key].name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.raw.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "landing_schema_usage" {
  provider          = snowflake.admin
  for_each          = toset(["LOADER", "TRANSFORMER"])
  account_role_name = snowflake_account_role.this[each.key].name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = local.landing_fq
  }
}

resource "snowflake_grant_privileges_to_account_role" "transformer_raw_select" {
  provider          = snowflake.admin
  account_role_name = snowflake_account_role.this["TRANSFORMER"].name
  privileges        = ["SELECT"]
  on_schema_object {
    all {
      object_type_plural = "TABLES"
      in_schema          = local.landing_fq
    }
  }
  depends_on = [snowflake_table.raw]
}

resource "snowflake_grant_privileges_to_account_role" "transformer_raw_select_future" {
  provider          = snowflake.admin
  account_role_name = snowflake_account_role.this["TRANSFORMER"].name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema          = local.landing_fq
    }
  }
}

# The orchestrator (Airflow, running as SVC_DBT) checks SYSTEM$PIPE_STATUS before building.
resource "snowflake_grant_privileges_to_account_role" "transformer_pipe_monitor" {
  provider          = snowflake.admin
  account_role_name = snowflake_account_role.this["TRANSFORMER"].name
  privileges        = ["MONITOR"]
  on_schema_object {
    all {
      object_type_plural = "PIPES"
      in_schema          = local.landing_fq
    }
  }
  depends_on = [snowflake_pipe.feed]
}

resource "snowflake_grant_privileges_to_account_role" "loader_raw_insert" {
  provider          = snowflake.admin
  account_role_name = snowflake_account_role.this["LOADER"].name
  privileges        = ["SELECT", "INSERT"]
  on_schema_object {
    all {
      object_type_plural = "TABLES"
      in_schema          = local.landing_fq
    }
  }
  depends_on = [snowflake_table.raw]
}

resource "snowflake_grant_privileges_to_account_role" "loader_stage_usage" {
  provider          = snowflake.admin
  account_role_name = snowflake_account_role.this["LOADER"].name
  privileges        = ["USAGE"]
  on_schema_object {
    object_type = "STAGE"
    object_name = "${local.landing_fq}.\"${snowflake_stage_external_s3.landing.name}\""
  }
}

resource "snowflake_grant_privileges_to_account_role" "loader_file_format_usage" {
  provider          = snowflake.admin
  account_role_name = snowflake_account_role.this["LOADER"].name
  privileges        = ["USAGE"]
  on_schema_object {
    object_type = "FILE FORMAT"
    object_name = "${local.landing_fq}.\"${snowflake_file_format_parquet.parquet.name}\""
  }
}

# dbt creates its schemas inside ANALYTICS and owns them.
resource "snowflake_grant_privileges_to_account_role" "transformer_analytics" {
  provider          = snowflake.admin
  account_role_name = snowflake_account_role.this["TRANSFORMER"].name
  privileges        = ["USAGE", "CREATE SCHEMA"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.analytics.name
  }
}

# BI roles: database usage only. Schema usage and SELECT on the mart schemas are granted by
# dbt (grants config + on-run-end hook), so staging/snapshot schemas stay invisible to them.
resource "snowflake_grant_privileges_to_account_role" "bi_analytics_usage" {
  provider          = snowflake.admin
  for_each          = toset(["ANALYST", "ANALYST_EU", "PII_READER"])
  account_role_name = snowflake_account_role.this[each.key].name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.analytics.name
  }
}

# ---------------------------------------------------------------- dbt service user (key-pair only)
resource "snowflake_service_user" "dbt" {
  provider          = snowflake.admin
  name              = "SVC_DBT"
  comment           = "dbt prod runs (local and GitHub Actions). Key-pair auth, no password."
  default_role      = snowflake_account_role.this["TRANSFORMER"].name
  default_warehouse = snowflake_warehouse.this["TRANSFORM_WH_S"].name
  rsa_public_key    = local.dbt_public_key
}

resource "snowflake_grant_account_role" "dbt_transformer" {
  provider  = snowflake.admin
  role_name = snowflake_account_role.this["TRANSFORMER"].name
  user_name = snowflake_service_user.dbt.name
}

locals {
  # Public key body without PEM header/footer/newlines, as Snowflake expects.
  dbt_public_key = join("", [
    for line in split("\n", trimspace(file(pathexpand(var.dbt_public_key_path)))) :
    line if !startswith(line, "-----")
  ])
}

# ---------------------------------------------------------------- S3 integration, stage, pipes
resource "snowflake_storage_integration_aws" "s3_landing" {
  provider                  = snowflake.admin
  name                      = "S3_LANDING_INT"
  storage_provider          = "S3"
  enabled                   = true
  storage_aws_role_arn      = local.snowflake_role_arn # constructed, avoids a dependency cycle with the role
  storage_allowed_locations = ["s3://${var.landing_bucket_name}/landing/"]
}

# SYSADMIN creates the stage, so it needs USAGE on the integration.
resource "snowflake_grant_privileges_to_account_role" "sysadmin_integration" {
  provider          = snowflake.admin
  account_role_name = "SYSADMIN"
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "INTEGRATION"
    object_name = snowflake_storage_integration_aws.s3_landing.name
  }
}

resource "snowflake_file_format_parquet" "parquet" {
  name             = "FF_PARQUET"
  database         = local.db_raw
  schema           = local.sch_land
  use_logical_type = "true"
}

resource "snowflake_stage_external_s3" "landing" {
  name                = "LANDING_STAGE"
  database            = local.db_raw
  schema              = local.sch_land
  url                 = "s3://${var.landing_bucket_name}/landing/"
  storage_integration = snowflake_storage_integration_aws.s3_landing.name
  comment             = "Landing zone, one prefix per feed, partitioned by _load_date"
  file_format {
    format_name = "${local.db_raw}.${local.sch_land}.${snowflake_file_format_parquet.parquet.name}"
  }
  depends_on = [snowflake_grant_privileges_to_account_role.sysadmin_integration, aws_iam_role.snowflake_landing_reader]
}

resource "snowflake_table" "raw" {
  for_each                    = local.raw_tables
  database                    = local.db_raw
  schema                      = local.sch_land
  name                        = upper(each.key)
  comment                     = each.value.comment
  data_retention_time_in_days = each.value.retention

  dynamic "column" {
    for_each = concat(each.value.columns, ["_loaded_at", "_load_date", "_source_file"])
    content {
      name = upper(column.value)
      type = "VARCHAR"
    }
  }
  column {
    name = "_INGESTED_AT"
    type = "TIMESTAMP_LTZ"
  }
}

resource "snowflake_pipe" "feed" {
  for_each    = local.raw_tables
  name        = "PIPE_${upper(each.key)}"
  database    = local.db_raw
  schema      = local.sch_land
  auto_ingest = true
  comment     = "Auto-ingest ${each.key} from S3"
  depends_on  = [time_sleep.iam_propagation]
  # include_metadata targets must be the exact (upper-case) column names.
  copy_statement = <<-SQL
    copy into ${local.db_raw}.${local.sch_land}.${snowflake_table.raw[each.key].name}
    from @${local.db_raw}.${local.sch_land}.${snowflake_stage_external_s3.landing.name}/${each.key}/
    file_format = (format_name = ${local.db_raw}.${local.sch_land}.${snowflake_file_format_parquet.parquet.name})
    match_by_column_name = case_insensitive
    include_metadata = (_SOURCE_FILE = METADATA$FILENAME, _INGESTED_AT = METADATA$START_SCAN_TIME)
    on_error = skip_file
  SQL
}
