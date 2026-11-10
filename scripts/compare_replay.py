"""Check that the incremental replay (load 1 then load 2) gives the same facts and marts
as one full build. Run `make replay` (-> data/warehouse.duckdb) and
`dbt build --target ci` on a fresh file (-> data/ci.duckdb) first.

customer_sk is excluded on purpose: the replay sees two profile versions for customers that
changed in load 2, the one-shot build only the latest, so the point-in-time keys differ.
"""

import sys

import duckdb

TABLES = [
    "core.fct_subscription_events", "core.fct_payments", "core.fct_feature_usage",
    "subscription.mart_cohort_retention", "subscription.mart_cohort_ltv",
    "subscription.mart_acquisition_cohorts", "subscription.mart_subscription_monthly",
    "product.mart_feature_usage_monthly", "product.mart_feature_engagement_churn",
]

con = duckdb.connect()
con.execute("attach 'data/warehouse.duckdb' as replay (read_only)")
con.execute("attach 'data/ci.duckdb' as oneshot (read_only)")
failed = False
for t in TABLES:
    schema, name = t.split(".")
    cols = ", ".join(r[0] for r in con.execute(
        "select column_name from information_schema.columns where table_catalog = 'oneshot' "
        "and table_schema = ? and table_name = ? and column_name not in ('customer_sk', '_loaded_at')",
        [schema, name]).fetchall())
    a = con.execute(f"select count(*) from (select {cols} from replay.{t} except all "
                    f"select {cols} from oneshot.{t})").fetchone()[0]
    b = con.execute(f"select count(*) from (select {cols} from oneshot.{t} except all "
                    f"select {cols} from replay.{t})").fetchone()[0]
    print(f"{t:45s} only-in-replay={a} only-in-oneshot={b}")
    failed |= bool(a or b)
sys.exit(1 if failed else 0)
