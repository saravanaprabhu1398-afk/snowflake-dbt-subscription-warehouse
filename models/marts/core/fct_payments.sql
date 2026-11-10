{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='payment_id',
    on_schema_change='append_new_columns',
    cluster_by=['payment_date']
) }}

-- Grain: one row per payment attempt (charge or refund). Amounts in local currency and USD.
with payments as (
    select * from {{ ref('int_payments_usd') }}
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
    p.payment_id,
    p.subscription_id,
    c.customer_sk,
    p.customer_id,
    p.plan_id as plan_key,
    {{ date_key('p.payment_date') }} as payment_date_key,
    p.payment_date,
    p.payment_ts,
    p.payment_type,
    p.status,
    p.amount_local,
    p.currency,
    p.amount_usd,
    p.net_revenue_usd,
    p.payment_method,
    p.card_brand,
    p.card_last4,
    p.refund_of_payment_id,
    p._loaded_at,
    p._load_date
from payments as p
left join customers as c
    on p.customer_id = c.customer_id
        and p.payment_ts >= c.valid_from
        and p.payment_ts < c.valid_to
