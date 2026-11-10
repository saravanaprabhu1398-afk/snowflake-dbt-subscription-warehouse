# Architecture

```mermaid
flowchart LR
    subgraph Sources["Producers"]
        ACC[Account service<br/>customers CDC]
        BILL[Billing / PSP<br/>plans, subscription events,<br/>payments + refunds]
        APP[Desktop & mobile apps<br/>feature telemetry]
    end

    subgraph S3["AWS S3 landing zone (KMS, versioned, lifecycle)"]
        L["landing/&lt;feed&gt;/_load_date=YYYY-MM-DD/*.parquet"]
    end

    subgraph SF["Snowflake"]
        direction TB
        PIPE[Snowpipe auto-ingest<br/>one pipe per feed]
        RAW[(RAW.LANDING<br/>VARCHAR tables + file metadata)]
        subgraph DBT["dbt (ANALYTICS)"]
            STG[staging views<br/>cast, dedup, GDPR anonymise]
            SNAP[snap_customers<br/>SCD2 snapshot]
            INT[intermediate<br/>subscriptions, customer-months, USD payments]
            CORE[core star schema<br/>dim_customer, dim_plan, dim_date<br/>fct_subscription_events, fct_payments, fct_feature_usage]
            MART[marts<br/>acquisition cohorts, retention / churn,<br/>cohort LTV, feature usage]
        end
        GOV[GOVERNANCE<br/>tags, masking + row access policies,<br/>erasure procedure, audit log]
    end

    BI[Dashboards / Finance / Product]

    ACC --> L
    BILL --> L
    APP --> L
    L -- S3 event to SQS --> PIPE --> RAW
    RAW --> STG --> SNAP --> CORE
    STG --> INT --> CORE
    INT --> MART
    CORE --> MART
    GOV -. policies applied by dbt post-hooks .-> CORE
    MART --> BI
    CORE --> BI
```

## Local / CI path

```mermaid
flowchart LR
    GEN[generator/generate.py] --> PQ[data/landing/*.parquet]
    PQ -- "dbt-duckdb external_location" --> DUCK[(DuckDB file)]
    DUCK --> TESTS[dbt build: models + snapshot + 95 data/unit tests]
```

The same dbt project runs on both: sources resolve to `RAW.LANDING.*` on Snowflake and to
`read_parquet(...)` on DuckDB; adapter-specific SQL goes through `adapter.dispatch` macros
(`macros/cross_db/`), and Snowflake-only configs (`cluster_by`, `snowflake_warehouse`,
query tags, masking post-hooks) are ignored or no-op on DuckDB.

## Workload isolation

| Warehouse | Size | Auto-suspend | Used by |
|---|---|---|---|
| (serverless) | n/a | n/a | Snowpipe |
| LOAD_WH | XS | 60 s | One-off COPY INTO backfills |
| TRANSFORM_WH_S | S | 60 s | dbt default, CI |
| TRANSFORM_WH_M | M | 60 s | Heavy models only (`fct_feature_usage`, cohort marts in prod) |
| BI_WH | S, 1-3 clusters, economy | 300 s | Dashboards |
