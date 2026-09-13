"""Station 5 — "applied but not received": what the back office did by hand.

Two patterns in a status-history export:

* a transition *leaving* a terminal status — terminal was not terminal;
* several transitions of one payment inside a minute that either leave a terminal status or
  revisit a status already seen — someone flipping statuses to force a callback resend.
  A fast but normal lifecycle (created -> processing -> succeeded in 40 seconds) does not count.
  Every flip emits a callback and, in systems where transitions move money, moves it.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import timedelta

from ..model import Finding, Transition
from . import Context, na, sample

CHECK_LEAVE = "transitions leaving a terminal status"
CHECK_RAPID = "rapid transition chains (manual flipping)"


def _terminal_set(ctx: Context) -> set[str]:
    terminal = set((ctx.inputs.get("terminal_statuses") or "").lower().split(",")) - {""}
    if not terminal and ctx.payments:
        terminal = {p.status.lower() for p in ctx.payments if p.terminal}
    return terminal


def run(ctx: Context) -> list[Finding]:
    if ctx.history is None:
        return [na(5, CHECK_LEAVE, "--history (and --terminal)"), na(5, CHECK_RAPID, "--history")]
    terminal = _terminal_set(ctx)
    if not terminal:
        return [na(5, CHECK_LEAVE, "--terminal (to know which statuses are terminal)"), *_rapid(ctx, terminal)]

    leaving = [t for t in ctx.history if t.from_status.lower() in terminal]
    out: list[Finding] = []
    if leaving:
        pairs: dict[str, int] = defaultdict(int)
        for t in leaving:
            pairs[f"{t.from_status} -> {t.to_status}"] += 1
        out.append(
            Finding(
                5,
                CHECK_LEAVE,
                "suspect",
                f"{len(leaving)} transitions leave a terminal status ({len({t.payment_id for t in leaving})} payments)",
                [
                    "pairs: " + ", ".join(f"{k}: {v}" for k, v in sorted(pairs.items(), key=lambda kv: -kv[1])),
                    "examples: " + sample(sorted({t.payment_id for t in leaving}), ctx.options.top_n),
                ],
                next_step=(
                    "A terminal status should be terminal. Each of these emitted at least one extra callback to the receiver, "
                    "and if transitions move balances, moved money. Find who does this and why — usually to force a callback "
                    "resend that a resend button should do without touching state."
                ),
            )
        )
    else:
        out.append(Finding(5, CHECK_LEAVE, "ok", "no transition leaves a terminal status"))
    out.extend(_rapid(ctx, terminal))
    return out


def _rapid(ctx: Context, terminal: set[str]) -> list[Finding]:
    assert ctx.history is not None
    window = timedelta(seconds=ctx.options.rapid_chain_seconds)
    n = ctx.options.rapid_chain_len
    by_payment: dict[str, list[Transition]] = defaultdict(list)
    for t in ctx.history:
        by_payment[t.payment_id].append(t)
    chains: list[str] = []
    for pid, ts in by_payment.items():
        ts.sort(key=lambda t: t.at)
        for i in range(len(ts) - n + 1):
            chunk = ts[i : i + n]
            if chunk[-1].at - chunk[0].at > window:
                continue
            leaves_terminal = any(t.from_status.lower() in terminal for t in chunk)
            visited = [chunk[0].from_status.lower()] + [t.to_status.lower() for t in chunk]
            revisits = len(set(visited)) < len(visited)
            if leaves_terminal or revisits:
                chains.append(f"{pid}: " + " -> ".join(s or "(new)" for s in visited))
                break
    if chains:
        return [
            Finding(
                5,
                CHECK_RAPID,
                "suspect",
                f"{len(chains)} payments have {n}+ transitions within {ctx.options.rapid_chain_seconds}s that leave a terminal status or loop",
                ["examples: " + sample(chains, ctx.options.top_n)],
                next_step="This is the signature of manual status flipping. Compare with the deliveries export: each hop sent the receiver a callback.",
            )
        ]
    return [
        Finding(
            5,
            CHECK_RAPID,
            "ok",
            f"no payment has {n}+ transitions within {ctx.options.rapid_chain_seconds}s that leave a terminal status or loop",
        )
    ]
