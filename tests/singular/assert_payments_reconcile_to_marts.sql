-- Revenue in the monthly mart must reconcile to the payments fact (to the cent).
with fact as (
    select sum(net_revenue_usd) as total from {{ ref('fct_payments') }}
),

mart as (
    select sum(net_revenue_usd) as total from {{ ref('mart_subscription_monthly') }}
)

select
    fact.total as fact_total,
    mart.total as mart_total
from fact
cross join mart
where abs(fact.total - mart.total) > 0.01
