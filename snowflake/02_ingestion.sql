-- RAW tables and pipes are deployed by Terraform (terraform/snowflake.tf). This file is the
-- readable SQL reference plus the backfill and monitoring queries.
-- =============================================================================
-- 02 RAW tables, one-off backfill with COPY INTO, continuous load with Snowpipe.
-- Raw columns stay VARCHAR (schema-on-read); dbt staging casts and dedups.
-- Metadata columns make every row traceable to its file.
-- =============================================================================

use role loader;
use warehouse load_wh;
use schema raw.landing;

create table if not exists customers (
    customer_id varchar, email varchar, first_name varchar, last_name varchar, phone varchar,
    country_code varchar, marketing_opt_in varchar, created_at varchar, updated_at varchar,
    _loaded_at varchar, _load_date varchar,
    _source_file varchar, _ingested_at timestamp_ltz
) data_retention_time_in_days = 1     -- PII: keep Time Travel short (GDPR erasure)
  comment = 'Customer profile CDC feed. PII.';

create table if not exists plans (
    plan_id varchar, plan_name varchar, tier varchar, billing_period varchar,
    list_price_usd varchar, max_devices varchar, includes_vpn varchar,
    includes_identity_protection varchar, is_family_plan varchar,
    _loaded_at varchar, _load_date varchar, _source_file varchar, _ingested_at timestamp_ltz
);

create table if not exists subscription_events (
    event_id varchar, subscription_id varchar, customer_id varchar, plan_id varchar,
    previous_plan_id varchar, event_type varchar, event_ts varchar, channel varchar,
    utm_source varchar, cancel_reason varchar,
    _loaded_at varchar, _load_date varchar, _source_file varchar, _ingested_at timestamp_ltz
);

create table if not exists payments (
    payment_id varchar, subscription_id varchar, customer_id varchar, plan_id varchar,
    payment_ts varchar, payment_type varchar, status varchar, amount varchar, currency varchar,
    payment_method varchar, card_brand varchar, card_last4 varchar, psp_token varchar,
    refund_of_payment_id varchar,
    _loaded_at varchar, _load_date varchar, _source_file varchar, _ingested_at timestamp_ltz
) comment = 'PSP tokens + last4 only. No PAN/CVV/expiry: keeps the warehouse out of PCI cardholder-data scope.';

create table if not exists feature_usage (
    usage_event_id varchar, customer_id varchar, device_id varchar, platform varchar,
    feature varchar, event_ts varchar, duration_sec varchar, threats_blocked varchar,
    _loaded_at varchar, _load_date varchar, _source_file varchar, _ingested_at timestamp_ltz
);

-- -----------------------------------------------------------------------------
-- Backfill (one-off). COPY keeps 64 days of load metadata, so re-running is idempotent.
-- -----------------------------------------------------------------------------
copy into subscription_events
from @landing_stage/subscription_events/
file_format = (format_name = ff_parquet)
match_by_column_name = case_insensitive
include_metadata = (_source_file = metadata$filename, _ingested_at = metadata$start_scan_time)
on_error = abort_statement;
-- repeat for customers, plans, payments, feature_usage

-- -----------------------------------------------------------------------------
-- Continuous load: one auto-ingest pipe per feed. S3 event notifications go to the
-- pipe's SQS queue (SHOW PIPES -> notification_channel; Terraform wires it).
-- Snowpipe is serverless: billed per file/compute-second, no warehouse to size.
-- -----------------------------------------------------------------------------
create pipe if not exists pipe_customers auto_ingest = true as
copy into customers from @landing_stage/customers/
file_format = (format_name = ff_parquet) match_by_column_name = case_insensitive
include_metadata = (_source_file = metadata$filename, _ingested_at = metadata$start_scan_time)
on_error = skip_file;

create pipe if not exists pipe_plans auto_ingest = true as
copy into plans from @landing_stage/plans/
file_format = (format_name = ff_parquet) match_by_column_name = case_insensitive
include_metadata = (_source_file = metadata$filename, _ingested_at = metadata$start_scan_time)
on_error = skip_file;

create pipe if not exists pipe_subscription_events auto_ingest = true as
copy into subscription_events from @landing_stage/subscription_events/
file_format = (format_name = ff_parquet) match_by_column_name = case_insensitive
include_metadata = (_source_file = metadata$filename, _ingested_at = metadata$start_scan_time)
on_error = skip_file;

create pipe if not exists pipe_payments auto_ingest = true as
copy into payments from @landing_stage/payments/
file_format = (format_name = ff_parquet) match_by_column_name = case_insensitive
include_metadata = (_source_file = metadata$filename, _ingested_at = metadata$start_scan_time)
on_error = skip_file;

create pipe if not exists pipe_feature_usage auto_ingest = true as
copy into feature_usage from @landing_stage/feature_usage/
file_format = (format_name = ff_parquet) match_by_column_name = case_insensitive
include_metadata = (_source_file = metadata$filename, _ingested_at = metadata$start_scan_time)
on_error = skip_file;

show pipes;

-- Monitoring: files that failed in the last day (skip_file means bad files don't block the pipe).
select *
from table(information_schema.copy_history(
    table_name => 'RAW.LANDING.FEATURE_USAGE',
    start_time => dateadd(day, -1, current_timestamp())))
where status <> 'Loaded';

select system$pipe_status('raw.landing.pipe_feature_usage');
