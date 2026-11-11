-- =============================================================================
-- 04 Governance: classification tags, tag-based masking, row access policy,
--    right-to-erasure procedure and audit trail.
-- =============================================================================

use role accountadmin;   -- in practice a dedicated GOVERNANCE_ADMIN role with APPLY MASKING/ROW ACCESS POLICY

-- -----------------------------------------------------------------------------
-- Classification tags
-- -----------------------------------------------------------------------------
create tag if not exists governance.tags.pii_type
    allowed_values 'email', 'name', 'phone', 'address', 'ip_address'
    comment = 'Personal data category (GDPR Art. 4). Drives tag-based masking.';

create tag if not exists governance.tags.data_sensitivity
    allowed_values 'public', 'internal', 'confidential', 'restricted'
    comment = 'Company data classification level.';

alter table raw.landing.customers set tag governance.tags.data_sensitivity = 'restricted';
alter table raw.landing.payments set tag governance.tags.data_sensitivity = 'confidential';
alter table raw.landing.customers modify column email set tag governance.tags.pii_type = 'email';
alter table raw.landing.customers modify column first_name set tag governance.tags.pii_type = 'name';
alter table raw.landing.customers modify column last_name set tag governance.tags.pii_type = 'name';
alter table raw.landing.customers modify column phone set tag governance.tags.pii_type = 'phone';
-- dbt post-hook apply_masking_policies() tags the dim_customer columns from model YAML meta.

-- Optional: let Snowflake suggest classifications for new tables.
-- call system$classify('analytics.core.dim_customer', {'auto_tag': false});

-- -----------------------------------------------------------------------------
-- Masking policies
-- -----------------------------------------------------------------------------
create masking policy if not exists governance.policies.mask_email as (val varchar)
returns varchar ->
    case
        when is_role_in_session('PII_READER') then val
        when is_role_in_session('TRANSFORMER') then val                 -- dbt must read to build
        when val is null then null
        else regexp_replace(val, '^[^@]+', '*****')                      -- keeps domain for analytics
    end
    comment = 'Email: full for PII_READER, domain-only for everyone else';

create masking policy if not exists governance.policies.mask_pii_string as (val varchar)
returns varchar ->
    case
        when is_role_in_session('PII_READER') then val
        when is_role_in_session('TRANSFORMER') then val
        when val is null then null
        else sha2(val || 'rotate-me-via-secret', 256)                    -- stable pseudonym, joinable
    end
    comment = 'Names/phones: deterministic hash for non-PII roles';

-- Tag-based masking: any column tagged pii_type gets the string policy automatically,
-- including new columns nobody remembered to mask. Explicit column policies win.
alter tag governance.tags.pii_type set masking policy governance.policies.mask_pii_string;

-- -----------------------------------------------------------------------------
-- Row access policy: EU/GDPR-scope rows only for roles cleared for them.
-- Mapping table instead of hard-coded roles so access changes are data, not DDL.
-- -----------------------------------------------------------------------------
create table if not exists governance.policies.region_access_map (
    role_name varchar,
    gdpr_scope_allowed boolean
);
merge into governance.policies.region_access_map t
using (
    select column1 as role_name, column2 as gdpr_scope_allowed
    from values ('ANALYST_EU', true), ('PII_READER', true), ('TRANSFORMER', true), ('ANALYST', false)
) s on t.role_name = s.role_name
when matched then update set gdpr_scope_allowed = s.gdpr_scope_allowed
when not matched then insert values (s.role_name, s.gdpr_scope_allowed);

create row access policy if not exists governance.policies.customer_region_rap
as (country_code varchar) returns boolean ->
    -- non-GDPR rows: visible to all roles that can see the table
    country_code not in ('GB', 'DE', 'FR', 'NL', 'ES', 'IT', 'IE', 'SE')
    or exists (
        select 1
        from governance.policies.region_access_map m
        where is_role_in_session(m.role_name) and m.gdpr_scope_allowed
    )
    comment = 'GDPR-scope customers visible only to EU-cleared roles';
-- dbt attaches it to dim_customer (meta.row_access_policy) via apply_masking_policies().

