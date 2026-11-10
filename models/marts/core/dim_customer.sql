{{ config(
    post_hook="{{ apply_masking_policies() }}",
    meta={'row_access_policy': 'customer_region_rap'},
    cluster_by=['customer_id']
) }}

-- SCD Type 2 customer dimension built from the snapshot.
-- The first version of each customer is opened at 1900-01-01 so facts that pre-date the
-- first captured profile still join (the initial backfill only saw the latest profile).
with snap as (
    select
        *,
        row_number() over (partition by customer_id order by dbt_valid_from) as version_number
    from {{ ref('snap_customers') }}
),

acquisition as (
    select
        customer_id,
        acquisition_channel,
        acquisition_utm_source
    from {{ ref('int_subscriptions') }}
    qualify row_number() over (partition by customer_id order by coalesce(trial_start_ts, paid_start_ts)) = 1
)

select
    snap.dbt_scd_id as customer_sk,
    snap.customer_id,
    snap.email,
    snap.first_name,
    snap.last_name,
    snap.phone,
    snap.country_code,
    cr.country_name,
    cr.region,
    cr.is_eu,
    cr.is_gdpr_scope,
    snap.marketing_opt_in,
    snap.created_at,
    acq.acquisition_channel,
    acq.acquisition_utm_source,
    snap.is_erased,
    snap.version_number,
    case when snap.version_number = 1 then cast('1900-01-01' as timestamp) else snap.dbt_valid_from end
        as valid_from,
    coalesce(snap.dbt_valid_to, cast('9999-12-31' as timestamp)) as valid_to,
    snap.dbt_valid_to is null as is_current
from snap
left join {{ ref('country_reference') }} as cr on snap.country_code = cr.country_code
left join acquisition as acq on snap.customer_id = acq.customer_id
