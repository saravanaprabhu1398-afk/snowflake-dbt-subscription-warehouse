"""Is a landing load fully in RAW? Used by the Airflow sensor before dbt runs.

Only metadata functions are used (COPY_HISTORY, SYSTEM$PIPE_STATUS), so polling needs no
running warehouse and costs no compute credits while the DAG waits for producers.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field

# Feeds every daily load must contain. `plans` is reference data that only lands when the
# catalogue changes, so it is checked for pending files but not required.
REQUIRED_FEEDS = ("customers", "subscription_events", "payments", "feature_usage")
ALL_PIPES = (*REQUIRED_FEEDS, "plans")

_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

COPY_HISTORY_SQL = """
select count(*) as files, coalesce(sum(row_count), 0) as rows_loaded
from table(raw.information_schema.copy_history(
    table_name => %(table)s,
    start_time => dateadd(day, -14, current_timestamp())))
where status = 'Loaded'
  and file_name ilike %(pattern)s
"""


@dataclass
class LandingStatus:
    load_date: str
    files: dict[str, int] = field(default_factory=dict)
    rows: dict[str, int] = field(default_factory=dict)
    pending_files: dict[str, int] = field(default_factory=dict)

    @property
    def missing_feeds(self) -> list[str]:
        return [f for f in REQUIRED_FEEDS if self.files.get(f, 0) == 0]

    @property
    def busy_pipes(self) -> list[str]:
        return [p for p, n in self.pending_files.items() if n > 0]

    @property
    def ready(self) -> bool:
        return not self.missing_feeds and not self.busy_pipes

    def summary(self) -> str:
        if self.ready:
            loaded = ", ".join(f"{f}={self.rows[f]:,}" for f in REQUIRED_FEEDS)
            return f"load {self.load_date} complete: {loaded}"
        return (
            f"load {self.load_date} not ready: missing={self.missing_feeds or '-'} "
            f"pipes_with_pending_files={self.busy_pipes or '-'}"
        )

    def as_dict(self) -> dict:
        return {
            "load_date": self.load_date,
            "ready": self.ready,
            "rows": self.rows,
            "files": self.files,
            "pending_files": self.pending_files,
        }


def validate_load_date(value: str) -> str:
    if not _DATE.match(value or ""):
        raise ValueError(f"load_date must be YYYY-MM-DD, got {value!r}")
    return value


def check_landing(cursor, load_date: str) -> LandingStatus:
    """Collect copy history and pipe backlog for one landing partition (_load_date=...)."""
    load_date = validate_load_date(load_date)
    status = LandingStatus(load_date=load_date)
    for feed in REQUIRED_FEEDS:
        cursor.execute(
            COPY_HISTORY_SQL,
            {"table": f"RAW.LANDING.{feed.upper()}", "pattern": f"%_load_date={load_date}/%"},
        )
        files, rows = cursor.fetchone()
        status.files[feed] = int(files)
        status.rows[feed] = int(rows)
    for pipe in ALL_PIPES:
        # Pipe names come from the fixed tuple above, never from user input.
        cursor.execute(f"select system$pipe_status('raw.landing.pipe_{pipe}')")
        status.pending_files[pipe] = int(json.loads(cursor.fetchone()[0]).get("pendingFileCount", 0))
    return status
