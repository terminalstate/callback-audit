"""Readers for the exports the audit consumes.

All readers are plain functions from a path to a list of records. They raise
``InputError`` with a message that names the file and the missing column, because a
report that silently skips half its input is worse than no report.
"""

from __future__ import annotations

import csv
import re
from collections import defaultdict
from pathlib import Path

from .model import Delivery, Event, Inbound, LogCounts, Payment, Transition
from .timeparse import TimeParseError, day_key, parse_ts


class InputError(ValueError):
    pass


_TRUE = {"1", "true", "t", "yes", "y"}


def _open_csv(path: Path, required: tuple[str, ...]) -> tuple[list[dict[str, str]], list[str]]:
    try:
        with path.open(newline="", encoding="utf-8-sig") as fh:
            reader = csv.DictReader(fh)
            if reader.fieldnames is None:
                raise InputError(f"{path}: empty file")
            fields = [f.strip() for f in reader.fieldnames]
            missing = [c for c in required if c not in fields]
            if missing:
                raise InputError(f"{path}: missing column(s) {', '.join(missing)}; found {', '.join(fields)}")
            rows = [{(k or "").strip(): (v or "").strip() for k, v in row.items()} for row in reader]
    except OSError as exc:
        raise InputError(f"{path}: {exc}") from exc
    return rows, fields


def _ts(path: Path, row_no: int, column: str, value: str):
    try:
        return parse_ts(value)
    except TimeParseError as exc:
        raise InputError(f"{path}, row {row_no}, column {column}: {exc}") from exc


def _is_terminal(status: str, row: dict[str, str], terminal_statuses: set[str] | None, path: Path) -> bool:
    if "terminal" in row and row["terminal"] != "":
        return row["terminal"].lower() in _TRUE
    if terminal_statuses is None:
        raise InputError(
            f"{path}: no 'terminal' column and no terminal status list given; "
            "pass --terminal succeeded,failed,canceled (your terminal statuses)"
        )
    return status.lower() in terminal_statuses


def read_payments(path: Path, terminal_statuses: set[str] | None) -> list[Payment]:
    rows, _ = _open_csv(path, ("id", "created_at", "status"))
    out: list[Payment] = []
    for i, row in enumerate(rows, start=2):
        status = row["status"]
        updated = row.get("updated_at") or ""
        out.append(
            Payment(
                id=row["id"],
                created_at=_ts(path, i, "created_at", row["created_at"]),
                status=status,
                terminal=_is_terminal(status, row, terminal_statuses, path),
                updated_at=_ts(path, i, "updated_at", updated) if updated else None,
                provider=row.get("provider", "") or "",
            )
        )
    return out


def read_deliveries(path: Path) -> list[Delivery]:
    rows, _ = _open_csv(path, ("payment_id", "attempt"))
    out: list[Delivery] = []
    for i, row in enumerate(rows, start=2):
        try:
            attempt = int(row["attempt"])
        except ValueError as exc:
            raise InputError(f"{path}, row {i}: attempt must be an integer, got {row['attempt']!r}") from exc
        code_raw = row.get("response_code", "") or ""
        code: int | None
        try:
            code = int(code_raw) if code_raw else None
        except ValueError:
            code = None  # "timeout", "ECONNREFUSED" and friends: a non-HTTP outcome
        sent_raw = row.get("sent_at", "") or ""
        out.append(
            Delivery(
                payment_id=row["payment_id"],
                attempt=attempt,
                sent_at=_ts(path, i, "sent_at", sent_raw) if sent_raw else None,
                response_code=code,
                response_body=row.get("response_body", "") or "",
            )
        )
    return out


def read_events(path: Path, terminal_statuses: set[str] | None) -> list[Event]:
    rows, _ = _open_csv(path, ("payment_id", "at", "status"))
    out: list[Event] = []
    for i, row in enumerate(rows, start=2):
        status = row["status"]
        out.append(
            Event(
                payment_id=row["payment_id"],
                at=_ts(path, i, "at", row["at"]),
                status=status,
                terminal=_is_terminal(status, row, terminal_statuses, path),
                event_id=row.get("event_id", "") or "",
            )
        )
    return out


