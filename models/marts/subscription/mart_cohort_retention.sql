-- Grain: paid cohort month x months since acquisition.
-- retention_rate = customers with paid access in month N / cohort size; churn_rate = 1 - retention.
with cm as (
    select * from {{ ref('int_customer_months') }}
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
    cm.cohort_month,
    cm.months_since_acquisition,
    cm.month_start as activity_month,
    cs.cohort_size,
    sum(case when cm.is_active then 1 else 0 end) as active_customers,
    cast(sum(case when cm.is_active then 1 else 0 end) as decimal(18, 6)) / cs.cohort_size as retention_rate,
    1 - cast(sum(case when cm.is_active then 1 else 0 end) as decimal(18, 6)) / cs.cohort_size as churn_rate
from cm
inner join cohort_size as cs on cm.cohort_month = cs.cohort_month
group by 1, 2, 3, 4
