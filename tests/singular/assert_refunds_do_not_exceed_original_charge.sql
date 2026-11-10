-- A refund must reference a successful charge and never exceed it.
select
    r.payment_id as refund_id,
    r.refund_of_payment_id,
    r.amount_local as refund_amount,
    c.amount_local as charge_amount
from {{ ref('fct_payments') }} as r
left join {{ ref('fct_payments') }} as c on r.refund_of_payment_id = c.payment_id
where r.payment_type = 'refund'
    and (
        c.payment_id is null
        or c.status <> 'succeeded'
        or abs(r.amount_local) > c.amount_local
    )
