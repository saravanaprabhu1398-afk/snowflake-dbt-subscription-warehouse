-- Grain: paid cohort month x months since acquisition.
-- ltv_usd = cumulative net revenue of the cohort up to month N / cohort size (realised LTV).
with cm as (
    select * from {{ ref('int_customer_months') }}
),

monthly as (
    select
        cohort_month,
        months_since_acquisition,
        month_start as activity_month,
        count(*) as customers_in_grid,
        sum(net_revenue_usd) as net_revenue_usd
    from cm
    group by 1, 2, 3
),

cohort_size as (
    select
        cohort_month,
        count(*) as cohort_size
    from cm
    where months_since_acquisition = 0
    group by cohort_month
)

select
    m.cohort_month,
    m.months_since_acquisition,
    m.activity_month,
    cs.cohort_size,
    m.net_revenue_usd,
    sum(m.net_revenue_usd) over (
        partition by m.cohort_month order by m.months_since_acquisition
        rows between unbounded preceding and current row
    ) as cumulative_net_revenue_usd,
    sum(m.net_revenue_usd) over (
        partition by m.cohort_month order by m.months_since_acquisition
        rows between unbounded preceding and current row
    ) / cs.cohort_size as ltv_usd
from monthly as m
inner join cohort_size as cs on m.cohort_month = cs.cohort_month
