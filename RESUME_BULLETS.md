# Resume bullets: Subscription Analytics Warehouse (personal project)

Personal portfolio project, built on synthetic data; not production work. DuckDB numbers come
from `docs/benchmark.md` and `docs/benchmark-100k.md`. Snowflake numbers come from deploying it
to a personal Snowflake Enterprise trial account plus an AWS S3 bucket (README, "Snowflake
results"), at 20k synthetic customers (~1.1M rows).

- Built a Kimball-style subscription analytics warehouse in dbt for a synthetic consumer
  security app: SCD2 customer snapshot, 3 conformed dimensions, 3 incremental MERGE fact tables
  and cohort retention/churn, cohort LTV, trial-conversion and feature-adoption marts, covered
  by 93 data tests and 2 unit tests; on ~5.8M synthetic landing rows each `dbt build`
  (backfill, then incremental load) finished in under 7 s on DuckDB; on the 20k-customer
  dataset the incremental replay matched a one-shot full build row for row.
- Deployed it to Snowflake with Terraform (75 AWS + Snowflake resources: KMS-encrypted S3
  landing zone, IAM role and storage integration, auto-ingest Snowpipe, RAW tables, XSMALL
  workload warehouses with resource monitors, RBAC roles and grants, key-pair-only dbt service
  user); Snowpipe landed ~1.1M rows within about 30 s of upload, the prod `dbt build` passed
  all 119 nodes in under 30 s per load, and every table matched the DuckDB run row for row
  (net revenue equal to the cent), for about 0.16 warehouse credits.
- Implemented GDPR controls (tag-based dynamic masking, a row access policy for EU/UK
  customers, and a right-to-erasure procedure backed by a dbt test that fails the build if
  erased PII reappears), verified live in Snowflake: the same query returns 12,259 rows with
  masked emails for ANALYST, 20,408 masked for ANALYST_EU and clear PII only for PII_READER; wrote an RFC (design, alternatives, rollout), and set up GitHub
  Actions CI with sqlfluff and slim `state:modified` dbt builds.
- Orchestrated the daily prod run in Airflow 3 with Astronomer Cosmos (one task per dbt
  model with tests after each, retries with backoff, webhook failure alerts): a
  reschedule-mode sensor waits on Snowpipe's copy history and pipe backlog, using no warehouse
  while it waits; the local run against Snowflake completed all 57 tasks on the first try in
  about 4 minutes, and replaying an already-loaded partition left every fact count unchanged.
