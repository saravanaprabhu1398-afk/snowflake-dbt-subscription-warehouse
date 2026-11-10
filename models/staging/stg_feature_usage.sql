with source as (
    select * from {{ source('landing', 'feature_usage') }}
    where {{ as_of_filter() }}
)

select
    usage_event_id,
    customer_id,
    device_id,
    platform,
    feature,
    cast(event_ts as timestamp) as event_ts,
    cast(cast(event_ts as timestamp) as date) as event_date,
    cast(duration_sec as integer) as duration_sec,
    cast(threats_blocked as integer) as threats_blocked,
    cast(_loaded_at as timestamp) as _loaded_at,
    cast(_load_date as date) as _load_date
from source
qualify row_number() over (partition by usage_event_id order by _loaded_at desc) = 1
