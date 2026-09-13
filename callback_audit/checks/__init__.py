"""The checks, one module per station family. Each exposes ``run(ctx) -> list[Finding]``."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime

from ..model import Delivery, Event, Finding, Inbound, LogCounts, Payment, Transition


@dataclass
class Options:
    now: datetime
    stuck_hours: float = 24.0
    inbound_error_share: float = 0.05  # per-day share of non-2xx inbound that is worth a look
    signature_share: float = 0.01  # share of inbound requests failing signature verification
    rapid_chain_seconds: int = 60  # N transitions of one payment inside this window = manual flipping
    rapid_chain_len: int = 3
    top_n: int = 10  # how many example ids to print per finding


@dataclass
class Context:
    options: Options
    payments: list[Payment] | None = None
    deliveries: list[Delivery] | None = None
    events: list[Event] | None = None
    inbound: list[Inbound] | None = None
    history: list[Transition] | None = None
    log_counts: LogCounts | None = None
    log_patterns: dict[str, re.Pattern[str]] = field(default_factory=dict)
    inputs: dict[str, str] = field(default_factory=dict)  # name -> path, for the report header


def run_all(ctx: Context) -> list[Finding]:
    from . import counters, delivery_bodies, history, inbound_codes, log_patterns, retry_ladder, sequence, stuck_age, visibility

    findings: list[Finding] = []
    for module in (stuck_age, counters, inbound_codes, log_patterns, delivery_bodies, sequence, history, visibility, retry_ladder):
        findings.extend(module.run(ctx))
    findings.sort(key=lambda f: (f.station, f.check))
    return findings


def na(station: int, check: str, needs: str) -> Finding:
    return Finding(station=station, check=check, verdict="na", summary=f"not checked: needs {needs}")


def sample(ids, n: int) -> str:
    ids = list(ids)
    shown = ", ".join(ids[:n])
    if len(ids) > n:
        shown += f" … (+{len(ids) - n} more)"
    return shown