grant apply masking policy on account to role transformer;
grant apply row access policy on account to role transformer;
grant apply tag on account to role transformer;
grant usage on database governance to role transformer;
grant usage on schema governance.policies to role transformer;
grant usage on schema governance.tags to role transformer;
grant select on governance.policies.region_access_map to role transformer;

-- -----------------------------------------------------------------------------
-- Right to erasure (GDPR Art. 17)
--   1. Request is recorded (privacy portal -> governance.privacy.erasure_requests).
--   2. This procedure scrubs PII in RAW, the snapshot history and the dimension now.
--   3. dbt staging anonymises requested customers on every build, so a full refresh
--      cannot resurrect them; the snapshot post-hook re-scrubs history.
--   4. Short Time Travel on RAW.LANDING (1 day) means old values age out; Fail-safe
--      (7 days, Snowflake-only access) is documented in the ROPA.
--   Financial records (payments) keep the pseudonymous customer_id: retained under
--   the legal obligation basis (tax/accounting), with no direct identifiers attached.
-- -----------------------------------------------------------------------------
create table if not exists governance.privacy.erasure_requests (
    customer_id varchar not null,
    requested_at timestamp_ltz not null,
    request_source varchar,
    completed_at timestamp_ltz,
    completed_by varchar
);

create table if not exists governance.privacy.erasure_log (
    customer_id_hash varchar,       -- sha2 of the id, so the log itself holds no identifier
    relation_name varchar,
    rows_affected number,
    executed_at timestamp_ltz,
    executed_by varchar
);

create or replace procedure governance.privacy.erase_customer(p_customer_id varchar)
returns varchar
language sql
execute as owner
as
$$
declare
    n_raw number default 0;
    n_snap number default 0;
    n_dim number default 0;
begin
    update raw.landing.customers
        set email = null, first_name = null, last_name = null, phone = null
        where customer_id = :p_customer_id;
    n_raw := sqlrowcount;

    update analytics.snapshots.snap_customers
        set email = null, first_name = null, last_name = null, phone = null, is_erased = true
        where customer_id = :p_customer_id;
    n_snap := sqlrowcount;

    update analytics.core.dim_customer
        set email = null, first_name = null, last_name = null, phone = null, is_erased = true
        where customer_id = :p_customer_id;
    n_dim := sqlrowcount;

    insert into governance.privacy.erasure_log
        select sha2(:p_customer_id, 256), column1, column2, current_timestamp(), current_user()
        from values ('raw.landing.customers', :n_raw),
                    ('analytics.snapshots.snap_customers', :n_snap),
                    ('analytics.core.dim_customer', :n_dim);

    update governance.privacy.erasure_requests
        set completed_at = current_timestamp(), completed_by = current_user()
        where customer_id = :p_customer_id and completed_at is null;

    return 'erased: raw=' || n_raw || ' snapshot=' || n_snap || ' dim=' || n_dim;
end;
$$;

grant usage on procedure governance.privacy.erase_customer(varchar) to role privacy_officer;

-- Process all open requests (scheduled daily with a task):
create or replace task governance.privacy.process_erasure_requests
    warehouse = transform_wh_s
    schedule = 'USING CRON 0 3 * * * UTC'
as
    execute immediate $$
    declare
        c cursor for select distinct customer_id from governance.privacy.erasure_requests where completed_at is null;
    begin
        for r in c do
            call governance.privacy.erase_customer(r.customer_id);
        end for;
    end;
    $$;

-- Tasks are created suspended. Daily on an XSMALL warehouse, ~1 minute.
alter task governance.privacy.process_erasure_requests resume;

-- Audit: who read PII columns in the last 7 days (Enterprise edition ACCESS_HISTORY).
select
    ah.query_start_time,
    ah.user_name,
    obj.value:"objectName"::varchar as object_name,
    col.value:"columnName"::varchar as column_name
from snowflake.account_usage.access_history as ah,
    lateral flatten(ah.base_objects_accessed) as obj,
    lateral flatten(obj.value:"columns") as col
where ah.query_start_time >= dateadd(day, -7, current_timestamp())
  and object_name ilike '%DIM_CUSTOMER'
  and column_name in ('EMAIL', 'FIRST_NAME', 'LAST_NAME', 'PHONE');
