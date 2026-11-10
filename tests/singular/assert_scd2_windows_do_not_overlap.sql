-- Each customer's SCD2 versions must tile time: no overlaps, no gaps, exactly one current row.
with versions as (
    select
        customer_id,
        valid_from,
        valid_to,
        is_current,
        lead(valid_from) over (partition by customer_id order by valid_from) as next_valid_from
    from {{ ref('dim_customer') }}
),

bad_windows as (
    select
        customer_id,
        'gap_or_overlap' as issue
    from versions
    where next_valid_from is not null and next_valid_from <> valid_to
),

bad_current as (
    select
        customer_id,
        'current_count' as issue
    from versions
    group by customer_id
    having sum(case when is_current then 1 else 0 end) <> 1
)

select * from bad_windows
union all
select * from bad_current
