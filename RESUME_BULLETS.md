# Resume bullets: Subscription Analytics Warehouse (personal project)

Personal portfolio project, built on synthetic data; not production work. Numbers come from
local runs on DuckDB recorded in `docs/benchmark.md` and `docs/benchmark-100k.md`. The
Snowflake, Snowpipe and Terraform parts are written and validated (`terraform validate`) but
were not run against a Snowflake or AWS account.

- Built a Kimball-style subscription analytics warehouse in dbt for a synthetic consumer
  security app: SCD2 customer snapshot, 3 conformed dimensions, 3 incremental MERGE fact tables
  and cohort retention/churn, cohort LTV, trial-conversion and feature-adoption marts, covered
  by 93 data tests and 2 unit tests; on ~5.8M synthetic landing rows each `dbt build`
  (backfill, then incremental load) finished in under 7 s on DuckDB; on the 20k-customer
  dataset the incremental replay matched a one-shot full build row for row.
- Designed the Snowflake side as code: S3 landing zone with Snowpipe auto-ingest, storage
  integration and IAM in Terraform, workload-isolated warehouses with auto-suspend, resource
  monitors and per-model JSON query tags, plus clustering keys on the large date-filtered facts.
- Implemented GDPR controls (tag-based dynamic masking, a row access policy for EU/UK
  customers, and a right-to-erasure procedure backed by a dbt test that fails the build if
  erased PII reappears), wrote an RFC (design, alternatives, rollout), and set up GitHub
  Actions CI with sqlfluff and slim `state:modified` dbt builds.
