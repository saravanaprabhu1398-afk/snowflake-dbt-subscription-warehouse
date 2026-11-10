# RFC-001: Subscription analytics warehouse on Snowflake + dbt

| | |
|---|---|
| Status | Draft (portfolio project) |
| Author | Prabhu Saravanan |
| Scope | Subscription, payment and feature-usage analytics for a consumer security app |

## 1. Problem

A consumer security product sells monthly and annual plans (basic → family) through web,
app stores and partner bundles, with free trials. Today the questions below are answered
by ad-hoc queries over service databases, and the answers disagree:

- How many trials convert, by channel and campaign?
- What share of each monthly acquisition cohort is still paying after N months?
- What is realised lifetime value per cohort, and does it pay back acquisition cost?
- Which features are used, by which plan tiers, and does early feature use relate to churn?

Constraints:

- Customer data includes PII for EU/UK customers (GDPR): masking, regional access control and
  erasure that survives rebuilds are required.
- Payment data must stay out of PCI-DSS cardholder-data scope.
- One definition per metric, tested, documented and reviewed like code.
- Cost must be attributable and bounded.

## 2. Goals and non-goals

Goals
- A Kimball star schema with conformed dimensions for subscription events, payments and usage.
- Metric marts: acquisition cohorts, retention / churn, cohort LTV, feature adoption.
- Incremental, idempotent loads; SCD2 customer history.
- Governance built in (classification, masking, row access, erasure, audit).
- CI on every PR without needing a Snowflake account.

Non-goals
- Real-time (sub-minute) dashboards. Hourly-to-daily freshness is enough for these decisions.
- Predictive LTV / churn models (a later RFC; these marts are their training inputs).
- Marketing spend ingestion (CAC); the LTV mart is built so CAC can be joined by channel later.

## 3. Design

### 3.1 Ingestion
Producers write parquet to `s3://<bucket>/landing/<feed>/_load_date=YYYY-MM-DD/`. One
auto-ingest Snowpipe per feed loads into `RAW.LANDING.<feed>` (all VARCHAR plus
`_source_file`, `_ingested_at`). Raw is schema-on-read: type errors surface in dbt tests,
not as rejected files, and the landing bucket remains a replayable log.

### 3.2 Modelling layers

| Layer | Materialisation | Responsibility |
|---|---|---|
| staging | views | Cast types, dedup on natural key (`qualify row_number()`), anonymise erased customers |
| snapshot | dbt snapshot (timestamp strategy) | SCD2 history of customer profile |
| intermediate | ephemeral / table | Subscription lifecycle, customer x month grid, FX to USD |
| core | tables + incremental facts (MERGE) | Star schema |
| marts | tables | Metric definitions consumed by BI |

**Grain decisions**

- `fct_subscription_events`: one row per lifecycle event (trial_start, trial_expired,
  subscription_start, renewal, upgrade, downgrade, cancel).
- `fct_payments`: one row per payment attempt, including failures and refunds (negative).
- `fct_feature_usage`: one row per interaction (largest table).
- `dim_customer`: one row per customer version (SCD2). Facts resolve `customer_sk`
  point-in-time at load, so revenue by country uses the country the customer had at that
  time. The first version is opened at 1900-01-01 because the initial backfill only sees the
  latest profile.
- `dim_plan`, `dim_date` (yyyymmdd integer key).

**Metric definitions** (tested; unit tests cover the arithmetic)

- *Cohort* = calendar month of the customer's first paid start.
- *Active in month M* = the customer had paid access on at least one day of M. Paid access runs
  from paid start to last billing anchor (start/renewal/upgrade) + billing period; involuntary
  churn (payment failed) ends access at the failure.
- *Retention(N)* = active customers in month N / cohort size; *churn(N)* = 1 − retention(N).
- *Logo churn (monthly)* = active last month and not this month / active last month.
- *Realised LTV(N)* = cumulative net revenue (charges − refunds, USD) of the cohort through
  month N / cohort size.
- *Trial conversion* = trials with a later paid start / trials started, by acquisition month,
  channel and UTM source.

### 3.3 Incremental strategy
Facts use `incremental_strategy='merge'` on the natural key with a filter on landing partition
date and a 3-day look-back. Re-delivered files and late data are absorbed idempotently;
`on_schema_change='append_new_columns'` avoids full refreshes for additive changes.
Validated locally by replaying load 1 (backfill) then load 2 (one month delta) and comparing
results with a single full build.

### 3.4 Performance and cost
Workload-isolated warehouses (load XS, transform S/M, BI S multi-cluster), 60 s auto-suspend
for bursty work, 300 s for BI cache, resource monitors per workload, JSON query tags per dbt
model, clustering only on the large date-filtered facts. Details:
`docs/snowflake-performance-and-cost.md`.

