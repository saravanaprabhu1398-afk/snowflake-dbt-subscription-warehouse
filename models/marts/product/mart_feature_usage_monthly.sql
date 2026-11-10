-- Grain: month x feature x plan tier (customer's current plan).
-- adoption_rate = distinct users of the feature / distinct users active in the app that month (same tier).
with usage as (
    select
        f.customer_id,
        f.feature,
        f.threats_blocked,
        f.duration_sec,
        cast({{ dbt.date_trunc('month', 'f.event_date') }} as date) as usage_month,
        p.tier
    from {{ ref('fct_feature_usage') }} as f
    inner join {{ ref('int_subscriptions') }} as s on f.customer_id = s.customer_id
    inner join {{ ref('dim_plan') }} as p on s.current_plan_id = p.plan_key
),

monthly_active as (
    select
        usage_month,
        tier,
        count(distinct customer_id) as app_active_users
    from usage
    group by 1, 2
)

select
    u.usage_month,
    u.feature,
    u.tier,
    count(*) as usage_events,
    count(distinct u.customer_id) as feature_users,
    ma.app_active_users,
    cast(count(distinct u.customer_id) as decimal(18, 6)) / ma.app_active_users as adoption_rate,
    sum(u.threats_blocked) as threats_blocked,
    avg(u.duration_sec) as avg_duration_sec
from usage as u
inner join monthly_active as ma on u.usage_month = ma.usage_month and u.tier = ma.tier
group by u.usage_month, u.feature, u.tier, ma.app_active_users
