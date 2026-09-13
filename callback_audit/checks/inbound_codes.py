"""Stations 2–3 — response codes your webhook endpoint returned, per day, and gaps in the timeline."""

from __future__ import annotations

from collections import defaultdict
from datetime import timedelta

from ..model import Finding
from ..timeparse import day_key
from . import Context, na

CHECK = "inbound response codes per day"


def run(ctx: Context) -> list[Finding]:
    if ctx.inbound is None:
        return [na(2, CHECK, "--inbound")]
    if not ctx.inbound:
        return [Finding(2, CHECK, "info", "inbound log is empty after filtering (check --path-filter)")]

    per_day: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for r in ctx.inbound:
        klass = f"{r.status_code // 100}xx"
        per_day[day_key(r.at)][klass] += 1

    bad_days: list[tuple[str, float]] = []
    rows: list[str] = []
    for day in sorted(per_day):
        counts = per_day[day]
        total = sum(counts.values())
        bad = total - counts.get("2xx", 0)
        share = bad / total if total else 0.0
        flag = ""
        if total >= 10 and share >= ctx.options.inbound_error_share:
            flag = f"  <- {share:.0%} non-2xx"
            bad_days.append((day, share))
        rows.append(f"{day}: " + ", ".join(f"{k}: {v}" for k, v in sorted(counts.items())) + flag)

    # gaps: calendar days with no inbound at all between first and last seen day
    first = min(r.at for r in ctx.inbound)
    last = max(r.at for r in ctx.inbound)
    gaps = []
    d = first
    while d <= last:
        if day_key(d) not in per_day:
            gaps.append(day_key(d))
        d += timedelta(days=1)

    details = rows[-14:] if len(rows) > 14 else rows
    if gaps:
        details.append(f"days with zero inbound requests inside the observed window: {', '.join(gaps[:10])}")

    if bad_days:
        worst = max(bad_days, key=lambda x: x[1])
        return [
            Finding(
                2,
                CHECK,
                "suspect",
                f"{len(bad_days)} day(s) with a non-2xx share above {ctx.options.inbound_error_share:.0%} (worst: {worst[0]} at {worst[1]:.0%})",
                details,
                next_step=(
                    "4xx concentrated on one day: rotation (secret, certificate, IP) or a deploy — station 3. "
                    "5xx/504 from the balancer rather than the app: ingress timeout shorter than the handler — station 2, "
                    "and the provider is probably retrying into duplicates."
                ),
            )
        ]
    if gaps:
        return [
            Finding(
                2,
                CHECK,
                "suspect",
                f"{len(gaps)} day(s) with no inbound requests at all inside the observed window",
                details,
                next_step="A silent day is station 1 or 2: nothing arrived. Cross-check with the provider's delivery log for that day.",
            )
        ]
    return [Finding(2, CHECK, "ok", "no day with an elevated non-2xx share and no silent days", details)]
