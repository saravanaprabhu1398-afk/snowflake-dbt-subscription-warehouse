# Orchestration: Airflow + Astronomer Cosmos

The daily production run as an Airflow DAG, so loading, transformation and alerting are one
observable pipeline instead of a cron job that hopes the data has arrived.

```
wait_for_landing ──► dbt (Cosmos task group: 55 tasks) ──► publish_summary
 sensor, reschedule     one task per seed / snapshot /        row counts of core
 mode, 5 min pokes      model, tests after each model,        and mart tables
 up to 3 h              source freshness per source
```

| Piece | What it does |
|---|---|
| `dags/subscription_warehouse_daily.py` | The DAG. 06:15 UTC daily, `max_active_runs=1` (no two MERGE runs on the same facts), 2 retries with exponential backoff, 30 min task timeout, failure callback on every task. Param `load_date` picks the landing partition; empty means the run's `ds`. |
| `include/landing_checks.py` | Sensor logic: every required feed has `Loaded` files for `_load_date=<date>` in `COPY_HISTORY`, and `SYSTEM$PIPE_STATUS` shows no pending files on any pipe. Metadata functions only, so waiting needs no warehouse. `load_date` is validated before it reaches SQL. |
| `include/alerts.py` | `notify_failure`: an ERROR log line with task, try, run, first error line and log URL; also posted to `ALERT_WEBHOOK_URL` (Slack/Teams/Chat incoming webhook) when set. |
| `Dockerfile` | Astro Runtime 3.3 (Airflow 3.3, Python 3.14) plus a separate dbt venv (Python 3.12, dbt-snowflake 1.12) so dbt's dependencies never clash with Airflow's. |
| `docker-compose.override.yml` | Mounts the dbt project (read-only) and the `SVC_DBT` private key (read-only) into the scheduler, DAG processor and triggerer. |
| `.env.example` | Snowflake account, `SVC_DBT` key path and the `snowflake_dbt` Airflow connection (key-pair, `authenticator: SNOWFLAKE_JWT`). Copy to `.env`. |
| `tests/` | 8 unit tests for the sensor logic (fake cursor checks the ILIKE pattern against the file names Snowflake really returns) and 4 DAG tests (imports, shape, sensor first, retries and alerts). |

## Run it locally

Needs Docker and the [Astro CLI](https://www.astronomer.io/docs/astro/cli/install-cli), plus the
Snowflake deployment from [docs/snowflake-deployment.md](../docs/snowflake-deployment.md).

```bash
cp orchestration/.env.example orchestration/.env   # fill in the account name
make airflow-start                                 # UI: http://orchestration.localhost:6563
make airflow-test                                  # 12 tests inside the scheduler
make airflow-run LOAD_DATE=2025-11-01              # trigger for one landing partition
make airflow-status
make airflow-stop
```

## Results (local Airflow against the Snowflake trial, 2026-11-11)

Manual run for `load_date=2025-11-01`, the October delta that Snowpipe had already loaded:

| | |
|---|---|
| Tasks | 57, all `success` on the first try |
| `wait_for_landing` | done on the first poke in 20 s: customers 1,775, subscription_events 6,775, payments 5,322, feature_usage 98,077 rows (matches the files uploaded) |
| Whole run | 4 min 6 s (13:21:26 → 13:25:32 UTC) |
| Slowest tasks | `fct_feature_usage.run` 28.6 s, `fct_subscription_events.run` 27.2 s, `fct_payments.run` 27.0 s |
| `publish_summary` | `fct_feature_usage` 990,063, `fct_subscription_events` 78,976, `fct_payments` 58,423, `dim_customer` 20,411 rows |

The partition had already been merged by an earlier `dbt build`, so this run was also a
replay: every fact and dimension count is identical to before, so the incremental MERGE did
not duplicate anything.

**Failure path, observed for real.** The first trigger failed because the Snowflake connector
now requires `authenticator: SNOWFLAKE_JWT` alongside a private key. The sensor failed (no
retry, by design), downstream tasks were marked `upstream_failed`, and `notify_failure`
logged:

```
:red_circle: subscription_warehouse_daily.wait_for_landing failed (try 1, run scheduled__2026-11-11T06:15:00+00:00)
> 251007: Configuration error: ... use 'SNOWFLAKE_JWT' or remove the private key parameters
http://localhost:8080/dags/subscription_warehouse_daily/runs/.../tasks/wait_for_landing?try_number=1
```

An earlier test also caught a bug before it reached a run: `COPY_HISTORY` reports file names
relative to the pipe's stage path (`_load_date=2025-11-01/data_0.parquet`), so a pattern with a
leading `/` would never match and the sensor would have waited for 3 hours.

## Trade-offs

- **Per-node tasks cost time.** A single `dbt build` takes about 27 s on Snowflake; through
  Cosmos the same graph takes about 4 minutes, because each task starts its own dbt process
  and parses the project. In return a failed model retries alone, the UI shows which model
  failed, and nothing downstream of it runs.
- **dbt unit tests are not in the DAG.** Cosmos 1.16 has no converter for `unit_test` nodes
  and skips them. They run in CI on every pull request, which is where dbt recommends running
  them.
- **Local only.** No always-on Airflow is deployed; the hosted daily schedule is still the
  GitHub Actions `prod-run` workflow. This project would deploy unchanged to Astro or MWAA
  with the key in a secrets backend instead of a mounted file.
