"""Unit tests for the landing sensor logic (no Airflow or Snowflake needed)."""

import json
import re

import pytest

from include.landing_checks import ALL_PIPES, REQUIRED_FEEDS, check_landing, validate_load_date


def ilike(value: str, pattern: str) -> bool:
    """Snowflake ILIKE semantics: % = any run, _ = any one character."""
    regex = "".join(".*" if c == "%" else "." if c == "_" else re.escape(c) for c in pattern)
    return re.fullmatch(regex, value, re.IGNORECASE) is not None


class FakeCursor:
    """Answers COPY_HISTORY with per-feed (files, rows) and PIPE_STATUS with pending counts."""

    def __init__(self, loaded: dict, pending: dict):
        self.loaded, self.pending, self._row = loaded, pending, None

    def execute(self, sql, params=None):
        if "copy_history" in sql:
            feed = params["table"].split(".")[-1].lower()
            # COPY_HISTORY reports FILE_NAME relative to the pipe's stage path, e.g.
            # "_load_date=2025-11-01/data_0.parquet" (copied from a real run).
            date = re.search(r"\d{4}-\d{2}-\d{2}", params["pattern"]).group()
            assert ilike(f"_load_date={date}/data_0.parquet", params["pattern"])
            assert not ilike("_load_date=2025-10-01/data_0.parquet", params["pattern"])
            self._row = self.loaded.get(feed, (0, 0))
        else:
            pipe = sql.rsplit("pipe_", 1)[1].split("'")[0]
            self._row = (json.dumps({"pendingFileCount": self.pending.get(pipe, 0)}),)

    def fetchone(self):
        return self._row


def test_ready_when_all_feeds_loaded_and_pipes_idle():
    cur = FakeCursor({f: (1, 100) for f in REQUIRED_FEEDS}, {})
    status = check_landing(cur, "2025-11-01")
    assert status.ready
    assert "complete" in status.summary()
    assert set(status.pending_files) == set(ALL_PIPES)


def test_not_ready_when_a_feed_is_missing():
    loaded = {f: (1, 100) for f in REQUIRED_FEEDS if f != "payments"}
    status = check_landing(FakeCursor(loaded, {}), "2025-11-01")
    assert not status.ready
    assert status.missing_feeds == ["payments"]


def test_not_ready_while_a_pipe_has_pending_files():
    cur = FakeCursor({f: (1, 100) for f in REQUIRED_FEEDS}, {"feature_usage": 2})
    status = check_landing(cur, "2025-11-01")
    assert not status.ready
    assert status.busy_pipes == ["feature_usage"]


def test_plans_is_not_required():
    assert "plans" not in REQUIRED_FEEDS and "plans" in ALL_PIPES


@pytest.mark.parametrize("bad", ["", "2025-11-1", "2025-11-01' or 1=1 --", None])
def test_load_date_is_validated(bad):
    with pytest.raises(ValueError):
        validate_load_date(bad)
