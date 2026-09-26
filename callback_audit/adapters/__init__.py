"""Adapters: a platform's own exports in, the audit's records out.

Each adapter reads files a merchant can get without writing code (a dashboard export, one
SQL query) and returns the same records the generic readers return, plus notes on what it
could not match. Like the rest of the tool, nothing here connects to anything.
"""

from __future__ import annotations

import csv
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Generic, TypeVar

from ..model import Event, Payment
from ..readers import InputError

T = TypeVar("T")


@dataclass
class AdapterResult(Generic[T]):
    records: list[T]
    notes: list[str] = field(default_factory=list)


def read_rows(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    """CSV rows with stripped keys and values; repeated header lines (pages glued together) are dropped."""
    try:
        with path.open(newline="", encoding="utf-8-sig") as fh:
            reader = csv.DictReader(fh)
            if reader.fieldnames is None:
                raise InputError(f"{path}: empty file")
            fields = [(f or "").strip() for f in reader.fieldnames]
            rows = []
            for raw in reader:
                row = {(k or "").strip(): (v or "").strip() for k, v in raw.items() if k is not None}
                if all(row.get(f, "").lower() == f.lower() for f in fields):
                    continue  # a header line repeated by a paginated export
                rows.append(row)
    except OSError as exc:
        raise InputError(f"{path}: {exc}") from exc
    except csv.Error as exc:
        raise InputError(f"{path}: not a readable CSV ({exc})") from exc
    return rows, fields


def _n(count: int, noun: str) -> str:
    return f"{count} {noun}" + ("" if count == 1 else "s")


def find_column(fields: list[str], candidates: Iterable[str]) -> str | None:
    """The first field whose name matches one of ``candidates``, ignoring case and surrounding spaces."""
    by_lower = {f.strip().lower(): f for f in fields}
    for c in candidates:
        hit = by_lower.get(c.lower())
        if hit is not None:
            return hit
    return None


def join_notes(payments: list[Payment], events: list[Event], provider_success: set[str] | None) -> list[str]:
    """What the join between the two exports could not explain."""
    local = {p.id for p in payments}
    orphans: dict[str, bool] = {}
    for e in events:
        if e.payment_id not in local:
            won = bool(provider_success) and e.status.lower() in (provider_success or set())
            orphans[e.payment_id] = orphans.get(e.payment_id, False) or won
    matched = len({e.payment_id for e in events} & local)
    notes = [f"joined: {_n(matched, 'order')} in both exports"]
    if orphans:
        won = sum(1 for v in orphans.values() if v)
        notes.append(
            f"{_n(len(orphans), 'order')} only in the provider export ({won} with a successful payment): "
            "outside the date range of the orders export, or deleted — compare the ranges before reading anything into it"
        )
    return notes
