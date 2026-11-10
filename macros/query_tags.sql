{#
  Cost attribution. Every dbt statement carries a JSON comment and, on Snowflake, a
  QUERY_TAG, so ACCOUNT_USAGE.QUERY_HISTORY can be grouped by model, layer and run.
#}
{% macro query_comment(node) -%}
    {%- set comment = {
        "app": "dbt",
        "project": project_name,
        "target": target.name,
        "invocation_id": invocation_id,
    } -%}
    {%- if node is not none -%}
        {%- do comment.update({"node_id": node.unique_id, "resource_type": node.resource_type}) -%}
    {%- endif -%}
    {{ return(tojson(comment)) }}
{%- endmacro %}

{% macro set_query_tag_for_run() -%}
    {%- if target.type == 'snowflake' -%}
        alter session set query_tag = '{{ tojson({"app": "dbt", "project": project_name, "target": target.name, "invocation_id": invocation_id}) }}'
    {%- else -%}
        select 1 as noop_query_tag
    {%- endif -%}
{%- endmacro %}

{# dbt-snowflake calls this per model; tag = layer + model so warehouse spend splits by layer. #}
{% macro set_query_tag() -%}
    {%- set original = get_current_query_tag() -%}
    {%- set layer = model.fqn[1] if model.fqn | length > 2 else 'root' -%}
    {%- set tag = tojson({"app": "dbt", "layer": layer, "model": model.name, "target": target.name, "invocation_id": invocation_id}) -%}
    {% do run_query("alter session set query_tag = '{}'".format(tag)) %}
    {{ return(original) }}
{%- endmacro %}
