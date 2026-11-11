"""Read the marts for the dashboard from DuckDB (local build) or Snowflake (prod).

The SQL is identical on both: it only reads mart tables and uses portable functions. Only the
table prefix differs (`core.x` in DuckDB, `analytics.core.x` in Snowflake).

Backend selection, by environment variable:
    DASHBOARD_BACKEND=duckdb      (default) reads data/warehouse.duckdb, built by `make build`
    DASHBOARD_BACKEND=snowflake   key-pair login from SNOWFLAKE_ACCOUNT / SNOWFLAKE_USER /
                                  SNOWFLAKE_PRIVATE_KEY_PATH, role DASHBOARD_ROLE, warehouse
                                  DASHBOARD_WAREHOUSE
"""

from __future__ import annotations

import os
from pathlib import Path

import pandas as pd

REPO = Path(__file__).resolve().parent.parent
TEXT_COLUMNS = {"feature", "tier", "acquisition_channel", "used_in_first_30d"}
DUCKDB_PATH = Path(os.environ.get("DASHBOARD_DUCKDB_PATH", REPO / "data" / "warehouse.duckdb"))

QUERIES: dict[str, str] = {
    "monthly": """
        select month_start, active_customers, new_or_returning, churned_customers,
               logo_churn_rate, net_revenue_usd
        from {p}subscription.mart_subscription_monthly
        order by month_start
    """,
    "retention": """
        select cohort_month, months_since_acquisition, cohort_size, active_customers,
               retention_rate
        from {p}subscription.mart_cohort_retention
        order by cohort_month, months_since_acquisition
    """,
    "ltv": """
        select cohort_month, months_since_acquisition, cohort_size, ltv_usd
        from {p}subscription.mart_cohort_ltv
        order by cohort_month, months_since_acquisition
    """,
    "channels": """
        select acquisition_channel,
               sum(acquired_customers) as acquired_customers,
               sum(trials_started) as trials_started,
               sum(trials_converted) as trials_converted,
               sum(direct_paid_starts) as direct_paid_starts,
               sum(first_month_revenue_usd) as first_month_revenue_usd
        from {p}subscription.mart_acquisition_cohorts
        group by acquisition_channel
        order by acquired_customers desc
    """,
    "feature_adoption": """
        select usage_month, feature, tier, feature_users, app_active_users, adoption_rate
        from {p}product.mart_feature_usage_monthly
        order by usage_month, feature, tier
    """,
    "feature_churn": """
        select feature, used_in_first_30d, customers, churned_within_6m, churn_rate_6m
        from {p}product.mart_feature_engagement_churn
        order by feature, used_in_first_30d
    """,
}


def backend() -> str:
    value = os.environ.get("DASHBOARD_BACKEND", "duckdb").lower()
    if value not in ("duckdb", "snowflake"):
        raise ValueError(f"DASHBOARD_BACKEND must be duckdb or snowflake, got {value!r}")
    return value


def _normalise(df: pd.DataFrame) -> pd.DataFrame:
    """Lower-case column names (Snowflake returns upper case), parse months, and turn Decimal
    columns into floats so both backends give the same dtypes."""
    df.columns = [c.lower() for c in df.columns]
    for col in df.columns:
        if col in ("month_start", "cohort_month", "usage_month"):
            df[col] = pd.to_datetime(df[col])
        elif col not in TEXT_COLUMNS and df[col].dtype == object:
            df[col] = df[col].astype(float)
    return df


def load_duckdb(path: Path = DUCKDB_PATH) -> dict[str, pd.DataFrame]:
    import duckdb

    if not path.exists():
        raise FileNotFoundError(f"{path} not found: run `make build` first")
    with duckdb.connect(str(path), read_only=True) as con:
        return {name: _normalise(con.execute(sql.format(p="")).df()) for name, sql in QUERIES.items()}


def load_snowflake() -> dict[str, pd.DataFrame]:
    import snowflake.connector

    con = snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        private_key_file=os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"],
        authenticator="SNOWFLAKE_JWT",
        role=os.environ.get("DASHBOARD_ROLE", "TRANSFORMER"),
        warehouse=os.environ.get("DASHBOARD_WAREHOUSE", "TRANSFORM_WH_S"),
        session_parameters={"QUERY_TAG": "subscription_dashboard"},
    )
    try:
        cur = con.cursor()
        out = {}
        for name, sql in QUERIES.items():
            cur.execute(sql.format(p="analytics."))
            cols = [c[0] for c in cur.description]
            out[name] = _normalise(pd.DataFrame(cur.fetchall(), columns=cols))
        return out
    finally:
        con.close()


def load() -> dict[str, pd.DataFrame]:
    return load_snowflake() if backend() == "snowflake" else load_duckdb()
