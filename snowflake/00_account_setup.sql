-- =============================================================================
-- 00 Account setup: databases, roles, warehouses per workload, resource monitors.
-- Run as SYSADMIN / SECURITYADMIN / ACCOUNTADMIN where noted. Terraform in
-- terraform/ manages the same objects; this file is the readable reference.
-- =============================================================================

use role sysadmin;

create database if not exists raw comment = 'Landing data loaded by Snowpipe. Source of truth for replays.';
create schema if not exists raw.landing;
create database if not exists analytics comment = 'dbt-managed models: staging, core, subscription, product.';
create database if not exists governance comment = 'Tags, masking/row access policies, privacy procedures, audit.';
create schema if not exists governance.tags;
create schema if not exists governance.policies;
create schema if not exists governance.privacy;

-- Short Time Travel on PII landing data so erased values age out quickly (see 04_governance.sql).
alter schema raw.landing set data_retention_time_in_days = 1;

-- -----------------------------------------------------------------------------
-- Warehouses: one per workload so cost is attributable and sizing is independent.
-- All auto-suspend quickly; BI is multi-cluster for concurrency, not size.
-- -----------------------------------------------------------------------------
create warehouse if not exists load_wh
    warehouse_size = 'XSMALL' auto_suspend = 60 auto_resume = true initially_suspended = true
    comment = 'COPY INTO backfills. Snowpipe itself is serverless and does not use this.';

create warehouse if not exists transform_wh_s
    warehouse_size = 'SMALL' auto_suspend = 60 auto_resume = true initially_suspended = true
    statement_timeout_in_seconds = 3600
    comment = 'dbt: staging, dims, incremental facts, CI.';

create warehouse if not exists transform_wh_m
    warehouse_size = 'MEDIUM' auto_suspend = 60 auto_resume = true initially_suspended = true
    statement_timeout_in_seconds = 3600
    comment = 'dbt: heavy models only (fct_feature_usage full refresh, cohort marts) via snowflake_warehouse config.';

create warehouse if not exists bi_wh
    warehouse_size = 'SMALL' auto_suspend = 300 auto_resume = true initially_suspended = true
    min_cluster_count = 1 max_cluster_count = 3 scaling_policy = 'ECONOMY'
    comment = 'Dashboards. Longer auto-suspend keeps the local disk cache warm between dashboard refreshes.';

-- -----------------------------------------------------------------------------
-- Resource monitors (ACCOUNTADMIN). Notify early, suspend at quota.
-- -----------------------------------------------------------------------------
use role accountadmin;

create or replace resource monitor rm_transform with
    credit_quota = 300 frequency = monthly start_timestamp = immediately
    triggers on 75 percent do notify
             on 90 percent do notify
             on 100 percent do suspend
             on 110 percent do suspend_immediate;

create or replace resource monitor rm_bi with
    credit_quota = 200 frequency = monthly start_timestamp = immediately
    triggers on 80 percent do notify
             on 100 percent do suspend;

create or replace resource monitor rm_account with
    credit_quota = 600 frequency = monthly start_timestamp = immediately
    triggers on 90 percent do notify;

alter warehouse transform_wh_s set resource_monitor = rm_transform;
alter warehouse transform_wh_m set resource_monitor = rm_transform;
alter warehouse load_wh set resource_monitor = rm_transform;
alter warehouse bi_wh set resource_monitor = rm_bi;
alter account set resource_monitor = rm_account;

-- -----------------------------------------------------------------------------
-- Roles (functional, least privilege)
-- -----------------------------------------------------------------------------
use role securityadmin;

create role if not exists loader comment = 'Snowpipe / COPY into RAW';
create role if not exists transformer comment = 'dbt service user';
create role if not exists analyst comment = 'BI users, global non-EU rows, PII masked';
create role if not exists analyst_eu comment = 'BI users cleared for EU customer rows, PII masked';
create role if not exists pii_reader comment = 'Support/privacy staff who may see unmasked PII';
create role if not exists privacy_officer comment = 'Runs right-to-erasure procedure';

grant role loader to role sysadmin;
grant role transformer to role sysadmin;
grant role analyst to role sysadmin;
grant role analyst_eu to role sysadmin;
grant role pii_reader to role sysadmin;
grant role privacy_officer to role sysadmin;

grant usage on warehouse load_wh to role loader;
grant usage on database raw to role loader;
grant usage, create table, create pipe, create stage on schema raw.landing to role loader;

grant usage on warehouse transform_wh_s to role transformer;
grant usage on warehouse transform_wh_m to role transformer;
grant usage on database raw to role transformer;
grant usage on schema raw.landing to role transformer;
grant select on all tables in schema raw.landing to role transformer;
grant select on future tables in schema raw.landing to role transformer;
grant usage, create schema on database analytics to role transformer;

grant usage on warehouse bi_wh to role analyst;
grant usage on warehouse bi_wh to role analyst_eu;
grant usage on database analytics to role analyst;
grant usage on database analytics to role analyst_eu;
