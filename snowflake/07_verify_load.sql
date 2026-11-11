-- Row counts per RAW table and load partition, and Snowpipe status (`make sf-load-status`).
select 'customers' as feed, _load_date, count(*) as rows_loaded, max(_ingested_at) as last_ingested
from raw.landing.customers group by 1, 2
union all
select 'plans', _load_date, count(*), max(_ingested_at) from raw.landing.plans group by 1, 2
union all
select 'subscription_events', _load_date, count(*), max(_ingested_at) from raw.landing.subscription_events group by 1, 2
union all
select 'payments', _load_date, count(*), max(_ingested_at) from raw.landing.payments group by 1, 2
union all
select 'feature_usage', _load_date, count(*), max(_ingested_at) from raw.landing.feature_usage group by 1, 2
order by 1, 2;

-- SYSTEM$PIPE_STATUS needs a literal pipe name, so one row per pipe.
select 'customers' as pipe, parse_json(system$pipe_status('raw.landing.pipe_customers')):executionState::varchar as state,
    parse_json(system$pipe_status('raw.landing.pipe_customers')):pendingFileCount::int as pending_files
union all
select 'plans' as pipe, parse_json(system$pipe_status('raw.landing.pipe_plans')):executionState::varchar as state,
    parse_json(system$pipe_status('raw.landing.pipe_plans')):pendingFileCount::int as pending_files
union all
select 'subscription_events' as pipe, parse_json(system$pipe_status('raw.landing.pipe_subscription_events')):executionState::varchar as state,
    parse_json(system$pipe_status('raw.landing.pipe_subscription_events')):pendingFileCount::int as pending_files
union all
select 'payments' as pipe, parse_json(system$pipe_status('raw.landing.pipe_payments')):executionState::varchar as state,
    parse_json(system$pipe_status('raw.landing.pipe_payments')):pendingFileCount::int as pending_files
union all
select 'feature_usage' as pipe, parse_json(system$pipe_status('raw.landing.pipe_feature_usage')):executionState::varchar as state,
    parse_json(system$pipe_status('raw.landing.pipe_feature_usage')):pendingFileCount::int as pending_files;

-- Files that failed or partially loaded in the last day (on_error = skip_file).
select table_name, file_name, status, first_error_message
from table(raw.information_schema.copy_history(
    table_name => 'RAW.LANDING.FEATURE_USAGE', start_time => dateadd(day, -1, current_timestamp())))
where status <> 'Loaded'
limit 20;
