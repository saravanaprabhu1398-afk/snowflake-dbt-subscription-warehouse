-- Successful money movements converted to USD. Failed charges carry no revenue.
select
    p.payment_id,
    p.subscription_id,
    p.customer_id,
    p.plan_id,
    p.payment_ts,
    p.payment_date,
    p.payment_type,
    p.status,
    p.amount as amount_local,
    p.currency,
    cast(p.amount * fx.usd_per_unit as decimal(14, 4)) as amount_usd,
    case when p.status = 'succeeded' then cast(p.amount * fx.usd_per_unit as decimal(14, 4)) else 0 end
        as net_revenue_usd,
    p.payment_method,
    p.card_brand,
    p.card_last4,
    p.refund_of_payment_id,
    p._loaded_at,
    p._load_date
from {{ ref('stg_payments') }} as p
inner join {{ ref('fx_rates') }} as fx on p.currency = fx.currency
