-- GDPR Art. 17: no version of an erased customer may hold PII, in the dimension or the snapshot.
select
    'dim_customer' as relation_name,
    d.customer_id
from {{ ref('dim_customer') }} as d
inner join {{ ref('gdpr_erasure_requests') }} as r on d.customer_id = r.customer_id
where d.email is not null or d.first_name is not null or d.last_name is not null or d.phone is not null

union all

select
    'snap_customers' as relation_name,
    s.customer_id
from {{ ref('snap_customers') }} as s
inner join {{ ref('gdpr_erasure_requests') }} as r on s.customer_id = r.customer_id
where s.email is not null or s.first_name is not null or s.last_name is not null or s.phone is not null
