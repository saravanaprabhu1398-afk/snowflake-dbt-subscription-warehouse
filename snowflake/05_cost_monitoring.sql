-- =============================================================================
-- 05 Cost monitoring. dbt sets QUERY_TAG = {"app":"dbt","layer":...,"model":...},
-- so spend can be attributed per layer and per model.
-- =============================================================================

-- Credits per warehouse per day
select
    warehouse_name,
    to_date(start_time) as usage_date,
    sum(credits_used) as credits
from snowflake.account_usage.warehouse_metering_history
where start_time >= dateadd(day, -30, current_timestamp())
group by 1, 2
order by 2 desc, 3 desc;

-- Approximate cost per dbt model: share of warehouse execution time by query tag.
-- (Per-query credit attribution: snowflake.account_usage.query_attribution_history.)
select
    try_parse_json(query_tag):"model"::varchar as dbt_model,
    try_parse_json(query_tag):"layer"::varchar as dbt_layer,
    warehouse_name,
    count(*) as queries,
    sum(execution_time) / 1000 / 3600 as execution_hours
from snowflake.account_usage.query_history
where start_time >= dateadd(day, -7, current_timestamp())
  and try_parse_json(query_tag):"app"::varchar = 'dbt'
group by 1, 2, 3
order by execution_hours desc
limit 25;

-- Credits attributed per query (Enterprise; ACCOUNT_USAGE latency up to a few hours)
select
    try_parse_json(query_tag):"model"::varchar as dbt_model,
    sum(credits_attributed_compute) as credits
from snowflake.account_usage.query_attribution_history
where start_time >= dateadd(day, -7, current_timestamp())
group by 1
order by 2 desc
limit 25;

-- Idle burn: warehouses that run long after the last query (auto_suspend too high)
select
    warehouse_name,
    sum(credits_used_compute) as compute_credits,
    sum(credits_used_cloud_services) as cloud_services_credits
from snowflake.account_usage.warehouse_metering_history
where start_time >= dateadd(day, -7, current_timestamp())
group by 1;

-- Snowpipe cost per pipe
select pipe_name, sum(credits_used) as credits, sum(files_inserted) as files
from snowflake.account_usage.pipe_usage_history
where start_time >= dateadd(day, -30, current_timestamp())
group by 1
order by 2 desc;
