with source as (
    select * from {{ source('landing', 'payments') }}
    where {{ as_of_filter() }}
)

select
    payment_id,
    subscription_id,
    customer_id,
    plan_id,
    cast(payment_ts as timestamp) as payment_ts,
    cast(cast(payment_ts as timestamp) as date) as payment_date,
    payment_type,
    status,
    cast(amount as decimal(12, 2)) as amount,
    upper(currency) as currency,
    payment_method,
    card_brand,
    card_last4,
    psp_token,
    refund_of_payment_id,
    cast(_loaded_at as timestamp) as _loaded_at,
    cast(_load_date as date) as _load_date
from source
qualify row_number() over (partition by payment_id order by _loaded_at desc) = 1
