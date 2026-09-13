"""Station 5 — compare the provider's sequence of events with what you applied.

Three things fall out of one join between ``events.csv`` and ``payments.csv``:

* provider says terminal, you say pending — the core symptom, with names attached;
* one event id reused across several statuses — dedup on event id drops legitimate transitions;
* a terminal event followed by a non-terminal one — out-of-order delivery your state machine must survive.
"""

from __future__ import annotations

from collections import defaultdict

from ..model import Event, Finding
from ..timeparse import humanize
from . import Context, na, sample

CHECK_TERMINAL = "provider terminal, local non-terminal"
CHECK_REUSE = "event id reused across statuses"
CHECK_ORDER = "terminal event followed by a non-terminal one"


def run(ctx: Context) -> list[Finding]:
    if ctx.events is None:
        return [na(5, CHECK_TERMINAL, "--events (and --payments)"), na(5, CHECK_REUSE, "--events"), na(5, CHECK_ORDER, "--events")]

    by_payment: dict[str, list[Event]] = defaultdict(list)
    for e in ctx.events:
        by_payment[e.payment_id].append(e)
    for evs in by_payment.values():
        evs.sort(key=lambda e: e.at)

    out: list[Finding] = []

    # 1. provider terminal vs local non-terminal
    if ctx.payments is None:
        out.append(na(5, CHECK_TERMINAL, "--payments"))
    else:
        local = {p.id: p for p in ctx.payments}
        mismatched: list[tuple[str, Event, str]] = []
        for pid, evs in by_payment.items():
            p = local.get(pid)
            if p is None or p.terminal:
                continue
            last_terminal = next((e for e in reversed(evs) if e.terminal), None)
            if last_terminal is not None:
                mismatched.append((pid, last_terminal, p.status))
        if mismatched:
            mismatched.sort(key=lambda m: m[1].at)
            oldest = mismatched[0]
            by_status: dict[str, int] = defaultdict(int)
            for _, ev, local_status in mismatched:
                by_status[f"{ev.status} -> local {local_status}"] += 1
            out.append(
                Finding(
                    5,
                    CHECK_TERMINAL,
                    "suspect",
                    f"{len(mismatched)} payments are terminal at the provider but non-terminal locally (oldest terminal event {humanize(ctx.options.now - oldest[1].at)} ago)",
                    [
                        "provider status -> local status: "
                        + ", ".join(f"{k}: {v}" for k, v in sorted(by_status.items(), key=lambda kv: -kv[1])),
                        "examples: " + sample((m[0] for m in mismatched), ctx.options.top_n),
                    ],
                    next_step=(
                        "This is the list to trace. For each id: did the request reach your edge (station 2)? was it rejected (3)? "
                        "accepted but misparsed (4)? or applied to a state machine that refused the transition (5)? "
                        "A non-success terminal status that your rules do not finalise is a common cause here."
                    ),
                )
            )
        else:
            out.append(Finding(5, CHECK_TERMINAL, "ok", "every payment the provider reports as terminal is terminal locally"))

    # 2. event id reuse
    reuse: dict[tuple[str, str], set[str]] = defaultdict(set)
    for e in ctx.events:
        if e.event_id:
            reuse[(e.payment_id, e.event_id)].add(e.status)
    reused = {k: v for k, v in reuse.items() if len(v) > 1}
    if not any(e.event_id for e in ctx.events):
        out.append(Finding(5, CHECK_REUSE, "info", "events export has no event_id column — cannot check id reuse"))
    elif reused:
        out.append(
            Finding(
                5,
                CHECK_REUSE,
                "suspect",
                f"{len(reused)} event ids carry more than one status for the same payment",
                [
                    "examples: "
                    + sample((f"{pid}/{eid} ({', '.join(sorted(sts))})" for (pid, eid), sts in sorted(reused.items())), ctx.options.top_n)
                ],
                next_step=(
                    "If your receiver deduplicates on the provider's event id, the second (legitimate) transition is dropped as a duplicate. "
                    "Deduplicate on (payment id, status, timestamp) or on a hash of the body instead."
                ),
            )
        )
    else:
        out.append(Finding(5, CHECK_REUSE, "ok", "no event id is reused across statuses"))

    # 3. out-of-order
    ooo: list[str] = []
    for pid, evs in by_payment.items():
        seen_terminal = False
        for e in evs:
            if seen_terminal and not e.terminal:
                ooo.append(f"{pid} ({e.status} after a terminal event)")
                break
            if e.terminal:
                seen_terminal = True
    if ooo:
        out.append(
            Finding(
                5,
                CHECK_ORDER,
                "info",
                f"{len(ooo)} payments received a non-terminal event after a terminal one",
                ["examples: " + sample(ooo, ctx.options.top_n)],
                next_step=(
                    "Delivery order is not guaranteed. A state machine that rejects the backwards transition and then applies the "
                    "late 'processing' event strands the payment. Terminal must stay terminal; late non-terminal events should be ignored, loudly."
                ),
            )
        )
    else:
        out.append(Finding(5, CHECK_ORDER, "ok", "no non-terminal event arrived after a terminal one"))
    return out
