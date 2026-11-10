"""Synthetic data generator for a consumer security subscription app.

Produces five landing feeds in an S3-style layout:

    <out>/<feed>/_load_date=YYYY-MM-DD/data_0.parquet

Feeds: customers, plans, subscription_events, payments, feature_usage.

The whole history (2024-01-01 .. 2025-10-31) is simulated in one pass, then
split into two daily "loads" so the warehouse can be exercised the way it is
in production: an initial backfill (load 1, everything before 2025-10-01) and
an incremental load (load 2, October 2025 plus customer profile changes).

All data is fake. Names and e-mails are built from small word lists and a
customer number; no real person is represented.

Usage:
    python generator/generate.py --customers 20000 --out data/landing
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import math
import random
import shutil
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

import duckdb

HISTORY_START = dt.datetime(2024, 1, 1)
HISTORY_END = dt.datetime(2025, 10, 31, 23, 59, 59)
LOAD_CUTOFF = dt.datetime(2025, 10, 1)  # load 1 = before this, load 2 = after
LOAD_DATES = {1: dt.date(2025, 10, 1), 2: dt.date(2025, 11, 1)}

# country -> (weight, currency)
COUNTRIES = {
    "US": (34, "USD"), "GB": (8, "GBP"), "DE": (10, "EUR"), "FR": (7, "EUR"),
    "NL": (4, "EUR"), "ES": (4, "EUR"), "IT": (4, "EUR"), "IE": (1, "EUR"),
    "SE": (2, "EUR"), "IN": (9, "INR"), "BR": (6, "BRL"), "CA": (5, "CAD"),
    "AU": (4, "AUD"), "JP": (2, "JPY"),
}
# local price multiplier vs USD list price (rough purchasing-power pricing)
PRICE_FACTOR = {"USD": 1.0, "GBP": 0.85, "EUR": 0.95, "INR": 45.0, "BRL": 3.5,
                "CAD": 1.35, "AUD": 1.5, "JPY": 140.0}

CHANNELS = [("web", 50), ("app_store", 20), ("play_store", 20), ("partner_bundle", 10)]
UTM_SOURCES = {
    "web": [("google_ads", 40), ("organic", 35), ("affiliate", 15), ("referral", 10)],
    "app_store": [("apple_search_ads", 50), ("organic", 50)],
    "play_store": [("google_ads", 50), ("organic", 50)],
    "partner_bundle": [("pc_oem", 70), ("isp_partner", 30)],
}

# plan_id, name, tier, billing_period, list_price_usd, max_devices, vpn, identity, family
PLANS = [
    ("P_BASIC_M", "Antivirus Basic Monthly", "basic", "monthly", 4.99, 1, False, False, False),
    ("P_BASIC_A", "Antivirus Basic Annual", "basic", "annual", 39.99, 1, False, False, False),
    ("P_PLUS_M", "Security Plus Monthly", "plus", "monthly", 9.99, 5, True, False, False),
    ("P_PLUS_A", "Security Plus Annual", "plus", "annual", 79.99, 5, True, False, False),
    ("P_ULT_M", "Ultimate Identity Monthly", "ultimate", "monthly", 19.99, 10, True, True, False),
    ("P_ULT_A", "Ultimate Identity Annual", "ultimate", "annual", 159.99, 10, True, True, False),
    ("P_FAM_A", "Family Ultimate Annual", "family", "annual", 249.99, 25, True, True, True),
]
PLAN_BY_ID = {p[0]: p for p in PLANS}
TIER_ORDER = ["basic", "plus", "ultimate", "family"]
START_PLAN_WEIGHTS = [("P_BASIC_M", 18), ("P_BASIC_A", 12), ("P_PLUS_M", 22), ("P_PLUS_A", 20),
                      ("P_ULT_M", 12), ("P_ULT_A", 10), ("P_FAM_A", 6)]

FEATURES = {  # feature -> (min tier index, weight)
    "malware_scan": (0, 40), "web_protection_block": (0, 25), "firewall_alert": (0, 8),
    "vpn_connect": (1, 20), "password_vault_open": (1, 15),
    "dark_web_monitor_check": (2, 6), "identity_alert_view": (2, 4),
    "parental_control_rule": (3, 6),
}
PLATFORMS = [("windows", 45), ("android", 25), ("ios", 15), ("macos", 15)]
FIRST = ["alex", "sam", "maria", "jan", "li", "anna", "omar", "priya", "lukas", "sofia",
         "noah", "emma", "arjun", "chloe", "mateo", "yuki", "lea", "david", "nina", "raj"]
LAST = ["smith", "muller", "garcia", "rossi", "dubois", "jansen", "kumar", "silva", "brown",
        "schmidt", "martin", "lopez", "bianchi", "nakamura", "wilson", "patel", "costa", "berg"]
DOMAINS = ["example.com", "example.org", "example.net", "mail.example"]


def wpick(rng: random.Random, pairs):
    total = sum(w for _, w in pairs)
    r = rng.uniform(0, total)
    upto = 0.0
    for item, w in pairs:
        upto += w
        if r <= upto:
            return item
    return pairs[-1][0]


def add_months(ts: dt.datetime, months: int) -> dt.datetime:
    m = ts.month - 1 + months
    y = ts.year + m // 12
    m = m % 12 + 1
    day = min(ts.day, [31, 29 if y % 4 == 0 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1])
    return ts.replace(year=y, month=m, day=day)


def local_price(plan_id: str, currency: str) -> float:
    usd = PLAN_BY_ID[plan_id][4]
    raw = usd * PRICE_FACTOR[currency]
    if currency in ("JPY", "INR"):
        return float(math.ceil(raw / 10) * 10 - 1)
    return round(math.floor(raw) + 0.99, 2)


@dataclass
class Out:
    customers: list
    subscription_events: list
    payments: list
    feature_usage: list


class Generator:
    def __init__(self, n_customers: int, usage_intensity: float, seed: int):
        self.n = n_customers
        self.usage_intensity = usage_intensity
        self.rng = random.Random(seed)
        self.out = Out([], [], [], [])
        self.event_seq = 0
        self.payment_seq = 0
        self.usage_seq = 0
        self.sub_seq = 0

    # ---------- ids
    def _eid(self):
        self.event_seq += 1
        return f"E{self.event_seq:09d}"

    def _pid(self):
        self.payment_seq += 1
        return f"PAY{self.payment_seq:09d}"

    def _uid(self):
        self.usage_seq += 1
        return f"U{self.usage_seq:011d}"

    # ---------- customers
    def signup_ts(self) -> dt.datetime:
        # linear growth: density proportional to (0.5 + t)
        span = (HISTORY_END - HISTORY_START).total_seconds()
        u = self.rng.random()
        # inverse CDF of f(t) ∝ 0.5 + t on [0,1]
        t = (-0.5 + math.sqrt(0.25 + 2 * u * 1.0)) / 1.0
        t = min(max(t, 0.0), 1.0)
        return HISTORY_START + dt.timedelta(seconds=t * span)

    def run(self) -> Out:
        for i in range(1, self.n + 1):
            self.customer(i)
        return self.out

    def customer(self, i: int):
        rng = self.rng
        cid = f"C{i:07d}"
        country = wpick(rng, [(c, w) for c, (w, _) in COUNTRIES.items()])
        currency = COUNTRIES[country][1]
        first, last = rng.choice(FIRST), rng.choice(LAST)
        signup = self.signup_ts()
        version = {
            "customer_id": cid,
            "email": f"{first}.{last}.{i}@{rng.choice(DOMAINS)}",
            "first_name": first.title(),
            "last_name": last.title(),
            "phone": f"+00-{rng.randint(100, 999)}-{rng.randint(1000000, 9999999)}",
            "country_code": country,
            "marketing_opt_in": rng.random() < 0.55,
            "created_at": signup,
            "updated_at": signup,
        }
        versions = [dict(version)]
        # 0-2 later profile changes
        for _ in range(rng.choices([0, 1, 2], weights=[70, 22, 8])[0]):
            change_at = versions[-1]["updated_at"] + dt.timedelta(days=rng.randint(10, 300))
            if change_at > HISTORY_END:
                break
            v = dict(versions[-1])
            kind = rng.choices(["email", "opt", "name", "country"], weights=[45, 35, 12, 8])[0]
            if kind == "email":
                v["email"] = f"{first}{rng.randint(1, 99)}.{i}@{rng.choice(DOMAINS)}"
            elif kind == "opt":
                v["marketing_opt_in"] = not v["marketing_opt_in"]
            elif kind == "name":
                v["last_name"] = rng.choice(LAST).title()
            else:  # moved country (keeps billing currency of the subscription)
                v["country_code"] = wpick(rng, [(c, w) for c, (w, _) in COUNTRIES.items()])
            v["updated_at"] = change_at
            versions.append(v)
        self.out.customers.append(versions)

        channel = wpick(rng, CHANNELS)
        utm = wpick(rng, UTM_SOURCES[channel])
        engagement = rng.betavariate(2, 4)  # 0..1, mean ~0.33
        self.subscription(cid, signup, channel, utm, currency, engagement)

    # ---------- subscriptions
    def emit(self, sub_id, cid, plan, etype, ts, prev_plan=None, channel=None, utm=None, reason=None):
        self.out.subscription_events.append({
            "event_id": self._eid(), "subscription_id": sub_id, "customer_id": cid,
            "plan_id": plan, "previous_plan_id": prev_plan, "event_type": etype,
            "event_ts": ts, "channel": channel, "utm_source": utm, "cancel_reason": reason,
        })

    def pay(self, sub_id, cid, plan, ts, amount, currency, kind="charge", status="succeeded",
            refund_of=None):
        rng = self.rng
        method = wpick(rng, [("card", 70), ("paypal", 15), ("app_store_iap", 15)])
        pid = self._pid()
        self.out.payments.append({
            "payment_id": pid, "subscription_id": sub_id, "customer_id": cid, "plan_id": plan,
            "payment_ts": ts, "payment_type": kind, "status": status,
            "amount": round(amount, 2), "currency": currency, "payment_method": method,
            "card_brand": wpick(rng, [("visa", 55), ("mastercard", 35), ("amex", 10)])
            if method == "card" else None,
            # PCI-DSS: only a PSP token and last-4 are stored, never the PAN or CVV.
            "card_last4": f"{rng.randint(0, 9999):04d}" if method == "card" else None,
            "psp_token": f"tok_{rng.getrandbits(64):016x}",
            "refund_of_payment_id": refund_of,
        })
        return pid

    def charge_with_retry(self, sub_id, cid, plan, ts, currency) -> bool:
        """Returns False when the charge finally fails (involuntary churn)."""
        amount = local_price(plan, currency)
        if self.rng.random() < 0.04:
            self.pay(sub_id, cid, plan, ts, amount, currency, status="failed")
            retry = ts + dt.timedelta(days=1)
            if self.rng.random() < 0.7 and retry <= HISTORY_END:
                pid = self.pay(sub_id, cid, plan, retry, amount, currency)
            else:
                return False
        else:
            pid = self.pay(sub_id, cid, plan, ts, amount, currency)
        if self.rng.random() < 0.025:
            rts = ts + dt.timedelta(days=self.rng.randint(1, 14))
            if rts <= HISTORY_END:
                self.pay(sub_id, cid, plan, rts, -amount, currency, kind="refund", refund_of=pid)
        return True

    def subscription(self, cid, signup, channel, utm, currency, engagement):
        rng = self.rng
        self.sub_seq += 1
        sub_id = f"S{self.sub_seq:08d}"
        plan = wpick(rng, START_PLAN_WEIGHTS)
        active_periods: list[tuple[dt.datetime, dt.datetime, str]] = []

        if channel != "partner_bundle" and rng.random() < 0.7:
            self.emit(sub_id, cid, plan, "trial_start", signup, channel=channel, utm=utm)
            trial_end = signup + dt.timedelta(days=14)
            active_periods.append((signup, min(trial_end, HISTORY_END), plan))
            if trial_end > HISTORY_END:
                self.usage(cid, active_periods, engagement)
                return
            if rng.random() > 0.42 + 0.3 * engagement:
                self.emit(sub_id, cid, plan, "trial_expired", trial_end, reason="trial_not_converted")
                self.usage(cid, active_periods, engagement)
                return
            start = trial_end
        else:
            start = signup

        self.emit(sub_id, cid, plan, "subscription_start", start, channel=channel, utm=utm)
        ok = self.charge_with_retry(sub_id, cid, plan, start, currency)
        period_start = start
        n_period = 0
        pending_downgrade = None
        while True:
            if not ok:
                fail_ts = period_start + dt.timedelta(days=1)
                if fail_ts <= HISTORY_END:
                    self.emit(sub_id, cid, plan, "cancel", fail_ts, reason="payment_failed")
                break
            months = 12 if PLAN_BY_ID[plan][3] == "annual" else 1
            period_end = add_months(period_start, months)
            # mid-period upgrade (immediate, prorated charge)
            tier_idx = TIER_ORDER.index(PLAN_BY_ID[plan][2])
            if tier_idx < 2 and rng.random() < 0.03 + 0.05 * engagement:
                up_ts = period_start + (period_end - period_start) * rng.uniform(0.1, 0.8)
                if up_ts <= HISTORY_END:
                    new_plan = next(p[0] for p in PLANS if p[2] == TIER_ORDER[tier_idx + 1]
                                    and p[3] == PLAN_BY_ID[plan][3])
                    self.emit(sub_id, cid, new_plan, "upgrade", up_ts, prev_plan=plan)
                    remaining = (period_end - up_ts) / (period_end - period_start)
                    diff = (local_price(new_plan, currency) - local_price(plan, currency)) * remaining
                    self.pay(sub_id, cid, new_plan, up_ts, diff, currency)
                    active_periods.append((period_start, up_ts, plan))
                    period_start, plan = up_ts, new_plan
            elif tier_idx > 0 and pending_downgrade is None and rng.random() < 0.015:
                dn_ts = period_start + (period_end - period_start) * rng.uniform(0.1, 0.9)
                if dn_ts <= HISTORY_END:
                    new_plan = next(p[0] for p in PLANS if p[2] == TIER_ORDER[tier_idx - 1]
                                    and p[3] == PLAN_BY_ID[plan][3])
                    self.emit(sub_id, cid, new_plan, "downgrade", dn_ts, prev_plan=plan)
                    pending_downgrade = new_plan  # takes effect at renewal

            active_periods.append((period_start, min(period_end, HISTORY_END), plan))
            # churn decision for this period
            if months == 1:
                hazard = max(0.035, 0.12 * math.exp(-n_period / 4)) * (1.3 - engagement)
            else:
                hazard = 0.32 * (1.3 - engagement)
            if rng.random() < hazard:
                cancel_ts = period_start + (period_end - period_start) * rng.uniform(0.2, 0.95)
                if cancel_ts <= HISTORY_END:
                    reason = wpick(rng, [("price", 40), ("not_using", 30), ("switched_competitor", 15),
                                         ("other", 15)])
                    self.emit(sub_id, cid, plan, "cancel", cancel_ts, reason=reason)
                break
            if period_end > HISTORY_END:
                break
            n_period += 1
            if pending_downgrade:
                plan, pending_downgrade = pending_downgrade, None
            self.emit(sub_id, cid, plan, "renewal", period_end)
            ok = self.charge_with_retry(sub_id, cid, plan, period_end, currency)
            period_start = period_end
        self.usage(cid, active_periods, engagement)

    # ---------- feature usage
    def usage(self, cid, periods, engagement):
        rng = self.rng
        devices = [f"D{cid[1:]}_{k}" for k in range(rng.randint(1, 3))]
        dev_platform = {d: wpick(rng, PLATFORMS) for d in devices}
        for start, end, plan in periods:
            tier_idx = TIER_ORDER.index(PLAN_BY_ID[plan][2])
            feats = [(f, w) for f, (min_tier, w) in FEATURES.items() if tier_idx >= min_tier]
            days = (end - start).total_seconds() / 86400
            if days <= 0:
                continue
            lam = days * engagement * 0.9 * self.usage_intensity
            n = self._poisson(lam)
            for _ in range(n):
                ts = start + dt.timedelta(seconds=rng.uniform(0, days * 86400))
                dev = rng.choice(devices)
                feat = wpick(rng, feats)
                self.out.feature_usage.append({
                    "usage_event_id": self._uid(), "customer_id": cid, "device_id": dev,
                    "platform": dev_platform[dev], "feature": feat, "event_ts": ts,
                    "duration_sec": int(rng.expovariate(1 / 120)) if feat == "vpn_connect"
                    or feat == "malware_scan" else None,
                    "threats_blocked": rng.choices([0, 1, 2], weights=[85, 12, 3])[0]
                    if feat in ("malware_scan", "web_protection_block") else 0,
                })

    def _poisson(self, lam: float) -> int:
        if lam > 30:  # normal approximation
            return max(0, int(round(self.rng.gauss(lam, math.sqrt(lam)))))
        L, k, p = math.exp(-lam), 0, 1.0
        while True:
            p *= self.rng.random()
            if p <= L:
                return k
            k += 1


def load_of(ts: dt.datetime) -> int:
    return 1 if ts < LOAD_CUTOFF else 2


def fmt(v):
    if isinstance(v, dt.datetime):
        return v.strftime("%Y-%m-%d %H:%M:%S")
    if v is None:
        return ""
    return v


def write_feed(con, tmp: Path, out: Path, feed: str, rows_by_load: dict[int, list[dict]],
               loaded_at: dict[int, dt.datetime], columns: list[str]):
    target = out / feed
    if target.exists():
        shutil.rmtree(target)
    for load, rows in rows_by_load.items():
        if not rows:
            continue
        csv_path = tmp / f"{feed}_{load}.csv"
        with csv_path.open("w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(columns + ["_loaded_at", "_load_date"])
            for r in rows:
                w.writerow([fmt(r[c]) for c in columns] + [fmt(loaded_at[load]), LOAD_DATES[load]])
        part = target / f"_load_date={LOAD_DATES[load]}"
        part.mkdir(parents=True, exist_ok=True)
        con.execute(
            f"copy (select * from read_csv('{csv_path}', header=true, all_varchar=true)) "
            f"to '{part / 'data_0.parquet'}' (format parquet, compression zstd)"
        )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--customers", type=int, default=20000)
    ap.add_argument("--usage-intensity", type=float, default=1.0,
                    help="multiplier on feature-usage event volume")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="data/landing")
    args = ap.parse_args()

    t0 = time.time()
    data = Generator(args.customers, args.usage_intensity, args.seed).run()

    now = dt.datetime.now(dt.UTC).replace(tzinfo=None, microsecond=0)
    loaded_at = {1: now - dt.timedelta(hours=6), 2: now - dt.timedelta(minutes=5)}

    # customers: load 1 carries the state as of the cutoff, load 2 carries rows that
    # were created or changed during October (a CDC-style delta).
    cust = {1: [], 2: []}
    for versions in data.customers:
        before = [v for v in versions if v["updated_at"] < LOAD_CUTOFF]
        after = [v for v in versions if v["updated_at"] >= LOAD_CUTOFF]
        if before:
            cust[1].append(before[-1])
        if after:
            cust[2].append(after[-1])

    def split(rows, ts_col):
        d = {1: [], 2: []}
        for r in rows:
            d[load_of(r[ts_col])].append(r)
        return d

    plan_rows = [dict(zip(["plan_id", "plan_name", "tier", "billing_period", "list_price_usd",
                           "max_devices", "includes_vpn", "includes_identity_protection",
                           "is_family_plan"], p, strict=True)) for p in PLANS]

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect()
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        write_feed(con, tmp, out, "customers", cust, loaded_at,
                   ["customer_id", "email", "first_name", "last_name", "phone", "country_code",
                    "marketing_opt_in", "created_at", "updated_at"])
        write_feed(con, tmp, out, "plans", {1: plan_rows}, loaded_at, list(plan_rows[0].keys()))
        write_feed(con, tmp, out, "subscription_events", split(data.subscription_events, "event_ts"),
                   loaded_at, list(data.subscription_events[0].keys()))
        write_feed(con, tmp, out, "payments", split(data.payments, "payment_ts"), loaded_at,
                   list(data.payments[0].keys()))
        write_feed(con, tmp, out, "feature_usage", split(data.feature_usage, "event_ts"), loaded_at,
                   list(data.feature_usage[0].keys()))

    print(f"customers (versions in landing): {len(cust[1]) + len(cust[2])}")
    print(f"subscription_events: {len(data.subscription_events)}")
    print(f"payments: {len(data.payments)}")
    print(f"feature_usage: {len(data.feature_usage)}")
    print(f"generated in {time.time() - t0:.1f}s -> {out}")


if __name__ == "__main__":
    main()
