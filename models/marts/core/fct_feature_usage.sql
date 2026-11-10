{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='usage_event_id',
    on_schema_change='append_new_columns',
    cluster_by=['event_date', 'feature'],
    snowflake_warehouse=('TRANSFORM_WH_M' if target.name == 'prod' else none)
) }}

-- Grain: one row per feature interaction. Largest table; clustered on event_date + feature
-- so date-bounded and per-feature queries prune micro-partitions.
with usage as (
    select * from {{ ref('stg_feature_usage') }}
    where 1 = 1
        {{ incremental_load_filter() }}
),

customers as (
    select
        customer_sk,
        customer_id,
        valid_from,
        valid_to
    from {{ ref('dim_customer') }}
)

select
    u.usage_event_id,
    c.customer_sk,
    u.customer_id,
    u.device_id,
    u.platform,
    u.feature,
    {{ date_key('u.event_date') }} as event_date_key,
    u.event_date,
    u.event_ts,
    u.duration_sec,
    u.threats_blocked,
    u._loaded_at,
    u._load_date
from usage as u
left join customers as c
    on u.customer_id = c.customer_id
        and u.event_ts >= c.valid_from
        and u.event_ts < c.valid_to
