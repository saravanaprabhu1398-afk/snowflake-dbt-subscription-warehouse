-- Governance smoke test: run once per role (`make sf-verify` does this).
-- ANALYST:     emails masked to the domain, names hashed, no GDPR-scope countries.
-- ANALYST_EU:  masked PII, GDPR-scope countries visible.
-- PII_READER:  clear PII, all countries.
-- Secondary roles off, so only the role under test is in the session.
use secondary roles none;

select
    current_role() as role,
    count(*) as visible_customer_versions,
    count_if(country_code in ('GB', 'DE', 'FR', 'NL', 'ES', 'IT', 'IE', 'SE')) as gdpr_scope_rows,
    max(email) as sample_email,
    max(first_name) as sample_first_name
from analytics.core.dim_customer
where email is not null;
