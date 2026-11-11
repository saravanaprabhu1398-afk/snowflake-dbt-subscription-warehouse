"""Subscription analytics dashboard over the dbt marts.

make dashboard                      # local DuckDB build
make sf-dashboard                   # live Snowflake marts (key-pair, read only)
"""

from __future__ import annotations

import sys
from pathlib import Path

import altair as alt
import pandas as pd
import streamlit as st

sys.path.insert(0, str(Path(__file__).resolve().parent))

import marts  # noqa: E402
import metrics  # noqa: E402

st.set_page_config(page_title="Subscription Analytics", layout="wide")

ACCENT = "#2563eb"
MUTED = "#94a3b8"
TIERS = ["basic", "plus", "ultimate", "family"]


@st.cache_data(ttl=600, show_spinner="Reading the marts…")
def load() -> dict[str, pd.DataFrame]:
    return marts.load()


try:
    frames = load()
except Exception as exc:  # show the reason instead of a stack trace
    st.error(f"Could not read the marts ({marts.backend()}): {exc}")
    st.stop()

monthly, retention, ltv = frames["monthly"], frames["retention"], frames["ltv"]
channels = metrics.channel_summary(frames["channels"])
k = metrics.kpis(monthly, ltv, frames["channels"])

# --- Sidebar --------------------------------------------------------------------------------
with st.sidebar:
    st.header("Filters")
    first, last = retention["cohort_month"].min(), retention["cohort_month"].max()
    cohort_range = st.slider(
        "Signup cohorts",
        min_value=first.to_pydatetime(),
        max_value=last.to_pydatetime(),
        value=(first.to_pydatetime(), last.to_pydatetime()),
        format="MMM YYYY",
    )
    st.divider()
    source = "Snowflake · ANALYTICS" if marts.backend() == "snowflake" else "DuckDB · local build"
    st.caption(f"Source: **{source}**")
    st.caption(
        "Synthetic data from the project's generator (20k customers). Every number on this "
        "page is read from the dbt marts; nothing is computed outside them except ratios."
    )

in_range = lambda df: df[df["cohort_month"].between(*map(pd.Timestamp, cohort_range))]  # noqa: E731
retention_f, ltv_f = in_range(retention), in_range(ltv)

# --- Header + KPIs --------------------------------------------------------------------------
st.title("Subscription analytics")
st.caption(f"Latest month: {k.month:%B %Y}. Revenue is net of refunds, converted to USD.")

c1, c2, c3, c4, c5 = st.columns(5)
c1.metric("Active customers", f"{k.active_customers:,}", f"{k.active_change:+,} vs prior month")
c2.metric("Net revenue (month)", f"${k.net_revenue_usd:,.0f}", f"{k.revenue_change_pct:+.1%}")
c3.metric("Logo churn (month)", f"{k.logo_churn_rate:.2%}", delta=None)
c4.metric("Trial → paid", f"{k.trial_conversion_rate:.1%}", help="All cohorts, all channels")
c5.metric(
    "12-month LTV",
    f"${k.ltv_12m_usd:,.0f}" if k.ltv_12m_usd is not None else "n/a",
    help=f"Cohort-size-weighted mean over the {k.ltv_12m_cohorts} cohorts that reached month 12",
)

