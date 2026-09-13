"""Stations 1–2 — count what the provider says it sent against what your edge saw, per day."""

from __future__ import annotations

from ..model import Finding
from ..readers import by_day
from . import Context, na

CHECK = "sent vs received per day"


def run(ctx: Context) -> list[Finding]:
    if ctx.events is None or ctx.inbound is None:
        return [na(1, CHECK, "--events and --inbound")]

    sent = by_day(ctx.events, lambda e: e.at)
    received = by_day(ctx.inbound, lambda r: r.at)
    days = sorted(set(sent) | set(received))
    short: list[str] = []
    rows: list[str] = []
    for day in days:
        s, r = sent.get(day, 0), received.get(day, 0)
        flag = ""
        if s and r < s * 0.9:
            flag = "  <- fewer received than sent"
            short.append(day)
        rows.append(f"{day}: sent {s:>5}  received {r:>5}{flag}")
    details = rows[-14:] if len(rows) > 14 else rows
    details.append("received > sent on a day is normal (provider retries, health checks on the same path); received < sent is not")
    if short:
        return [
            Finding(
                1,
                CHECK,
                "suspect",
                f"{len(short)} day(s) where your edge saw fewer requests than the provider reports sending (worst: {short[0]})",
                details,
                next_step=(
                    "Station 1 or 2. Check the provider's delivery log for those days (callback URL, event types they actually send), "
                    "then your ingress/WAF logs for rejected or missing connections (IP allowlist, TLS chain, timeouts)."
                ),
            )
        ]
    return [Finding(1, CHECK, "ok", "daily counts of provider events and inbound requests agree", details)]
