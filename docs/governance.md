# Data governance: GDPR and PCI-DSS

SQL in `snowflake/04_governance.sql`; dbt hooks in `macros/governance/masking.sql`.

## Classification

- Tag `GOVERNANCE.TAGS.PII_TYPE` (`email`, `name`, `phone`, ...) on PII columns and
  `DATA_SENSITIVITY` on tables.
- Classification lives in dbt YAML (`meta: {pii_type: email, masking_policy: mask_email}` on
  `dim_customer` columns). The `apply_masking_policies()` post-hook turns that into
  `ALTER TABLE ... SET TAG` / `SET MASKING POLICY` on Snowflake, so docs and enforcement cannot
  drift. On DuckDB the hook is a no-op.

## Dynamic masking

| Policy | Unmasked for | Others see |
|---|---|---|
| `mask_email` | `PII_READER`, `TRANSFORMER` | `*****@domain` (domain kept for analytics) |
| `mask_pii_string` | `PII_READER`, `TRANSFORMER` | SHA-256 pseudonym (stable, joinable) |

`mask_pii_string` is also attached to the `PII_TYPE` tag (tag-based masking), so a newly tagged
PII column is masked even if nobody adds a column policy.

## Row access

`customer_region_rap` on `dim_customer(country_code)`: customers in GDPR scope
(EU + UK) are visible only to roles mapped `gdpr_scope_allowed = true` in
`GOVERNANCE.POLICIES.REGION_ACCESS_MAP`. Access changes are a row update, not DDL.

## Right to erasure (Art. 17)

Erasure has to survive rebuilds, not only delete once. Three layers:

1. **Source of truth for requests**: `GOVERNANCE.PRIVACY.ERASURE_REQUESTS` in Snowflake
   (locally the `gdpr_erasure_requests` seed stands in for it).
2. **Procedure** `GOVERNANCE.PRIVACY.ERASE_CUSTOMER(id)`: nulls PII in `RAW.LANDING.CUSTOMERS`,
   every version in the SCD2 snapshot and `dim_customer`; writes an audit row with a hashed id
   and row counts; marks the request complete. A daily task processes open requests.
3. **Anonymise by design in dbt**: `stg_customers` nulls PII for requested ids on every run, and
   the snapshot post-hook `scrub_erased_customers` re-scrubs history. A full refresh therefore
   cannot bring PII back. The singular test `assert_erased_customers_have_no_pii` fails the
   build if any version of an erased customer still holds PII (in both dim and snapshot).

Retention: RAW customer tables have 1-day Time Travel; S3 customer files expire after 30 days
(Terraform lifecycle rule). Snowflake Fail-safe (7 days, not user-accessible) should be
recorded in the ROPA. Payment rows keep the pseudonymous `customer_id` because accounting law
requires keeping financial records; no direct identifiers remain attached.

## PCI-DSS note: payment data

- The warehouse **never receives cardholder data** beyond what PCI-DSS allows outside the CDE:
  no PAN, no CVV/CVC, no expiry date, no track data. Payment rows hold a **PSP token**, the
  **card brand** and the **last four digits** (PCI-DSS permits storing first-six/last-four
  without rendering them unreadable).
- This keeps Snowflake, S3 landing and dbt out of cardholder-data-environment scope; the PSP
  (tokenisation) is the CDE.
- Controls that still apply: the payments landing table is tagged `confidential`; a dbt test
  checks `card_last4` is null or exactly 4 characters, so a mis-mapped PAN column would fail
  the build; the PSP token is not a secret on its own but is still restricted to
  `TRANSFORMER`/finance roles.
- If a future feed ever needs full PANs, it must stay in the PSP vault, not be landed here.
