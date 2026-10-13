import csv
import io
import json
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.models import Base, Meeting, Participant, User
from app.reports import lambda_handler
from app.reports.weekly import (
    build_report_csv,
    last_full_week,
    parse_week,
    previous_week,
    report_key,
    week_bounds,
)

KYIV = ZoneInfo("Europe/Kyiv")


def at(day: int, hour: int, minute: int = 0) -> datetime:
    """A moment in Kyiv during the week of Monday 2026-09-28 (2026-W40); day 0 is Monday."""
    return datetime(2026, 9, 28, hour, minute, tzinfo=KYIV) + timedelta(days=day)


def test_parse_week() -> None:
    assert parse_week("2026-W40") == date(2026, 9, 28)
    for bad in ("2026-40", "2026-W4", "last week", "2026-W54"):
        with pytest.raises(ValueError):
            parse_week(bad)


def test_week_arithmetic() -> None:
    assert previous_week("2026-W40") == "2026-W39"
    assert previous_week("2026-W01") == "2025-W52"
    # Any day of W41 (Monday 2026-10-05 to Sunday 2026-10-11) reports on W40.
    assert last_full_week(date(2026, 10, 5)) == "2026-W40"
    assert last_full_week(date(2026, 10, 11)) == "2026-W40"
    assert report_key("2026-W40") == "reports/2026-W40.csv"
    start, end = week_bounds("2026-W40", KYIV)
    assert start.isoformat() == "2026-09-28T00:00:00+03:00"
    assert end - start == timedelta(weeks=1)


def sections(report: bytes) -> dict[str, list[list[str]]]:
    """The CSV split at blank lines, keyed by each block's first cell."""
    blocks: dict[str, list[list[str]]] = {}
    current: list[list[str]] = []
    for row in csv.reader(io.StringIO(report.decode())):
        if not row:
            current = []
            continue
        if not current:
            blocks[row[0]] = current
        current.append(row)
    return blocks


async def test_weekly_report(engine) -> None:
    async with engine.begin() as conn:
        for table in reversed(Base.metadata.sorted_tables):
            await conn.execute(table.delete())

    async with async_sessionmaker(engine, expire_on_commit=False)() as session:
        alice = User(cognito_sub="alice", email="alice@example.com", name="Alice")
        bob = User(cognito_sub="bob", email="bob@example.com", name="Bob")
        olena = Participant(name="Olena", email="olena@example.com")
        taras = Participant(name="Taras", email="taras@example.com")
        session.add_all([alice, bob, olena, taras])
        await session.flush()

        def meeting(title: str, start: datetime, minutes: int, owner: User, people=()) -> Meeting:
            return Meeting(
                title=title,
                starts_at=start,
                ends_at=start + timedelta(minutes=minutes),
                place="Room 1",
                owner_id=owner.id,
                participants=list(people),
            )

        session.add_all(
            [
                # 2026-W40: six meetings, 9.5 hours.
                meeting("Planning", at(0, 10), 120, alice, [olena, taras]),
                meeting("Standup", at(1, 9), 30, alice, [olena]),
                meeting("Review", at(2, 14), 90, bob, [taras]),
                meeting("Workshop", at(3, 10), 240, bob, [olena, taras]),
                meeting("Sync", at(4, 16), 60, alice),
                # Sunday 23:30 in Kyiv is Sunday 20:30 UTC: still W40.
                meeting("Late call", at(6, 23, 30), 30, alice),
                # 2026-W39: two meetings, 1.5 hours.
                meeting("Old planning", at(-7, 10), 60, alice),
                meeting("Old standup", at(-6, 9), 30, bob),
                # Monday 00:00 of W41: not in the report.
                meeting("Next week", at(7, 0), 60, alice),
            ]
        )
        await session.commit()

        report = await build_report_csv(session, "2026-W40", KYIV)

    blocks = sections(report)
    assert blocks["Weekly meetings report"][0] == ["Weekly meetings report", "2026-W40"]
    assert blocks["Weekly meetings report"][1] == ["Period", "2026-09-28", "2026-10-04"]
    assert blocks["Summary"][1:] == [
        ["Meetings", "6", "2", "+4"],
        ["Hours", "9.50", "1.50", "+8.00"],
    ]
    assert blocks["Longest 5 meetings"][2:] == [
        ["Workshop", "2026-10-01T10:00+03:00", "4.00", "2"],
        ["Planning", "2026-09-28T10:00+03:00", "2.00", "2"],
        ["Review", "2026-09-30T14:00+03:00", "1.50", "1"],
        ["Sync", "2026-10-02T16:00+03:00", "1.00", "0"],
        ["Standup", "2026-09-29T09:00+03:00", "0.50", "1"],
    ]
    assert blocks["Per organiser"][2:] == [
        ["Bob", "bob@example.com", "2", "5.50"],
        ["Alice", "alice@example.com", "4", "4.00"],
    ]
    assert blocks["Per participant"][2:] == [
        ["Taras", "taras@example.com", "3", "7.50"],
        ["Olena", "olena@example.com", "3", "6.50"],
    ]


def test_detect_trigger() -> None:
    sqs = {"Records": [{"eventSource": "aws:sqs", "body": '{"week": "2026-W39"}'}]}
    assert lambda_handler.detect_trigger(sqs) == "sqs"
    assert lambda_handler.detect_trigger({"source": "schedule"}) == "schedule"
    assert lambda_handler.detect_trigger({"week": "2026-W39"}) == "direct"


def test_handler_accepts_both_shapes(monkeypatch) -> None:
    built: list[str] = []
    monkeypatch.setattr(
        lambda_handler, "build_and_save", lambda week: built.append(week) or report_key(week)
    )
    body = json.dumps({"week": "2026-W39", "source": "make report-now"})
    sqs = {"Records": [{"eventSource": "aws:sqs", "body": body}]}

    assert lambda_handler.handler(sqs, None) == {"keys": ["reports/2026-W39.csv"]}
    # The scheduler sends no week: the handler picks the previous full week.
    result = lambda_handler.handler({"source": "schedule", "week": None}, None)

    assert built == ["2026-W39", last_full_week(datetime.now(KYIV).date())]
    assert result == {"keys": [report_key(built[1])]}


def test_break_week(monkeypatch) -> None:
    monkeypatch.setenv("REPORT_BREAK_WEEK", "2026-W13")
    with pytest.raises(RuntimeError, match="Deliberate failure"):
        lambda_handler.build_and_save("2026-W13")
