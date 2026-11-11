"""Failure alerting for the warehouse DAGs.

Always logs an ERROR line with the failing task and a link to its log. If ALERT_WEBHOOK_URL is
set (Slack / Teams / Google Chat style incoming webhook), the same text is posted there.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.request

log = logging.getLogger(__name__)


def build_message(context: dict) -> str:
    ti = context.get("task_instance")
    dag_id = getattr(ti, "dag_id", "?")
    task_id = getattr(ti, "task_id", "?")
    try_number = getattr(ti, "try_number", "?")
    run_id = context.get("run_id", "?")
    log_url = getattr(ti, "log_url", "")
    error = context.get("exception")
    text = f":red_circle: {dag_id}.{task_id} failed (try {try_number}, run {run_id})"
    if error:
        text += f"\n> {str(error).splitlines()[0][:300]}"
    if log_url:
        text += f"\n{log_url}"
    return text


def notify_failure(context: dict) -> None:
    text = build_message(context)
    log.error(text)
    url = os.environ.get("ALERT_WEBHOOK_URL")
    if not url:
        return
    req = urllib.request.Request(
        url,
        data=json.dumps({"text": text}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:  # noqa: S310 - URL is operator config
            log.info("alert webhook answered %s", resp.status)
    except Exception:  # alerting must never mask the original failure
        log.exception("alert webhook failed")