### 3.5 Governance
Tags + tag-based masking, column masking policies declared in dbt YAML and applied by
post-hook, a row access policy driven by a role→region mapping table, and a three-layer
erasure design (procedure, anonymise-in-staging, snapshot scrub) with a test that fails the
build on leaked PII. Payments hold only PSP token + brand + last four. Details:
`docs/governance.md`.

### 3.6 Dev workflow
Trunk-based development (CONTRIBUTING.md). The project runs on DuckDB (`dbt-duckdb`) with the
same SQL as Snowflake; adapter differences go through `adapter.dispatch` macros. PR CI:
sqlfluff, then `dbt build --select +state:modified+` against the last main manifest. Main:
full build, incremental replay, source freshness, docs, manifest artifact for the next PR.
Snowflake deploy is a gated job (`--select state:modified+` against prod state).

## 4. Alternatives considered

| Option | Why not (for now) |
|---|---|
| **One big table per metric, no star schema** | Fast to start, but every metric re-derives subscription status and customer attributes; definitions drift. The star schema keeps one place for lifecycle logic and one conformed customer dimension. |
| **Data vault before the star schema** | Better for many volatile sources and full auditability; overkill for five well-owned feeds. The landing bucket + RAW tables already give replay and lineage. Revisit if source count grows a lot. |
| **SCD2 built in SQL instead of dbt snapshot** | Custom SQL can backfill exact historical validity from a CDC log; snapshots only capture changes seen at run time. Snapshots are simpler and standard; the 1900-01-01 opening of the first version covers the backfill gap. If the account service exposes a full change log, build SCD2 from it instead. |
| **Iceberg tables on S3 (Snowflake-managed or external catalog)** | Open format, shared with Spark/Trino. Worth it if other engines need these tables; today only Snowflake + BI read them, and native tables give clustering, search optimisation and simpler governance. A follow-up could publish the core facts as Iceberg. |
| **Kafka → Snowpipe Streaming instead of S3 + Snowpipe** | Seconds-level latency, but adds an always-on connector to operate. Daily/hourly freshness meets the goals; the RAW contract stays the same if streaming is added later for telemetry. |
| **Dynamic tables instead of dbt incremental models** | Declarative refresh with target lag. Attractive for the marts; kept in dbt for now so tests, docs, slim CI and the DuckDB local path work the same everywhere. |
| **Snowflake-only dev (zero-copy clone per PR)** | Most faithful, but costs credits per PR and needs an account for every contributor. DuckDB CI catches logic and test failures for free; the Snowflake deploy job catches dialect issues. |

## 5. Trade-offs and risks

- **DuckDB/Snowflake drift.** Same SQL, different engines. Mitigation: dispatch macros for
  known differences, cross-database `dbt.*` macros, and the gated Snowflake job before prod.
  Residual risk: Snowflake-only behaviour (masking, row access) is not exercised in CI.
- **Retention definition.** "Any paid day in the month" counts a customer who cancels on day 2
  as retained for that month. It is simple and matches billing, but differs from "active at
  month end". Documented in the model; an alternative column can be added if Finance prefers.
- **Realised vs predicted LTV.** Young cohorts have short curves; comparisons must be at equal
  `months_since_acquisition`.
- **Snapshot granularity.** Two profile changes between runs collapse into one version.
- **Clustering cost.** Automatic clustering consumes credits; reviewed monthly against pruning
  gains (`automatic_clustering_history`).
- **Erasure vs financial retention.** Payments keep a pseudonymous id; needs sign-off from the
  DPO and recording in the ROPA.

## 6. Rollout

1. **Foundation** — Terraform: bucket, KMS, IAM role, storage integration, stage, pipes,
   warehouses, monitors, roles. Run `snowflake/04_governance.sql` (policies, tags, procedure).
2. **Backfill** — `COPY INTO` all history on LOAD_WH; verify row counts against producers.
3. **Shadow run** — dbt prod build daily for two weeks next to the existing reports;
   reconcile revenue (`assert_payments_reconcile_to_marts`) and active-subscriber counts with
   Finance. Differences are explained or fixed before switching.
4. **Switch consumers** — point the Subscription Health dashboard and the Finance LTV model
   (dbt exposures) at the marts. Freeze the legacy queries.
5. **Harden** — enable resource-monitor suspends, alerting on source freshness and test
   failures, monthly cost review by query tag.
6. **Decommission** legacy reports after one month with no reconciliation gaps.

Rollback: consumers keep the legacy queries until step 6; dbt models are rebuildable from RAW
and the landing bucket at any time.

## 7. Open questions

- Should churn be reported at subscription or customer level for family plans?
- Which FX source does Finance sign off on (daily vs monthly average)?
- Is "active at month end" needed as a second retention definition for investor reporting?
