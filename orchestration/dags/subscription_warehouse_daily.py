"""
### subscription_warehouse_daily

Daily production run of the subscription warehouse on Snowflake.

1. **wait_for_landing**: sensor (reschedule mode) that waits until the day's landing load is in
   RAW: every required feed has files with `_load_date=<load_date>` in Snowpipe's copy history
   and no pipe has pending files. Metadata functions only, so waiting uses no warehouse.
2. **dbt**: the dbt project rendered by Astronomer Cosmos, one Airflow task per seed, snapshot,
   model and source-freshness check, each model followed by its tests. Failed nodes retry on
   their own; downstream models wait.
3. **publish_summary**: row counts and last-modified times of the core and mart tables.

Failures call `include.alerts.notify_failure` (log + optional webhook).

Trigger manually with `{"load_date": "2025-11-01"}` to run against a specific landing partition;
scheduled runs wait for today's partition (`ds`).
"""

from __future__ import annotations

from datetime import timedelta
from pathlib import Path

import pendulum
from airflow.providers.snowflake.hooks.snowflake import SnowflakeHook
from airflow.sdk import Param, PokeReturnValue, dag, get_current_context, task
from cosmos import DbtTaskGroup, ExecutionConfig, ProfileConfig, ProjectConfig, RenderConfig
from cosmos.constants import LoadMode, SourceRenderingBehavior, TestBehavior

from include.alerts import notify_failure
from include.landing_checks import check_landing, validate_load_date

AIRFLOW_HOME = Path("/usr/local/airflow")
DBT_PROJECT = AIRFLOW_HOME / "dbt" / "subscription_warehouse"
DBT_EXECUTABLE = AIRFLOW_HOME / "dbt_venv" / "bin" / "dbt"
SNOWFLAKE_CONN_ID = "snowflake_dbt"

profile_config = ProfileConfig(
    profile_name="subscription_warehouse",
    target_name="prod",
    profiles_yml_filepath=DBT_PROJECT / "profiles.yml",  # credentials come from env vars
)

default_args = {
    "owner": "data-platform",
    "retries": 2,
    "retry_delay": timedelta(minutes=2),
    "retry_exponential_backoff": True,
    "execution_timeout": timedelta(minutes=30),
    "on_failure_callback": notify_failure,
}


@dag(
    dag_id="subscription_warehouse_daily",
    schedule="15 6 * * *",  # 06:15 UTC, after the overnight producer drops
    start_date=pendulum.datetime(2026, 11, 1, tz="UTC"),
    catchup=False,
    max_active_runs=1,  # never two MERGE runs on the same facts
    max_active_tasks=8,
    default_args=default_args,
    params={
        "load_date": Param(
            None,
            type=["null", "string"],
            description="Landing partition to wait for (YYYY-MM-DD). Empty = the run's ds.",
        ),
    },
    tags=["snowflake", "dbt", "subscription-warehouse"],
    doc_md=__doc__,
)
def subscription_warehouse_daily():
    @task.sensor(
        poke_interval=300,
        timeout=int(timedelta(hours=3).total_seconds()),
        mode="reschedule",  # frees the worker slot between pokes
        retries=0,  # a timeout means producers are late: alert, don't retry blindly
    )
    def wait_for_landing() -> PokeReturnValue:
        context = get_current_context()
        load_date = validate_load_date(context["params"].get("load_date") or context["ds"])
        hook = SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)
        with hook.get_conn() as conn, conn.cursor() as cur:
            status = check_landing(cur, load_date)
        print(status.summary())
        return PokeReturnValue(is_done=status.ready, xcom_value=status.as_dict())

    dbt = DbtTaskGroup(
        group_id="dbt",
        # dbt_packages is part of the mounted project, so no `dbt deps` per task.
        project_config=ProjectConfig(dbt_project_path=DBT_PROJECT, install_dbt_deps=False),
        profile_config=profile_config,
        execution_config=ExecutionConfig(dbt_executable_path=DBT_EXECUTABLE),
        render_config=RenderConfig(
            load_method=LoadMode.DBT_LS,
            test_behavior=TestBehavior.AFTER_EACH,
            source_rendering_behavior=SourceRenderingBehavior.WITH_TESTS_OR_FRESHNESS,
            # Exposures are documentation, not work.
            exclude=["resource_type:exposure"],
        ),
    )

    @task
    def publish_summary(landing: dict) -> dict:
        """Row counts of core and mart tables after the run (SHOW TABLES: no warehouse needed)."""
        hook = SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)
        with hook.get_conn() as conn, conn.cursor() as cur:
            cur.execute("show tables in database analytics")
            cols = [c[0] for c in cur.description]
            tables = [dict(zip(cols, row, strict=True)) for row in cur.fetchall()]
        summary = {
            f"{t['schema_name']}.{t['name']}".lower(): int(t["rows"] or 0)
            for t in tables
            if t["schema_name"] in ("CORE", "SUBSCRIPTION", "PRODUCT")
        }
        for name, rows in sorted(summary.items()):
            print(f"{name:45s} {rows:>12,}")
        print(f"landing rows for {landing['load_date']}: {landing['rows']}")
        return {"load_date": landing["load_date"], "tables": summary}

    landing = wait_for_landing()
    landing >> dbt >> publish_summary(landing)


subscription_warehouse_daily()
