-- Grain: feature. Did using a feature in the first 30 days of paid access go with lower
-- 6-month churn? Only customers whose paid start is >= 6 months before the end of data.
with subs as (
    select
        customer_id,
        paid_start_ts,
        cancel_ts,
        data_end_ts,
        current_plan_id
    from {{ ref('int_subscriptions') }}
    where paid_start_ts is not null
        and paid_start_ts <= {{ dbt.dateadd('month', -6, 'data_end_ts') }}
),

early_usage as (
    select distinct
        f.customer_id,
        f.feature
    from {{ ref('fct_feature_usage') }} as f
    inner join subs as s
        on f.customer_id = s.customer_id
            and f.event_ts >= s.paid_start_ts
            and f.event_ts < {{ dbt.dateadd('day', 30, 's.paid_start_ts') }}
),

features as (
    select distinct feature from {{ ref('fct_feature_usage') }}
),

base as (
    select
        f.feature,
        s.customer_id,
        eu.customer_id is not null as used_in_first_30d,
        s.cancel_ts is not null and s.cancel_ts < {{ dbt.dateadd('month', 6, 's.paid_start_ts') }} as churned_within_6m
    from subs as s
    cross join features as f
    left join early_usage as eu on s.customer_id = eu.customer_id and f.feature = eu.feature
)

select
    feature,
    used_in_first_30d,
    count(*) as customers,
    sum(case when churned_within_6m then 1 else 0 end) as churned_within_6m,
    cast(sum(case when churned_within_6m then 1 else 0 end) as decimal(18, 6)) / count(*) as churn_rate_6m
from base
group by feature, used_in_first_30d
