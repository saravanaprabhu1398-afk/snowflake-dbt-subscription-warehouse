"""DAG integrity tests. Run inside the Airflow container (`make airflow-test`), where the
dbt project and dbt executable that Cosmos needs to render the graph are mounted."""

import pytest
from airflow.models import DagBag

DAG_ID = "subscription_warehouse_daily"


@pytest.fixture(scope="module")
def dagbag():
    return DagBag(include_examples=False)


def test_no_import_errors(dagbag):
    assert dagbag.import_errors == {}


def test_dag_shape(dagbag):
    dag = dagbag.get_dag(DAG_ID)
    ids = set(dag.task_ids)
    assert {"wait_for_landing", "publish_summary"} <= ids
    dbt_tasks = {t for t in ids if t.startswith("dbt.")}
    # every model, the snapshot, the seeds and the source freshness checks become tasks
    for expected in ("dbt.fct_feature_usage", "dbt.snap_customers", "dbt.dim_customer"):
        assert any(t.startswith(expected) for t in dbt_tasks), expected
    assert any("freshness" in t or "source" in t for t in dbt_tasks)
    assert dag.max_active_runs == 1 and not dag.catchup


def test_sensor_runs_first_and_summary_last(dagbag):
    dag = dagbag.get_dag(DAG_ID)
    sensor = dag.get_task("wait_for_landing")
    assert not sensor.upstream_task_ids
    # the sensor gates dbt; publish_summary also reads the sensor's XCom
    assert sensor.downstream_task_ids - {"publish_summary"}
    assert all(t.startswith("dbt.") for t in sensor.downstream_task_ids - {"publish_summary"})
    summary = dag.get_task("publish_summary")
    assert not summary.downstream_task_ids
    # the summary waits for every dbt leaf, i.e. for the whole dbt graph
    assert any(t.startswith("dbt.") for t in summary.upstream_task_ids)
    assert summary.get_flat_relative_ids(upstream=True) >= {t for t in dag.task_ids if t.startswith("dbt.")}
    assert sensor.mode == "reschedule"


def test_every_task_retries_and_alerts(dagbag):
    dag = dagbag.get_dag(DAG_ID)
    for t in dag.tasks:
        if t.task_id != "wait_for_landing":
            assert t.retries == 2, t.task_id
        assert t.on_failure_callback, t.task_id
