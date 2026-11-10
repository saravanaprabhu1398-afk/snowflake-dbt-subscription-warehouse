-- Cumulative LTV can only fall when a month's net revenue is negative (refunds exceed charges).
with ordered as (
    select
        cohort_month,
        months_since_acquisition,
        ltv_usd,
        net_revenue_usd,
        lag(ltv_usd) over (partition by cohort_month order by months_since_acquisition) as prev_ltv
    from {{ ref('mart_cohort_ltv') }}
)

select *
from ordered
where prev_ltv is not null
    and ltv_usd < prev_ltv
    and net_revenue_usd >= 0
