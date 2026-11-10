{{ config(materialized='table') }}

with spine as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2023-01-01' as date)",
        end_date="cast('2027-01-01' as date)"
    ) }}
),

days as (
    select cast(date_day as date) as date_day from spine
)

select
    {{ date_key('date_day') }} as date_key,
    date_day,
    cast(extract(year from date_day) as integer) as year_number,
    cast(extract(quarter from date_day) as integer) as quarter_number,
    cast(extract(month from date_day) as integer) as month_number,
    {{ month_name_short('date_day') }} as month_name,
    cast(extract(day from date_day) as integer) as day_of_month,
    cast({{ iso_day_of_week('date_day') }} as integer) as iso_day_of_week,
    {{ day_name_short('date_day') }} as day_name,
    {{ iso_day_of_week('date_day') }} in (6, 7) as is_weekend,
    cast({{ dbt.date_trunc('week', 'date_day') }} as date) as week_start_date,
    cast({{ dbt.date_trunc('month', 'date_day') }} as date) as month_start_date,
    cast({{ dbt.date_trunc('quarter', 'date_day') }} as date) as quarter_start_date,
    cast({{ dbt.date_trunc('year', 'date_day') }} as date) as year_start_date
from days
