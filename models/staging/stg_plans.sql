with source as (
    select * from {{ source('landing', 'plans') }}
    where {{ as_of_filter() }}
    qualify row_number() over (partition by plan_id order by _loaded_at desc) = 1
)

select
    plan_id,
    plan_name,
    tier,
    billing_period,
    cast(list_price_usd as decimal(10, 2)) as list_price_usd,
    case billing_period when 'annual' then 12 else 1 end as billing_months,
    cast(max_devices as integer) as max_devices,
    cast(includes_vpn as boolean) as includes_vpn,
    cast(includes_identity_protection as boolean) as includes_identity_protection,
    cast(is_family_plan as boolean) as is_family_plan,
    cast(_loaded_at as timestamp) as _loaded_at
from source
