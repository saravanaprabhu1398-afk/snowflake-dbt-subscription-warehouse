{#
  On Snowflake, give BI roles USAGE on the schemas that hold marts, and nothing else.
  Table-level SELECT comes from the `grants` config on marts in dbt_project.yml.
  Staging, intermediate and snapshot schemas (raw PII, pre-masking logic) stay invisible.
#}
{% macro grant_mart_schema_usage(roles) -%}
    {%- if target.type != 'snowflake' or not execute -%}
        {{ return('select 1 as noop_grants') }}
    {%- endif -%}
    {%- set schemas = [] -%}
    {%- for node in graph.nodes.values() -%}
        {%- if node.resource_type == 'model' and node.fqn[1] == 'marts' -%}
            {%- set fq = node.database ~ '.' ~ node.schema -%}
            {%- if fq not in schemas -%}{%- do schemas.append(fq) -%}{%- endif -%}
        {%- endif -%}
    {%- endfor -%}
    {%- set statements = [] -%}
    {%- for schema in schemas -%}
        {%- for role in roles -%}
            {%- do statements.append('grant usage on schema ' ~ schema ~ ' to role ' ~ role) -%}
        {%- endfor -%}
    {%- endfor -%}
    {{ return(statements | join(';\n')) }}
{%- endmacro %}
