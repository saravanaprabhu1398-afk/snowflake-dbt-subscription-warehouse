-- Grain: acquisition month x channel x utm source.
-- Acquisition month = month of the customer's first touch (trial start or direct paid start).
with subs as (
    select
        *,
        cast({{ dbt.date_trunc('month', 'coalesce(trial_start_ts, paid_start_ts)') }} as date) as acquisition_month
    from {{ ref('int_subscriptions') }}
),

first_month_revenue as (
    select
        customer_id,
        sum(net_revenue_usd) as first_month_revenue_usd
    from {{ ref('int_customer_months') }}
    where months_since_acquisition = 0
    group by customer_id
)

select
    s.acquisition_month,
    s.acquisition_channel,
    s.acquisition_utm_source,
    count(distinct s.customer_id) as acquired_customers,
    count(distinct case when s.trial_start_ts is not null then s.customer_id end) as trials_started,
    count(distinct case when s.converted_from_trial then s.customer_id end) as trials_converted,
    count(distinct case when s.trial_start_ts is null and s.paid_start_ts is not null then s.customer_id end)
        as direct_paid_starts,
    count(distinct case when s.paid_start_ts is not null then s.customer_id end) as paying_customers,
    cast(
        count(distinct case when s.converted_from_trial then s.customer_id end) as decimal(18, 6)
    )
    / nullif(count(distinct case when s.trial_start_ts is not null then s.customer_id end), 0)
        as trial_conversion_rate,
    coalesce(sum(fmr.first_month_revenue_usd), 0) as first_month_revenue_usd
from subs as s
left join first_month_revenue as fmr on s.customer_id = fmr.customer_id
group by 1, 2, 3
