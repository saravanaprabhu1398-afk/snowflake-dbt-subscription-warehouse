-- =============================================================================
-- 06 Account-level guardrails, applied after Terraform (`make sf-governance`).
-- Per-workload monitors (Terraform) suspend individual warehouses; this monitor caps
-- total warehouse spend for the whole account. Serverless features (Snowpipe,
-- automatic clustering, tasks on serverless compute) are not covered by resource
-- monitors: watch them with 05_cost_monitoring.sql or a Snowflake budget.
-- Quota below is sized for a trial account (about $400 of credit).
-- =============================================================================

use role accountadmin;

create or replace resource monitor rm_account with
    credit_quota = 40 frequency = monthly start_timestamp = immediately
    triggers on 50 percent do notify
             on 80 percent do notify
             on 100 percent do suspend
             on 110 percent do suspend_immediate;

alter account set resource_monitor = rm_account;

-- Fail runaway queries instead of letting them burn credits (warehouses also set 3600 s).
alter account set statement_timeout_in_seconds = 7200;

-- Snapshot of what was configured.
show resource monitors;
show warehouses;
