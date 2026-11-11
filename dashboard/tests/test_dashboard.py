"""Dashboard tests: metric logic on small frames, and the whole app rendered on the DuckDB build."""

from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd
import pytest

DASH = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(DASH))

import marts  # noqa: E402
import metrics  # noqa: E402

needs_build = pytest.mark.skipif(
    not marts.DUCKDB_PATH.exists(), reason="run `make build` to create data/warehouse.duckdb"
)


def _monthly():
    return pd.DataFrame(
        {
            "month_start": pd.to_datetime(["2025-09-01", "2025-10-01"]),
            "active_customers": [100.0, 110.0],
            "net_revenue_usd": [1000.0, 1100.0],
            "logo_churn_rate": [0.05, 0.04],
        }
    )


def test_kpis_use_latest_month_and_weight_ltv_by_cohort_size():
    ltv = pd.DataFrame(
        {
            "months_since_acquisition": [12, 12, 11],
            "cohort_size": [100, 300, 50],
            "ltv_usd": [100.0, 200.0, 999.0],
        }
    )
    channels = pd.DataFrame({"trials_started": [10, 30], "trials_converted": [5, 15]})
    k = metrics.kpis(_monthly(), ltv, channels)
    assert k.active_customers == 110 and k.active_change == 10
    assert k.revenue_change_pct == pytest.approx(0.10)
    assert k.ltv_12m_usd == pytest.approx(175.0)  # (100*100 + 200*300) / 400; month 11 ignored
    assert k.ltv_12m_cohorts == 2
    assert k.trial_conversion_rate == pytest.approx(0.5)


def test_kpis_without_a_12_month_cohort():
    ltv = pd.DataFrame({"months_since_acquisition": [1], "cohort_size": [5], "ltv_usd": [9.0]})
    channels = pd.DataFrame({"trials_started": [1], "trials_converted": [1]})
    assert metrics.kpis(_monthly(), ltv, channels).ltv_12m_usd is None


def test_feature_churn_lift_is_not_used_minus_used():
    f = pd.DataFrame(
        {"feature": ["vpn", "vpn"], "used_in_first_30d": [True, False], "churn_rate_6m": [0.2, 0.3]}
    )
    assert metrics.feature_churn_lift(f)["churn_reduction_pts"].iloc[0] == pytest.approx(10.0)


def test_backend_rejects_unknown_value(monkeypatch):
    monkeypatch.setenv("DASHBOARD_BACKEND", "postgres")
    with pytest.raises(ValueError):
        marts.backend()


@needs_build
def test_marts_load_with_expected_shapes():
    frames = marts.load_duckdb()
    assert set(frames) == set(marts.QUERIES)
    assert frames["monthly"]["month_start"].is_monotonic_increasing
    assert frames["retention"]["retention_rate"].between(0, 1).all()


@needs_build
def test_app_renders_without_errors(monkeypatch):
    from streamlit.testing.v1 import AppTest

    monkeypatch.setenv("DASHBOARD_BACKEND", "duckdb")
    at = AppTest.from_file(str(DASH / "app.py"), default_timeout=60).run()
    assert not at.exception, at.exception
    assert not at.error, [e.value for e in at.error]
    labels = [m.label for m in at.metric]
    assert labels == [
        "Active customers",
        "Net revenue (month)",
        "Logo churn (month)",
        "Trial → paid",
        "12-month LTV",
    ]