def read_history(path: Path) -> list[Transition]:
    rows, _ = _open_csv(path, ("payment_id", "at", "from_status", "to_status"))
    return [
        Transition(
            payment_id=row["payment_id"],
            at=_ts(path, i, "at", row["at"]),
            from_status=row["from_status"],
            to_status=row["to_status"],
        )
        for i, row in enumerate(rows, start=2)
    ]


# nginx "combined" format:
# 203.0.113.9 - - [10/Sep/2026:13:55:36 +0000] "POST /webhooks/alpha HTTP/1.1" 200 12 "-" "alpha-webhooks/2.1"
_COMBINED_RE = re.compile(
    r'^(?P<remote>\S+)\s+\S+\s+\S+\s+\[(?P<ts>[^\]]+)\]\s+"(?P<method>[A-Z]+)\s+(?P<path>\S+)[^"]*"\s+'
    r"(?P<status>\d{3})\s+(?P<size>\S+)(?:\s+\"(?P<referer>[^\"]*)\"\s+\"(?P<ua>[^\"]*)\")?"
)


def read_inbound(path: Path, path_filter: str | None = None) -> list[Inbound]:
    """Read inbound webhook requests from a CSV (at,status_code[,path,remote,user_agent]) or an nginx combined log."""
    try:
        with path.open(encoding="utf-8", errors="replace") as fh:
            first = ""
            for line in fh:
                if line.strip():
                    first = line
                    break
    except OSError as exc:
        raise InputError(f"{path}: {exc}") from exc

    if "status_code" in first and "," in first:
        rows, _ = _open_csv(path, ("at", "status_code"))
        out: list[Inbound] = []
        for i, row in enumerate(rows, start=2):
            try:
                code = int(row["status_code"])
            except ValueError as exc:
                raise InputError(f"{path}, row {i}: status_code must be an integer") from exc
            rec = Inbound(
                at=_ts(path, i, "at", row["at"]),
                status_code=code,
                path=row.get("path", "") or "",
                remote=row.get("remote", "") or "",
                user_agent=row.get("user_agent", "") or "",
            )
            if path_filter and path_filter not in rec.path:
                continue
            out.append(rec)
        return out

    out = []
    skipped = 0
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = _COMBINED_RE.match(line)
            if not m:
                if line.strip():
                    skipped += 1
                continue
            if path_filter and path_filter not in m.group("path"):
                continue
            try:
                at = parse_ts(m.group("ts"))
            except TimeParseError:
                skipped += 1
                continue
            out.append(
                Inbound(
                    at=at,
                    status_code=int(m.group("status")),
                    path=m.group("path"),
                    remote=m.group("remote"),
                    user_agent=m.group("ua") or "",
                )
            )
    if not out and skipped:
        raise InputError(f"{path}: no lines matched the nginx combined format ({skipped} lines skipped)")
    return out


_LINE_TS_RE = re.compile(r"(\d{4}-\d{2}-\d{2})[T ]\d{2}:\d{2}:\d{2}")


def count_log_patterns(path: Path, patterns: dict[str, re.Pattern[str]]) -> LogCounts:
    """Count application-log lines matching each named pattern, bucketed by the day found in the line."""
    counts = LogCounts()
    by: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    try:
        with path.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if not line.strip():
                    continue
                counts.total_lines += 1
                m = _LINE_TS_RE.search(line)
                day = m.group(1) if m else "unknown-day"
                for name, rx in patterns.items():
                    if rx.search(line):
                        by[name][day] += 1
    except OSError as exc:
        raise InputError(f"{path}: {exc}") from exc
    counts.by_pattern_day = {k: dict(v) for k, v in by.items()}
    return counts


def by_day(items, key) -> dict[str, int]:
    out: dict[str, int] = defaultdict(int)
    for it in items:
        out[day_key(key(it))] += 1
    return dict(sorted(out.items()))
