"""Station 5 — compare the provider's sequence of events with what you applied.

Four things fall out of one join between ``events.csv`` and ``payments.csv``:

* provider says terminal, you say pending — the core symptom, with names attached;
* provider says the money arrived, you closed the payment as failed or cancelled — the expensive
  variant (needs ``--success``/``--provider-success``);
* one event id reused across several statuses — dedup on event id drops legitimate transitions;
* a terminal event followed by a non-terminal one — out-of-order delivery your state machine must survive.
"""

from __future__ import annotations

from collections import defaultdict

from ..model import Event, Finding
from ..timeparse import humanize
from . import Context, na, sample

CHECK_TERMINAL = "provider terminal, local non-terminal"
CHECK_OUTCOME = "provider success, local terminal failure"
CHECK_REUSE = "event id reused across statuses"
CHECK_ORDER = "terminal event followed by a non-terminal one"

_NEEDS_SUCCESS = "--success"


def provider_success(evs: list[Event], success: set[str] | None) -> Event | None:
    """The event in which the provider last said "succeeded", if that is still its final word.

    ``evs`` must be sorted by time. Events are grouped by ``ref`` (the provider's own object:
    a payment intent, a charge); without refs the whole payment is one object. Per object the
    last terminal event decides, so a success that was later refunded or reversed does not
    count, while a success next to a second, cancelled attempt does.
    """
    if not success:
        return None
    by_ref: dict[str, list[Event]] = defaultdict(list)
    for e in evs:
        by_ref[e.ref].append(e)
    found: Event | None = None
    for obj in by_ref.values():
        last = next((e for e in reversed(obj) if e.terminal), None)
        if last is not None and last.status.lower() in success and (found is None or last.at < found.at):
            found = last
    return found


def run(ctx: Context) -> list[Finding]:
    if ctx.events is None:
        return [
            na(5, CHECK_TERMINAL, "--events (and --payments)"),
            na(5, CHECK_OUTCOME, f"--events, --payments, {_NEEDS_SUCCESS}"),
            na(5, CHECK_REUSE, "--events"),
            na(5, CHECK_ORDER, "--events"),
        ]

    by_payment: dict[str, list[Event]] = defaultdict(list)
    for e in ctx.events:
        by_payment[e.payment_id].append(e)
    for evs in by_payment.values():
        evs.sort(key=lambda e: e.at)

    out: list[Finding] = []

    # 1. provider terminal vs local non-terminal
    won_statuses = ctx.options.provider_success
    if ctx.payments is None:
        out.append(na(5, CHECK_TERMINAL, "--payments"))
    else:
        local = {p.id: p for p in ctx.payments}
        mismatched: list[tuple[str, Event, str, bool]] = []
        for pid, evs in by_payment.items():
            p = local.get(pid)
            if p is None or p.terminal:
                continue
            won = provider_success(evs, won_statuses)
            shown = won or next((e for e in reversed(evs) if e.terminal), None)
            if shown is not None:
                mismatched.append((pid, shown, p.status, won is not None))
        if mismatched:
            oldest = min(mismatched, key=lambda m: m[1].at)
            mismatched.sort(key=lambda m: (not m[3], m[1].at))  # the ones the provider calls a success first
            n_won = sum(1 for m in mismatched if m[3])
            by_status: dict[str, int] = defaultdict(int)
            for _, ev, local_status, _won in mismatched:
                by_status[f"{ev.status} -> local {local_status}"] += 1
            summary = f"{len(mismatched)} payments are terminal at the provider but non-terminal locally (oldest terminal event {humanize(ctx.options.now - oldest[1].at)} ago)"
            next_step = (
                "This is the list to trace. For each id: did the request reach your edge (station 2)? was it rejected (3)? "
                "accepted but misparsed (4)? or applied to a state machine that refused the transition (5)? "
                "A non-success terminal status that your rules do not finalise is a common cause here."
            )
            if won_statuses:
                summary += f"; {n_won} of them succeeded at the provider"
                if n_won:
                    next_step = (
                        "Start with the ones that succeeded at the provider: the money arrived and the payment never moved. " + next_step
                    )
            out.append(
                Finding(
                    5,
                    CHECK_TERMINAL,
                    "suspect",
                    summary,
                    [
                        "provider status -> local status: "
                        + ", ".join(f"{k}: {v}" for k, v in sorted(by_status.items(), key=lambda kv: -kv[1])),
                        "examples: " + sample((m[0] for m in mismatched), ctx.options.top_n),
                    ],
                    next_step=next_step,
                )
            )
        else:
            out.append(Finding(5, CHECK_TERMINAL, "ok", "every payment the provider reports as terminal is terminal locally"))

    # 2. provider success vs local terminal failure
    success = ctx.options.success
    if ctx.payments is None or not success or not won_statuses:
        needs = ["--payments"] if ctx.payments is None else []
        if not success or not won_statuses:
            needs.append(_NEEDS_SUCCESS)
        out.append(na(5, CHECK_OUTCOME, ", ".join(needs)))
    else:
        local = {p.id: p for p in ctx.payments}
        lost: list[tuple[str, Event, str]] = []
        for pid, evs in by_payment.items():
            p = local.get(pid)
            if p is None or not p.terminal or p.status.lower() in success:
                continue
            won = provider_success(evs, won_statuses)
            if won is not None:
                lost.append((pid, won, p.status))
        if lost:
            lost.sort(key=lambda m: m[1].at)
            lost_by: dict[str, int] = defaultdict(int)
            for _, ev, local_status in lost:
                lost_by[f"{ev.status} -> local {local_status}"] += 1
            out.append(
                Finding(
                    5,
                    CHECK_OUTCOME,
                    "suspect",
                    (
                        f"{len(lost)} payments succeeded at the provider but are"
                        if len(lost) != 1
                        else "1 payment succeeded at the provider but is"
                    )
                    + f" closed as a failure locally (oldest success {humanize(ctx.options.now - lost[0][1].at)} ago)",
                    [
                        "provider status -> local status: "
                        + ", ".join(f"{k}: {v}" for k, v in sorted(lost_by.items(), key=lambda kv: -kv[1])),
                        "examples: " + sample((m[0] for m in lost), ctx.options.top_n),
                    ],
                    next_step=(
                        "The money arrived and the payment was closed as failed on your side — the customer was charged for nothing. "
                        "Usually a timeout sweep or an auto-cancel ran before the success was applied, and the late success was then "
                        "refused because the payment was already terminal. Confirm each id at the provider, then fulfil or refund it. "
                        "Structurally: a provider success must be able to override a local timeout."
                    ),
                )
            )
        else:
            out.append(Finding(5, CHECK_OUTCOME, "ok", "no payment that succeeded at the provider is closed as a failure locally"))

    # 3. event id reuse
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

    # 4. out-of-order
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
