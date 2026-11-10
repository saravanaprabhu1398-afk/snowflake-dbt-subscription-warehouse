-- Grain: calendar month. Company-level paid subscriber movement and logo churn.
-- logo_churn_rate = customers active last month but not this month / active last month.
with cm as (
    select
        customer_id,
        month_start,
        is_active,
        net_revenue_usd,
        lag(is_active) over (partition by customer_id order by month_start) as was_active_prev
    from {{ ref('int_customer_months') }}
)

select
    month_start,
    sum(case when is_active then 1 else 0 end) as active_customers,
    sum(case when is_active and coalesce(was_active_prev, false) = false then 1 else 0 end) as new_or_returning,
    sum(case when was_active_prev and not is_active then 1 else 0 end) as churned_customers,
    sum(case when was_active_prev then 1 else 0 end) as active_previous_month,
    cast(sum(case when was_active_prev and not is_active then 1 else 0 end) as decimal(18, 6))
    / nullif(sum(case when was_active_prev then 1 else 0 end), 0) as logo_churn_rate,
    sum(net_revenue_usd) as net_revenue_usd
from cm
group by month_start
