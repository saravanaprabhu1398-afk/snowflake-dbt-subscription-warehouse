-- Latest known profile per customer. Customers with a GDPR erasure request are
-- anonymised here, so no downstream rebuild can resurrect their PII.
with source as (
    select * from {{ source('landing', 'customers') }}
    where {{ as_of_filter() }}
),

latest as (
    select *
    from source
    qualify row_number() over (
            partition by customer_id order by cast(updated_at as timestamp) desc, _loaded_at desc
        ) = 1
),

erasure as (
    select customer_id from {{ ref('gdpr_erasure_requests') }}
)

select
    latest.customer_id,
    case when erasure.customer_id is null then lower(trim(latest.email)) end as email,
    case when erasure.customer_id is null then latest.first_name end as first_name,
    case when erasure.customer_id is null then latest.last_name end as last_name,
    case when erasure.customer_id is null then latest.phone end as phone,
    upper(latest.country_code) as country_code,
    cast(latest.marketing_opt_in as boolean) as marketing_opt_in,
    cast(latest.created_at as timestamp) as created_at,
    cast(latest.updated_at as timestamp) as updated_at,
    erasure.customer_id is not null as is_erased,
    cast(latest._loaded_at as timestamp) as _loaded_at,
    cast(latest._load_date as date) as _load_date
from latest
left join erasure on latest.customer_id = erasure.customer_id
