# Snowflake performance and cost choices

Short notes on why the Snowflake objects are set up the way they are. SQL is in
`snowflake/03_performance.sql` and `snowflake/05_cost_monitoring.sql`; Terraform in `terraform/`.

> Status: written against Snowflake documentation, not measured on a Snowflake account.
> The local numbers in the README come from DuckDB.

## Micro-partition pruning

Snowflake stores every table as immutable micro-partitions (roughly 50-500 MB uncompressed)
and keeps min/max metadata per column per partition. A query with `where event_date between ...`
skips every partition whose range does not overlap. Pruning only works if rows with similar
values sit in the same partitions.

- **Natural clustering first.** Facts are loaded incrementally in event-time order, so new
  partitions are already roughly date-ordered. The MERGE in dbt rewrites only partitions that
  contain matched keys; the 3-day look-back (`incremental_lookback_days`) keeps that set small.
- **Explicit clustering keys only where they pay off.**
  - `fct_feature_usage`: `cluster by (event_date, feature)`. Largest table; almost every
    query is date-bounded and many filter on one feature. Low-cardinality column second.
  - `fct_subscription_events`: `(event_date)`; `fct_payments`: `(payment_date)`.
  - Dimensions and marts are small (thousands of rows) and are not clustered: automatic
    clustering costs credits and would buy nothing.
- **Check, don't assume.** `system$clustering_information` (average depth) and
  `partitions_scanned / partitions_total` from query history are the two numbers to watch.
- Wrapping the cluster column in a function (`where to_char(event_date) = ...`) defeats
  pruning; marts filter on the raw date column or `date_key`.

## Caching

| Cache | What it holds | How the design uses it |
|---|---|---|
| Result cache (24 h, cloud services) | Exact result of a query | Dashboards hit the same mart queries repeatedly. Marts are rebuilt once per load, so results stay valid all day. Free. |
| Warehouse local disk cache | Micro-partitions read recently | BI_WH has a 300 s auto-suspend (vs 60 s for transforms) so consecutive dashboard refreshes reuse warm cache. Transform warehouses suspend fast because dbt runs are bursty and their working set changes every run. |
| Metadata | Row counts, min/max | `count(*)`, `min/max(date)` on facts answered without a warehouse scan. |

## Warehouse sizing per workload

- Separate warehouses per workload (load, transform S, transform M, BI) so one workload cannot
  queue another and spend is attributable without parsing queries.
- **Scale up for big single queries, out for concurrency.** dbt heavy models get
  `TRANSFORM_WH_M` through the `snowflake_warehouse` model config; everything else stays on S.
  BI is multi-cluster (1-3, ECONOMY) because the problem there is concurrent users, not query size.
- **Resize on evidence.** Remote spill (`bytes_spilled_to_remote_storage`) on a model means the
  warehouse is too small for it; move that model, not the whole run.
- `statement_timeout_in_seconds = 3600` on transform warehouses stops runaway queries.
- Snowpipe is serverless, so ingestion needs no running warehouse.

## Cost guardrails

- **Auto-suspend 60 s** on transform/load warehouses; `initially_suspended = true`.
- **Resource monitors**: per-workload monthly quotas, notify at 75/90%, suspend at 100%,
  suspend-immediate at 110%; plus an account-level notify monitor.
- **Query tags**: dbt sets `QUERY_TAG` to JSON `{app, layer, model, target, invocation_id}`
  (`macros/query_tags.sql`), so `QUERY_HISTORY` / `QUERY_ATTRIBUTION_HISTORY` can be grouped by
  model and layer (`snowflake/05_cost_monitoring.sql`).
- **Incremental by default for facts** with `on_schema_change='append_new_columns'`, so a new
  column does not force a full refresh of the largest table.
- **Ephemeral intermediates** where they are used once, so no extra tables are stored or scanned.
- **Short Time Travel** (1 day) on RAW landing data: less storage and faster ageing of erased PII.
