{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='event_id',
    on_schema_change='append_new_columns',
    cluster_by=['event_date']
) }}

-- Grain: one row per subscription lifecycle event.
with events as (
    select * from {{ ref('stg_subscription_events') }}
    where 1 = 1 {{ incremental_load_filter() }}
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
    e.event_id,
    e.subscription_id,
    c.customer_sk,
    e.customer_id,
    e.plan_id as plan_key,
    e.previous_plan_id as previous_plan_key,
    {{ date_key('e.event_date') }} as event_date_key,
    e.event_date,
    e.event_ts,
    e.event_type,
    e.channel,
    e.utm_source,
    e.cancel_reason,
    case e.event_type
        when 'subscription_start' then 1
        when 'cancel' then -1
        else 0
    end as paid_subscriber_delta,
    e._loaded_at,
    e._load_date
from events as e
left join customers as c
    on e.customer_id = c.customer_id
        and e.event_ts >= c.valid_from
        and e.event_ts < c.valid_to
