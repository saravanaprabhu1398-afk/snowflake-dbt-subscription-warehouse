-- Customer x calendar month grid from acquisition month to the last month of data,
-- flagging whether the customer had paid access in that month and the net revenue booked.
{{ config(materialized='table') }}

with subs as (
    select * from {{ ref('int_subscriptions') }}
    where paid_start_ts is not null
),

customers as (
    select
        customer_id,
        cast({{ dbt.date_trunc('month', 'min(paid_start_ts)') }} as date) as cohort_month,
        max(cast({{ dbt.date_trunc('month', 'data_end_ts') }} as date)) as last_data_month
    from subs
    group by customer_id
),

months as (
    select distinct month_start_date as month_start
    from {{ ref('dim_date') }}
),

grid as (
    select
        c.customer_id,
        c.cohort_month,
        m.month_start
    from customers as c
    inner join months as m
        on m.month_start >= c.cohort_month
            and m.month_start <= c.last_data_month
),

active as (
    select distinct
        g.customer_id,
        g.month_start
    from grid as g
    inner join subs as s
        on g.customer_id = s.customer_id
            and s.paid_start_ts < {{ dbt.dateadd('month', 1, 'g.month_start') }}
            and s.paid_access_end_ts > g.month_start
),

revenue as (
    select
        customer_id,
        cast({{ dbt.date_trunc('month', 'payment_date') }} as date) as month_start,
        sum(net_revenue_usd) as net_revenue_usd
    from {{ ref('int_payments_usd') }}
    group by 1, 2
)

select
    g.customer_id,
    g.cohort_month,
    g.month_start,
    {{ months_between_dates('g.cohort_month', 'g.month_start') }} as months_since_acquisition,  -- noqa: LT05
    a.customer_id is not null as is_active,
    coalesce(r.net_revenue_usd, 0) as net_revenue_usd
from grid as g
left join active as a
    on g.customer_id = a.customer_id and g.month_start = a.month_start
left join revenue as r
    on g.customer_id = r.customer_id and g.month_start = r.month_start
