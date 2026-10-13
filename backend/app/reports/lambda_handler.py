"""The report-builder Lambda: builds one week's report and saves it to S3.

Accepts two event shapes:
- a direct invocation, e.g. from EventBridge Scheduler: {"source": "schedule", "week": null}
- an SQS event (the report-requests queue), whose record bodies carry the same JSON.

A missing or null week means the previous full ISO week. The function never calls the mailer:
it only writes reports/<week>.csv, and S3 announces the new object to whoever listens.
"""

import json
import logging
import os
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

import boto3

from app.config import settings
from app.reports.weekly import build_weekly_report, last_full_week, report_key

log = logging.getLogger("report-builder")
log.setLevel(logging.INFO)

_s3 = None


def s3():
    # Created on first use, so importing this module (tests) needs no AWS configuration.
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3")
    return _s3


def detect_trigger(event: dict[str, Any]) -> str:
    """What started this invocation: "sqs", "schedule" (direct from the scheduler) or "direct"."""
    records = event.get("Records") or []
    if records and records[0].get("eventSource") == "aws:sqs":
        return "sqs"
    if event.get("source") == "schedule":
        return "schedule"
    return "direct"


def requests_from(event: dict[str, Any]) -> list[dict[str, Any]]:
    """The report requests in an event: one per SQS record, or the event itself."""
    if detect_trigger(event) == "sqs":
        return [json.loads(record["body"] or "{}") for record in event["Records"]]
    return [event]


def build_and_save(week: str) -> str:
    key = report_key(week)
    # Rehearses a failure for the DLQ exercise: deploy with REPORTS_BREAK_WEEK=<week>.
    if week == os.environ.get("REPORT_BREAK_WEEK"):
        raise RuntimeError(f"Deliberate failure for {week} (REPORT_BREAK_WEEK)")
    body = build_weekly_report(week)
    s3().put_object(
        Bucket=settings.reports_bucket, Key=key, Body=body, ContentType="text/csv; charset=utf-8"
    )
    return key


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    trigger = detect_trigger(event)
    today = datetime.now(ZoneInfo(settings.report_timezone)).date()
    keys = []
    # BatchSize is 1, so an SQS event holds one record; if it fails, the whole invocation fails
    # and SQS redelivers the message (to the DLQ after maxReceiveCount attempts).
    for request in requests_from(event):
        week = request.get("week") or last_full_week(today)
        log.info(
            "report-builder triggered",
            extra={"trigger": trigger, "source": request.get("source"), "week": week},
        )
        key = build_and_save(week)
        log.info("report saved", extra={"bucket": settings.reports_bucket, "key": key})
        keys.append(key)
    return {"keys": keys}
