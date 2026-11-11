"""Headline numbers derived from the marts. Pure pandas, so they are unit-tested on DuckDB."""

from __future__ import annotations

from dataclasses import dataclass

import pandas as pd


@dataclass(frozen=True)
class Kpis:
    month: pd.Timestamp
    active_customers: int
    active_change: int
    net_revenue_usd: float
    revenue_change_pct: float
    logo_churn_rate: float
    trial_conversion_rate: float
    ltv_12m_usd: float | None
    ltv_12m_cohorts: int


def kpis(monthly: pd.DataFrame, ltv: pd.DataFrame, channels: pd.DataFrame) -> Kpis:
    m = monthly.sort_values("month_start")
    last, prev = m.iloc[-1], m.iloc[-2]
    # 12-month LTV: cohort-size-weighted mean over cohorts old enough to have month 12.
    at12 = ltv[ltv["months_since_acquisition"] == 12]
    ltv12 = (
        float((at12["ltv_usd"] * at12["cohort_size"]).sum() / at12["cohort_size"].sum())
        if len(at12)
        else None
    )
    return Kpis(
        month=last["month_start"],
        active_customers=int(last["active_customers"]),
        active_change=int(last["active_customers"] - prev["active_customers"]),
        net_revenue_usd=float(last["net_revenue_usd"]),
        revenue_change_pct=float(last["net_revenue_usd"] / prev["net_revenue_usd"] - 1),
        logo_churn_rate=float(last["logo_churn_rate"]),
        trial_conversion_rate=float(channels["trials_converted"].sum() / channels["trials_started"].sum()),
        ltv_12m_usd=ltv12,
        ltv_12m_cohorts=len(at12),
    )


def channel_summary(channels: pd.DataFrame) -> pd.DataFrame:
    c = channels.copy()
    c["trial_conversion_rate"] = c["trials_converted"] / c["trials_started"]
    c["first_month_revenue_per_customer"] = c["first_month_revenue_usd"] / c["acquired_customers"]
    return c.sort_values("acquired_customers", ascending=False)


def feature_churn_lift(feature_churn: pd.DataFrame) -> pd.DataFrame:
    """Per feature: 6-month churn for early users vs non-users, and the difference."""
    f = feature_churn.copy()
    f["group"] = f["used_in_first_30d"].map({True: "used", False: "not_used"})
    wide = f.pivot_table(index="feature", columns="group", values="churn_rate_6m").reset_index()
    wide["churn_reduction_pts"] = (wide["not_used"] - wide["used"]) * 100
    return wide.sort_values("churn_reduction_pts", ascending=False)


def latest_adoption(feature_adoption: pd.DataFrame) -> pd.DataFrame:
    last = feature_adoption["usage_month"].max()
    return feature_adoption[feature_adoption["usage_month"] == last]
