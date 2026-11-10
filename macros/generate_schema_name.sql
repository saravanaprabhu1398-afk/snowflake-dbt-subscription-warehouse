{#
  DuckDB (local/CI) and Snowflake prod: use the folder schema as-is (core, subscription, ...).
  Snowflake dev targets: prefix with the developer schema so people never collide.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- elif target.type == 'duckdb' or target.name == 'prod' -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ target.schema }}_{{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
