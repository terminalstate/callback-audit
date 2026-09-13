"""Station 7 — the cheapest and most telling check: how old is your oldest non-terminal payment?"""

from __future__ import annotations

from collections import defaultdict
from datetime import timedelta

from ..model import Finding
from ..timeparse import humanize
from . import Context, na, sample

CHECK = "age of non-terminal payments"


def run(ctx: Context) -> list[Finding]:
    if ctx.payments is None:
        return [na(7, CHECK, "--payments")]

    now = ctx.options.now
    open_ = [p for p in ctx.payments if not p.terminal]
    if not open_:
        return [Finding(7, CHECK, "ok", f"{len(ctx.payments)} payments, none in a non-terminal state")]

    ages = sorted(((now - p.created_at), p) for p in open_)
    oldest_age, oldest = ages[-1]
    threshold = timedelta(hours=ctx.options.stuck_hours)
    stuck = [p for age, p in ages if age > threshold]

    buckets = {"< 1h": 0, "1h–24h": 0, "1d–7d": 0, "> 7d": 0}
    for age, _ in ages:
        h = age.total_seconds() / 3600
        if h < 1:
            buckets["< 1h"] += 1
        elif h < 24:
            buckets["1h–24h"] += 1
        elif h < 24 * 7:
            buckets["1d–7d"] += 1
        else:
            buckets["> 7d"] += 1

    details = [f"non-terminal: {len(open_)} of {len(ctx.payments)}; by age: " + ", ".join(f"{k}: {v}" for k, v in buckets.items())]

    by_status: dict[str, int] = defaultdict(int)
    by_provider: dict[str, int] = defaultdict(int)
    for p in stuck:
        by_status[p.status] += 1
        by_provider[p.provider or "(no provider)"] += 1
    if stuck:
        details.append(
            f"older than {ctx.options.stuck_hours:g}h: {len(stuck)} — by status: "
            + ", ".join(f"{s}: {n}" for s, n in sorted(by_status.items(), key=lambda kv: -kv[1]))
        )
        details.append("  by provider: " + ", ".join(f"{s}: {n}" for s, n in sorted(by_provider.items(), key=lambda kv: -kv[1])))
        details.append("  examples: " + sample((p.id for _, p in reversed(ages) if (now - p.created_at) > threshold), ctx.options.top_n))

    if stuck:
        return [
            Finding(
                7,
                CHECK,
                "suspect",
                f"oldest non-terminal payment is {humanize(oldest_age)} old (id {oldest.id}, status {oldest.status}); "
                f"{len(stuck)} older than {ctx.options.stuck_hours:g}h",
                details,
                next_step=(
                    "If the answer is 'days', there is no second path to a terminal state for these payments: "
                    "no status poll against the provider API, no sweep behind the one-shot timeout task, or the sweep is not running. "
                    "Pick three of the examples and trace each one through stations 1–6."
                ),
            )
        ]
    return [
        Finding(
            7,
            CHECK,
            "ok",
            f"oldest non-terminal payment is {humanize(oldest_age)} old; nothing older than {ctx.options.stuck_hours:g}h",
            details,
        )
    ]