# --- Growth ---------------------------------------------------------------------------------
st.subheader("Growth")
g1, g2 = st.columns(2)
month_axis = alt.X("month_start:T", title=None, axis=alt.Axis(format="%b %y"))
g1.altair_chart(
    alt.Chart(monthly, title="Active customers")
    .mark_area(
        line={"color": ACCENT},
        color=alt.Gradient(
            gradient="linear",
            x1=1,
            x2=1,
            y1=1,
            y2=0,
            stops=[
                alt.GradientStop(color="rgba(37,99,235,0)", offset=0),
                alt.GradientStop(color=ACCENT, offset=1),
            ],
        ),
        opacity=0.6,
    )
    .encode(
        month_axis,
        alt.Y("active_customers:Q", title=None),
        tooltip=[
            alt.Tooltip("month_start:T", format="%B %Y", title="Month"),
            alt.Tooltip("active_customers:Q", format=",", title="Active"),
            alt.Tooltip("new_or_returning:Q", format=",", title="New / returning"),
            alt.Tooltip("churned_customers:Q", format=",", title="Churned"),
        ],
    ),
    use_container_width=True,
)
g2.altair_chart(
    alt.Chart(monthly, title="Net revenue (USD)")
    .mark_bar(color=ACCENT, cornerRadiusTopLeft=2, cornerRadiusTopRight=2)
    .encode(
        month_axis,
        alt.Y("net_revenue_usd:Q", title=None, axis=alt.Axis(format="$.3~s")),
        tooltip=[
            alt.Tooltip("month_start:T", format="%B %Y", title="Month"),
            alt.Tooltip("net_revenue_usd:Q", format="$,.0f", title="Net revenue"),
        ],
    ),
    use_container_width=True,
)

# --- Retention + LTV ------------------------------------------------------------------------
st.subheader("Cohorts")
r1, r2 = st.columns([3, 2])
r1.altair_chart(
    alt.Chart(retention_f, title="Retention: share of each cohort still paying")
    .mark_rect()
    .encode(
        alt.X("months_since_acquisition:O", title="Months since signup"),
        alt.Y("cohort_month:O", title=None, timeUnit="yearmonth", axis=alt.Axis(format="%b %Y")),
        alt.Color(
            "retention_rate:Q",
            title=None,
            scale=alt.Scale(scheme="blues", domain=[0.5, 1]),
            legend=alt.Legend(format=".0%"),
        ),
        tooltip=[
            alt.Tooltip("yearmonth(cohort_month):T", format="%B %Y", title="Cohort"),
            alt.Tooltip("months_since_acquisition:O", title="Month"),
            alt.Tooltip("retention_rate:Q", format=".1%", title="Retention"),
            alt.Tooltip("active_customers:Q", format=",", title="Still paying"),
            alt.Tooltip("cohort_size:Q", format=",", title="Cohort size"),
        ],
    )
    .properties(height=420),
    use_container_width=True,
)

avg_ltv = (
    ltv_f.assign(w=ltv_f["ltv_usd"] * ltv_f["cohort_size"])
    .groupby("months_since_acquisition", as_index=False)
    .agg(w=("w", "sum"), n=("cohort_size", "sum"), cohorts=("cohort_month", "nunique"))
    .assign(ltv_usd=lambda d: d["w"] / d["n"])
)
lines = (
    alt.Chart(ltv_f)
    .mark_line(color=MUTED, opacity=0.35, strokeWidth=1)
    .encode(
        alt.X("months_since_acquisition:Q", title="Months since signup"),
        alt.Y("ltv_usd:Q", title=None, axis=alt.Axis(format="$,.0f")),
        detail="cohort_month:T",
        tooltip=[
            alt.Tooltip("yearmonth(cohort_month):T", format="%B %Y", title="Cohort"),
            alt.Tooltip("ltv_usd:Q", format="$,.2f", title="LTV"),
        ],
    )
)
mean = (
    alt.Chart(avg_ltv)
    .mark_line(color=ACCENT, strokeWidth=3)
    .encode(
        x="months_since_acquisition:Q",
        y="ltv_usd:Q",
        tooltip=[
            alt.Tooltip("months_since_acquisition:Q", title="Month"),
            alt.Tooltip("ltv_usd:Q", format="$,.2f", title="Weighted mean LTV"),
            alt.Tooltip("cohorts:Q", title="Cohorts"),
        ],
    )
)
r2.altair_chart(
    (lines + mean).properties(title="Cumulative LTV per customer (USD)", height=420),
    use_container_width=True,
)

st.caption(
    "Grey lines are individual cohorts, blue is the cohort-size-weighted mean. The step at "
    "month 12 is annual plans renewing; retention drops at the same point when they don't."
)

