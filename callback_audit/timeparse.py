"""Timestamp parsing that is deliberately forgiving about input and strict about output.

Every function here returns a timezone-aware ``datetime`` in UTC. Naive inputs are
interpreted as UTC (stated in the README, so that the assumption is at least visible).
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone

_EPOCH_RE = re.compile(r"^\d{9,13}(\.\d+)?$")
# nginx/apache "common" and "combined" log timestamp: 10/Oct/2000:13:55:36 -0700
_CLF_RE = re.compile(
    r"^(?P<d>\d{1,2})/(?P<mon>[A-Za-z]{3})/(?P<y>\d{4}):(?P<H>\d{2}):(?P<M>\d{2}):(?P<S>\d{2})"
    r"(?:\s+(?P<sign>[+-])(?P<oh>\d{2})(?P<om>\d{2}))?$"
)
_MONTHS = {m: i for i, m in enumerate(("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"), start=1)}


class TimeParseError(ValueError):
    pass


def parse_ts(value: str | int | float | datetime) -> datetime:
    """Parse an epoch (s or ms), ISO 8601, or CLF timestamp into an aware UTC datetime."""
    if isinstance(value, datetime):
        return _to_utc(value)
    if isinstance(value, (int, float)):
        return _from_epoch(float(value))

    s = str(value).strip()
    if not s:
        raise TimeParseError("empty timestamp")

    if _EPOCH_RE.match(s):
        return _from_epoch(float(s))

    m = _CLF_RE.match(s)
    if m:
        offset = timedelta(0)
        if m.group("sign"):
            offset = timedelta(hours=int(m.group("oh")), minutes=int(m.group("om")))
            if m.group("sign") == "-":
                offset = -offset
        naive = datetime(
            int(m.group("y")),
            _MONTHS[m.group("mon").title()],
            int(m.group("d")),
            int(m.group("H")),
            int(m.group("M")),
            int(m.group("S")),
        )
        return _to_utc(naive.replace(tzinfo=timezone(offset)))

    iso = s
    if iso.endswith("Z") or iso.endswith("z"):
        iso = iso[:-1] + "+00:00"
    # "2026-09-13 10:00:00" and "2026-09-13T10:00:00" are both fine for fromisoformat.
    try:
        return _to_utc(datetime.fromisoformat(iso))
    except ValueError as exc:
        raise TimeParseError(f"unrecognised timestamp: {value!r}") from exc


def _from_epoch(x: float) -> datetime:
    if x > 1e11:  # milliseconds
        x = x / 1000.0
    return datetime.fromtimestamp(x, tz=timezone.utc)


def _to_utc(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def day_key(dt: datetime) -> str:
    """UTC calendar day, used to bucket everything by day."""
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%d")


def humanize(delta: timedelta) -> str:
    seconds = int(delta.total_seconds())
    if seconds < 0:
        return "-" + humanize(-delta)
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, _ = divmod(rem, 60)
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"
