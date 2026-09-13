"""Station 7 (sender side) — a retry ladder with no last rung.

If the query that picks rows for retry covers attempts < N and exactly N..M with backoff,
attempt M+1 falls out forever: no terminal status, no alert. The tell is a spike of
non-successful deliveries sitting at one exact attempt count with nothing above it.
"""

from __future__ import annotations

from collections import Counter, defaultdict

from ..model import Delivery, Finding
from . import Context, na, sample

CHECK = "retry ladder (attempt counter distribution)"


def _is_success(d: Delivery) -> bool:
    return d.response_code is not None and 200 <= d.response_code < 300


def run(ctx: Context) -> list[Finding]:
    if ctx.deliveries is None:
        return [na(7, CHECK, "--deliveries")]

    last_attempt: dict[str, Delivery] = {}
    for d in ctx.deliveries:
        cur = last_attempt.get(d.payment_id)
        if cur is None or d.attempt > cur.attempt:
            last_attempt[d.payment_id] = d

    unresolved = {pid: d for pid, d in last_attempt.items() if not _is_success(d)}
    if not unresolved:
        return [Finding(7, CHECK, "ok", f"{len(last_attempt)} payments with deliveries, all resolved with a 2xx")]

    dist = Counter(d.attempt for d in unresolved.values())
    ordered = sorted(dist.items())
    details = [
        f"payments whose last delivery attempt is not a 2xx: {len(unresolved)} of {len(last_attempt)}",
        "attempts at last try: " + ", ".join(f"{a}: {n}" for a, n in ordered),
    ]

    max_attempt = ordered[-1][0]
    at_max = dist[max_attempt]
    cliff = max_attempt >= 3 and at_max >= 5 and at_max / len(unresolved) >= 0.3
    if cliff:
        ids = [pid for pid, d in unresolved.items() if d.attempt == max_attempt]
        by_code: dict[str, int] = defaultdict(int)
        for pid in ids:
            by_code[str(unresolved[pid].response_code or "no-http")] += 1
        details.append(
            f"at attempt {max_attempt}: {at_max} payments, nothing above it; last response codes: "
            + ", ".join(f"{k}: {v}" for k, v in sorted(by_code.items()))
        )
        details.append("  examples: " + sample(ids, ctx.options.top_n))
        return [
            Finding(
                7,
                CHECK,
                "suspect",
                f"{at_max} unresolved deliveries sit at exactly attempt {max_attempt} and none above — looks like a retry ceiling",
                details,
                next_step=(
                    "Read the retry selection query: does it have a branch for attempts beyond the ladder? "
                    "These rows are probably not being retried and not being reported. Decide per row whether to "
                    "replay or close them — do not mass-replay stale statuses (see README, 'how not to fix it')."
                ),
            )
        ]
    return [Finding(7, CHECK, "ok", f"{len(unresolved)} unresolved deliveries, attempt counts spread without a cliff", details)]
