"""Data model: what the audit reads, and what it produces."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Literal

Verdict = Literal["ok", "suspect", "info", "na"]


@dataclass(frozen=True)
class Payment:
    id: str
    created_at: datetime
    status: str
    terminal: bool
    updated_at: datetime | None = None
    provider: str = ""


@dataclass(frozen=True)
class Delivery:
    """One attempt to deliver a callback to a receiver (the sender's point of view)."""

    payment_id: str
    attempt: int
    sent_at: datetime | None
    response_code: int | None
    response_body: str = ""


@dataclass(frozen=True)
class Event:
    """A status event as the provider reports it (dashboard export, delivery log)."""

    payment_id: str
    at: datetime
    status: str
    terminal: bool
    event_id: str = ""
    ref: str = ""  # the provider's own object id (payment intent, charge) when one payment maps to several


@dataclass(frozen=True)
class Inbound:
    """One inbound HTTP request to your webhook endpoint (access log line or CSV row)."""

    at: datetime
    status_code: int
    path: str = ""
    remote: str = ""
    user_agent: str = ""


@dataclass(frozen=True)
class Transition:
    """One local status transition (status history table export)."""

    payment_id: str
    at: datetime
    from_status: str
    to_status: str


@dataclass
class LogCounts:
    """Counts of application-log lines matching named patterns, bucketed by day."""

    by_pattern_day: dict[str, dict[str, int]] = field(default_factory=dict)
    total_lines: int = 0

    def total(self, name: str) -> int:
        return sum(self.by_pattern_day.get(name, {}).values())


@dataclass
class Finding:
    station: int
    check: str
    verdict: Verdict
    summary: str
    details: list[str] = field(default_factory=list)
    next_step: str = ""

    def as_dict(self) -> dict:
        return {
            "station": self.station,
            "check": self.check,
            "verdict": self.verdict,
            "summary": self.summary,
            "details": list(self.details),
            "next_step": self.next_step,
        }


STATIONS: dict[int, str] = {
    1: "Provider never sent it (or sent it elsewhere)",
    2: "Sent, but it never reached you (network, edge)",
    3: "Reached you, rejected at the door (signature, auth)",
    4: "Accepted, parsed wrong (schema, status mapping)",
    5: "Parsed, not applied (state machine, ordering, dedup)",
    6: "Applied, not visible (transaction, replica, cache)",
    7: "Nobody is watching (no second path, silent retries)",
}
