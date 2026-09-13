"""Station 6 — applied but not visible. Not checkable from exports; the report says so honestly.

What it does: if both payments and history are present, it flags payments whose last history
transition reached a terminal status while the payments export still shows a non-terminal one —
the export and the history disagree, which is exactly the symptom (replica lag, cache, a
rolled-back write that logged success).
"""

from __future__ import annotations

from collections import defaultdict

from ..model import Finding, Transition
from . import Context, sample

CHECK = "payments export vs status history disagree"


def run(ctx: Context) -> list[Finding]:
    if ctx.payments is None or ctx.history is None:
        return [
            Finding(
                6,
                CHECK,
                "na",
                "not checkable from exports alone",
                next_step=(
                    "For three stuck payments compare the row on the primary with what the UI/report shows, and match 200 responses "
                    "in the access log against actual writes in the same minute. A 200 without a write is station 6."
                ),
            )
        ]
    last: dict[str, Transition] = {}
    for t in ctx.history:
        cur = last.get(t.payment_id)
        if cur is None or t.at > cur.at:
            last[t.payment_id] = t
    local = {p.id: p for p in ctx.payments}
    disagree = [pid for pid, t in last.items() if pid in local and local[pid].status.lower() != t.to_status.lower()]
    if disagree:
        by_pair: dict[str, int] = defaultdict(int)
        for pid in disagree:
            by_pair[f"history {last[pid].to_status} / export {local[pid].status}"] += 1
        return [
            Finding(
                6,
                CHECK,
                "suspect",
                f"{len(disagree)} payments where the last history transition and the payments export disagree",
                [
                    "pairs: " + ", ".join(f"{k}: {v}" for k, v in sorted(by_pair.items(), key=lambda kv: -kv[1])),
                    "examples: " + sample(disagree, ctx.options.top_n),
                ],
                next_step="Two exports from the same system disagree: one of them was read from a replica or a cache, or a write was rolled back after its history row was logged.",
            )
        ]
    return [Finding(6, CHECK, "ok", "payments export and status history agree on the current status")]
