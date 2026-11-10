select
    plan_id as plan_key,
    plan_id,
    plan_name,
    tier,
    billing_period,
    billing_months,
    list_price_usd,
    cast(list_price_usd / billing_months as decimal(10, 2)) as monthly_equivalent_price_usd,
    max_devices,
    includes_vpn,
    includes_identity_protection,
    is_family_plan
from {{ ref('stg_plans') }}
