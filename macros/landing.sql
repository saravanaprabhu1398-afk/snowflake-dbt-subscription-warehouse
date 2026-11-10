{#
  Incremental filter on the landing partition date with a look-back window, so late files
  in recent partitions are picked up again (the MERGE makes the reprocessing idempotent).
#}
{% macro incremental_load_filter(load_date_col='_load_date') -%}
    {%- if is_incremental() -%}
    and {{ load_date_col }} >= (
        select {{ dbt.dateadd('day', -1 * var('incremental_lookback_days'), 'max(' ~ load_date_col ~ ')') }}
        from {{ this }}
    )
    {%- endif -%}
{%- endmacro %}

{% macro as_of_filter(load_date_col='_load_date') -%}
    {{ load_date_col }} <= cast('{{ var("as_of_load_date") }}' as date)
{%- endmacro %}
