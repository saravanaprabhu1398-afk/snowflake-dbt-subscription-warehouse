{#
  Adapter dispatch examples: the same model SQL compiles to Snowflake or DuckDB syntax.
#}

{# ISO day of week, Monday = 1 .. Sunday = 7 #}
{% macro iso_day_of_week(col) -%}
    {{ return(adapter.dispatch('iso_day_of_week', 'subscription_warehouse')(col)) }}
{%- endmacro %}
{% macro default__iso_day_of_week(col) -%} extract(isodow from {{ col }}) {%- endmacro %}
{% macro snowflake__iso_day_of_week(col) -%} dayofweekiso({{ col }}) {%- endmacro %}

{# Three-letter day name, e.g. Mon #}
{% macro day_name_short(col) -%}
    {{ return(adapter.dispatch('day_name_short', 'subscription_warehouse')(col)) }}
{%- endmacro %}
{% macro default__day_name_short(col) -%} strftime({{ col }}, '%a') {%- endmacro %}
{% macro snowflake__day_name_short(col) -%} dayname({{ col }}) {%- endmacro %}

{# Three-letter month name, e.g. Jan #}
{% macro month_name_short(col) -%}
    {{ return(adapter.dispatch('month_name_short', 'subscription_warehouse')(col)) }}
{%- endmacro %}
{% macro default__month_name_short(col) -%} strftime({{ col }}, '%b') {%- endmacro %}
{% macro snowflake__month_name_short(col) -%} monthname({{ col }}) {%- endmacro %}

{# Whole months between two dates (month boundaries crossed) #}
{% macro months_between_dates(start_col, end_col) -%}
    {{ dbt.datediff(start_col, end_col, 'month') }}
{%- endmacro %}

{# Integer surrogate date key yyyymmdd #}
{% macro date_key(col) -%}
    cast(extract(year from {{ col }}) * 10000 + extract(month from {{ col }}) * 100 + extract(day from {{ col }}) as integer)
{%- endmacro %}