# --- Acquisition ----------------------------------------------------------------------------
st.subheader("Acquisition channels")
a1, a2 = st.columns([1, 2])
a1.altair_chart(
    alt.Chart(channels, title="Trial → paid conversion")
    .mark_bar(color=ACCENT)
    .encode(
        alt.X("trial_conversion_rate:Q", title=None, axis=alt.Axis(format=".0%")),
        alt.Y("acquisition_channel:N", title=None, sort="-x"),
        tooltip=[
            alt.Tooltip("acquisition_channel:N", title="Channel"),
            alt.Tooltip("trial_conversion_rate:Q", format=".1%", title="Conversion"),
            alt.Tooltip("trials_started:Q", format=",", title="Trials"),
        ],
    ),
    use_container_width=True,
)
a2.dataframe(
    channels[
        [
            "acquisition_channel",
            "acquired_customers",
            "trials_started",
            "trials_converted",
            "direct_paid_starts",
            "trial_conversion_rate",
            "first_month_revenue_per_customer",
        ]
    ],
    hide_index=True,
    use_container_width=True,
    column_config={
        "acquisition_channel": "Channel",
        "acquired_customers": st.column_config.NumberColumn("Customers", format="%d"),
        "trials_started": st.column_config.NumberColumn("Trials", format="%d"),
        "trials_converted": st.column_config.NumberColumn("Converted", format="%d"),
        "direct_paid_starts": st.column_config.NumberColumn("Direct paid", format="%d"),
        "trial_conversion_rate": st.column_config.NumberColumn("Conversion", format="percent"),
        "first_month_revenue_per_customer": st.column_config.NumberColumn(
            "1st-month rev / cust.", format="dollar"
        ),
    },
)
a2.caption("Partner-bundle customers start on a paid plan, so they have no trial to convert.")

# --- Product --------------------------------------------------------------------------------
st.subheader("Product engagement")
p1, p2 = st.columns(2)
adoption = metrics.latest_adoption(frames["feature_adoption"])
p1.altair_chart(
    alt.Chart(adoption, title=f"Feature adoption by plan tier, {adoption['usage_month'].max():%B %Y}")
    .mark_rect()
    .encode(
        alt.X("tier:N", title=None, sort=TIERS),
        alt.Y("feature:N", title=None, axis=alt.Axis(labelLimit=220)),
        alt.Color(
            "adoption_rate:Q", title=None, scale=alt.Scale(scheme="blues"), legend=alt.Legend(format=".0%")
        ),
        tooltip=[
            alt.Tooltip("feature:N"),
            alt.Tooltip("tier:N"),
            alt.Tooltip("adoption_rate:Q", format=".1%", title="Adoption"),
            alt.Tooltip("feature_users:Q", format=",", title="Users"),
        ],
    )
    + alt.Chart(adoption)
    .mark_text(fontSize=11)
    .encode(
        x=alt.X("tier:N", sort=TIERS),
        y="feature:N",
        text=alt.Text("adoption_rate:Q", format=".0%"),
        color=alt.condition("datum.adoption_rate > 0.6", alt.value("white"), alt.value("black")),
    ),
    use_container_width=True,
)
lift = metrics.feature_churn_lift(frames["feature_churn"])
p2.altair_chart(
    alt.Chart(lift, title="Lower 6-month churn when used in first 30 days")
    .mark_bar(color=ACCENT)
    .encode(
        alt.X("churn_reduction_pts:Q", title="Churn reduction (percentage points)"),
        alt.Y("feature:N", title=None, sort="-x", axis=alt.Axis(labelLimit=220)),
        tooltip=[
            alt.Tooltip("feature:N"),
            alt.Tooltip("used:Q", format=".1%", title="Churn, used"),
            alt.Tooltip("not_used:Q", format=".1%", title="Churn, not used"),
            alt.Tooltip("churn_reduction_pts:Q", format=".1f", title="Difference (pts)"),
        ],
    ),
    use_container_width=True,
)
st.caption(
    "Engagement vs churn is a correlation, not proof that a feature causes retention: customers "
    "on richer plans both use more features and churn less."
)
