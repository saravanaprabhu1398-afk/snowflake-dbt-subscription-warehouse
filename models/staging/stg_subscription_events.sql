with source as (
    select * from {{ source('landing', 'subscription_events') }}
    where {{ as_of_filter() }}
)

select
    event_id,
    subscription_id,
    customer_id,
    plan_id,
    previous_plan_id,
    event_type,
    cast(event_ts as timestamp) as event_ts,
    cast(cast(event_ts as timestamp) as date) as event_date,
    channel,
    utm_source,
    cancel_reason,
    cast(_loaded_at as timestamp) as _loaded_at,
    cast(_load_date as date) as _load_date
from source
-- exactly-once: Snowpipe can deliver a file twice after a retry
qualify row_number() over (partition by event_id order by _loaded_at desc) = 1
