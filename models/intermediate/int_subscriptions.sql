-- One row per subscription with its paid-access window.
-- Billing anchors (start, renewal, upgrade) restart the billing period; access runs until
-- the last anchor + billing months, except involuntary churn (payment_failed) which ends
-- access immediately.
with events as (
    select
        e.*,
        p.billing_months
    from {{ ref('stg_subscription_events') }} as e
    inner join {{ ref('stg_plans') }} as p on e.plan_id = p.plan_id
),

data_end as (
    select max(event_ts) as data_end_ts from {{ ref('stg_subscription_events') }}
),

first_touch as (
    select
        subscription_id,
        channel as acquisition_channel,
        utm_source as acquisition_utm_source,
        plan_id as initial_plan_id
    from events
    where event_type in ('trial_start', 'subscription_start')
    qualify row_number() over (partition by subscription_id order by event_ts) = 1
),

last_anchor as (
    select
        subscription_id,
        event_ts as last_anchor_ts,
        plan_id as current_plan_id,
        billing_months
    from events
    where event_type in ('subscription_start', 'renewal', 'upgrade')
    qualify row_number() over (partition by subscription_id order by event_ts desc) = 1
),

rollup as (
    select
        subscription_id,
        min(customer_id) as customer_id,
        min(case when event_type = 'trial_start' then event_ts end) as trial_start_ts,
        min(case when event_type = 'trial_expired' then event_ts end) as trial_expired_ts,
        min(case when event_type = 'subscription_start' then event_ts end) as paid_start_ts,
        max(case when event_type = 'cancel' then event_ts end) as cancel_ts,
        max(case when event_type = 'cancel' then cancel_reason end) as cancel_reason,
        sum(case when event_type = 'renewal' then 1 else 0 end) as renewal_count,
        sum(case when event_type = 'upgrade' then 1 else 0 end) as upgrade_count,
        sum(case when event_type = 'downgrade' then 1 else 0 end) as downgrade_count
    from events
    group by subscription_id
)

select
    r.subscription_id,
    r.customer_id,
    ft.acquisition_channel,
    ft.acquisition_utm_source,
    ft.initial_plan_id,
    coalesce(la.current_plan_id, ft.initial_plan_id) as current_plan_id,
    r.trial_start_ts,
    r.trial_expired_ts,
    r.paid_start_ts,
    r.trial_start_ts is not null and r.paid_start_ts is not null as converted_from_trial,
    r.cancel_ts,
    r.cancel_reason,
    case
        when r.paid_start_ts is null then null
        when r.cancel_reason = 'payment_failed' then r.cancel_ts
        when r.cancel_ts is not null then {{ dbt.dateadd('month', 'la.billing_months', 'la.last_anchor_ts') }}
        else least(
                {{ dbt.dateadd('month', 'la.billing_months', 'la.last_anchor_ts') }},
                de.data_end_ts
            )
    end as paid_access_end_ts,
    case
        when r.paid_start_ts is null and r.trial_expired_ts is not null then 'trial_expired'
        when r.paid_start_ts is null then 'in_trial'
        when r.cancel_ts is not null then 'cancelled'
        else 'active'
    end as subscription_status,
    r.renewal_count,
    r.upgrade_count,
    r.downgrade_count,
    de.data_end_ts
from rollup as r
left join first_touch as ft on r.subscription_id = ft.subscription_id
left join last_anchor as la on r.subscription_id = la.subscription_id
cross join data_end as de
