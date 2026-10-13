"""The weekly meetings report: plain Python and SQL, no AWS.

The week is always a parameter ("2026-W40"); nothing here decides which week is "last week".
The same week always maps to the same file name, so building a report twice overwrites one
file instead of creating two, and a message delivered twice does no harm.

Run it locally against the compose database:  python -m app.reports.weekly 2026-W40
"""

import asyncio
import csv
import io
import re
import sys
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import selectinload
from sqlalchemy.pool import NullPool

from app.config import settings
from app.models import Meeting, User

WEEK_PATTERN = re.compile(r"^(\d{4})-W(\d{2})$")
LONGEST_COUNT = 5


def parse_week(week: str) -> date:
    """The Monday of an ISO week such as "2026-W40"; raises ValueError for anything else."""
    match = WEEK_PATTERN.match(week)
    if not match:
        raise ValueError(f"Expected an ISO week like 2026-W40, got {week!r}")
    return date.fromisocalendar(int(match[1]), int(match[2]), 1)


def format_week(day: date) -> str:
    year, week, _ = day.isocalendar()
    return f"{year}-W{week:02d}"


def previous_week(week: str) -> str:
    return format_week(parse_week(week) - timedelta(weeks=1))


def last_full_week(today: date) -> str:
    """The ISO week before the one that contains `today`: what a Monday-morning run reports on."""
    return format_week(today - timedelta(weeks=1))


def report_key(week: str) -> str:
    """The S3 key of a week's report. One week, one key: rebuilding overwrites it."""
    parse_week(week)
    return f"reports/{week}.csv"


def week_bounds(week: str, tz: ZoneInfo) -> tuple[datetime, datetime]:
    """Monday 00:00 to the next Monday 00:00 in the report's time zone."""
    monday = parse_week(week)
    start = datetime.combine(monday, time.min, tzinfo=tz)
    return start, datetime.combine(monday + timedelta(weeks=1), time.min, tzinfo=tz)


def hours(meeting: Meeting) -> float:
    return (meeting.ends_at - meeting.starts_at).total_seconds() / 3600


@dataclass
class PersonTotals:
    name: str
    email: str
    meetings: int = 0
    hours: float = 0.0


async def meetings_in_week(session: AsyncSession, week: str, tz: ZoneInfo) -> list[Meeting]:
    """Meetings that start in the week, with their organiser and participants loaded."""
    start, end = week_bounds(week, tz)
    result = await session.scalars(
        select(Meeting)
        .where(Meeting.starts_at >= start, Meeting.starts_at < end)
        .options(selectinload(Meeting.participants))
        .order_by(Meeting.starts_at, Meeting.id)
    )
    return list(result)


async def build_report_csv(session: AsyncSession, week: str, tz: ZoneInfo) -> bytes:
    """The CSV for one week, compared with the week before."""
    before = previous_week(week)
    this = await meetings_in_week(session, week, tz)
    last = await meetings_in_week(session, before, tz)
    owners = {
        user.id: user
        for user in await session.scalars(
            select(User).where(User.id.in_({m.owner_id for m in this}))
        )
    }

    this_hours = sum(map(hours, this))
    last_hours = sum(map(hours, last))
    start, end = week_bounds(week, tz)

    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(["Weekly meetings report", week])
    last_day = (end - timedelta(days=1)).date()
    writer.writerow(["Period", start.date().isoformat(), last_day.isoformat()])
    writer.writerow(["Time zone", str(tz)])
    writer.writerow([])

    writer.writerow(["Summary", "This week", f"Previous week ({before})", "Change"])
    writer.writerow(["Meetings", len(this), len(last), f"{len(this) - len(last):+d}"])
    writer.writerow(
        ["Hours", f"{this_hours:.2f}", f"{last_hours:.2f}", f"{this_hours - last_hours:+.2f}"]
    )
    writer.writerow([])

    writer.writerow([f"Longest {LONGEST_COUNT} meetings"])
    writer.writerow(["Title", "Start", "Duration (h)", "Participants"])
    # Ties are broken by start time, so the same data always gives the same file.
    for meeting in sorted(this, key=lambda m: (-hours(m), m.starts_at))[:LONGEST_COUNT]:
        writer.writerow(
            [
                meeting.title,
                meeting.starts_at.astimezone(tz).isoformat(timespec="minutes"),
                f"{hours(meeting):.2f}",
                len(meeting.participants),
            ]
        )
    writer.writerow([])

    per_organiser: dict[object, PersonTotals] = {}
    per_participant: dict[object, PersonTotals] = {}
    for meeting in this:
        owner = owners[meeting.owner_id]
        people = [(owner.id, owner.name, owner.email, per_organiser)]
        people += [(p.id, p.name, p.email, per_participant) for p in meeting.participants]
        for key, name, email, totals in people:
            person = totals.setdefault(key, PersonTotals(name, email))
            person.meetings += 1
            person.hours += hours(meeting)

    for title, totals in (("Organiser", per_organiser), ("Participant", per_participant)):
        writer.writerow([f"Per {title.lower()}"])
        writer.writerow([title, "Email", "Meetings", "Hours"])
        for person in sorted(totals.values(), key=lambda p: (-p.hours, p.name, p.email)):
            writer.writerow([person.name, person.email, person.meetings, f"{person.hours:.2f}"])
        writer.writerow([])

    return out.getvalue().encode()


def build_weekly_report(week: str) -> bytes:
    """Query the meetings of one ISO week (e.g. "2026-W40") and return the CSV."""
    parse_week(week)

    async def run() -> bytes:
        # A fresh engine per call: asyncio.run() starts a new event loop every time, and pooled
        # asyncpg connections cannot move between loops.
        engine = create_async_engine(settings.database_url, poolclass=NullPool)
        try:
            async with async_sessionmaker(engine)() as session:
                return await build_report_csv(session, week, ZoneInfo(settings.report_timezone))
        finally:
            await engine.dispose()

    return asyncio.run(run())


if __name__ == "__main__":
    if len(sys.argv) > 2:
        sys.exit("Usage: python -m app.reports.weekly [2026-W40]")
    week = sys.argv[1] if len(sys.argv) == 2 else last_full_week(date.today())
    sys.stdout.write(build_weekly_report(week).decode())
