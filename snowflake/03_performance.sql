-- =============================================================================
-- 03 Performance: clustering, pruning checks, caching, warehouse sizing.
-- Background and reasoning: docs/snowflake-performance-and-cost.md
-- dbt sets cluster_by on the facts; these statements are for inspection and for
-- the cases dbt does not own.
-- =============================================================================

use role transformer;
use warehouse transform_wh_s;
use schema analytics.core;

-- dbt (cluster_by config) emits the equivalent of:
--   alter table fct_feature_usage cluster by (event_date, feature);
--   alter table fct_subscription_events cluster by (event_date);
--   alter table fct_payments cluster by (payment_date);

-- How well clustered are we? average_depth close to 1 = good pruning.
select system$clustering_information('analytics.core.fct_feature_usage', '(event_date, feature)');

-- Is a typical dashboard query pruning? Compare partitions_scanned vs partitions_total.
select
    query_id,
    query_text,
    partitions_scanned,
    partitions_total,
    round(100 * partitions_scanned / nullif(partitions_total, 0), 1) as pct_scanned,
    bytes_scanned,
    percentage_scanned_from_cache,
    total_elapsed_time / 1000 as seconds
from table(information_schema.query_history_by_warehouse(warehouse_name => 'BI_WH', result_limit => 100))
where query_text ilike '%fct_feature_usage%'
order by start_time desc;

-- Automatic clustering cost (credits) per table, last 30 days: clustering is not free,
-- so only the large, date-filtered facts are clustered.
select table_name, sum(credits_used) as credits
from snowflake.account_usage.automatic_clustering_history
where start_time >= dateadd(day, -30, current_timestamp())
group by table_name
order by credits desc;

-- Result cache: identical dashboard queries within 24h are free if the underlying
-- data did not change. Keep it on (default) for BI; disable only for benchmarking.
alter session set use_cached_result = true;

-- Remote spill = warehouse too small for that query. Upsize only the model that spills
-- (dbt snowflake_warehouse config), not the whole run.
select
    query_tag,
    warehouse_name,
    warehouse_size,
    count(*) as queries,
    sum(bytes_spilled_to_local_storage) as local_spill,
    sum(bytes_spilled_to_remote_storage) as remote_spill,
    avg(total_elapsed_time) / 1000 as avg_seconds
from snowflake.account_usage.query_history
where start_time >= dateadd(day, -7, current_timestamp())
  and warehouse_name like 'TRANSFORM_WH%'
group by 1, 2, 3
order by remote_spill desc;

-- Search optimisation for point lookups by customer_id (support tooling), only on the
-- dimension, not on the large facts.
alter table analytics.core.dim_customer add search optimization on equality(customer_id, email);
