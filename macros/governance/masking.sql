{#
  Post-hook: attach column-level masking policies on Snowflake. No-op on DuckDB.
  Policies are created by snowflake/04_governance.sql. Columns are declared in model YAML
  under meta.masking_policy so classification lives next to the column docs.
#}
{% macro apply_masking_policies() -%}
    {%- if target.type != 'snowflake' -%}
        {{ return('select 1 as noop_masking') }}
    {%- endif -%}
    {%- set statements = [] -%}
    {%- for col_name, col in model.columns.items() -%}
        {%- set policy = col.meta.get('masking_policy') -%}
        {%- if policy -%}
            {%- do statements.append(
                "alter table " ~ this ~ " modify column " ~ col_name ~
                " set masking policy GOVERNANCE.POLICIES." ~ policy ~ " force") -%}
        {%- endif -%}
        {%- set pii = col.meta.get('pii_type') -%}
        {%- if pii -%}
            {%- do statements.append(
                "alter table " ~ this ~ " modify column " ~ col_name ~
                " set tag GOVERNANCE.TAGS.PII_TYPE = '" ~ pii ~ "'") -%}
        {%- endif -%}
    {%- endfor -%}
    {%- if model.config.meta.get('row_access_policy') -%}
        {%- do statements.append(
            "alter table " ~ this ~ " drop all row access policies") -%}
        {%- do statements.append(
            "alter table " ~ this ~ " add row access policy GOVERNANCE.POLICIES." ~
            model.config.meta.get('row_access_policy') ~ " on (country_code)") -%}
    {%- endif -%}
    {{ return(statements | join(';\n') if statements else 'select 1 as noop_masking') }}
{%- endmacro %}

{#
  Removes PII from every snapshot version of customers with an erasure request.
  Runs as a snapshot post-hook on both adapters (plain UPDATE). In Snowflake the
  GOVERNANCE.ERASE_CUSTOMER procedure does the same for RAW tables and Time Travel.
#}
{% macro scrub_erased_customers(relation) -%}
    update {{ relation }}
    set email = null, first_name = null, last_name = null, phone = null, is_erased = true
    where customer_id in (select customer_id from {{ ref('gdpr_erasure_requests') }})
      and (email is not null or first_name is not null or last_name is not null or phone is not null)
{%- endmacro %}
