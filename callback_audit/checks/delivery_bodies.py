"""Station 3, seen from the sender — a 2xx whose body says "I did not apply that".

Delivery services usually treat any 2xx as success and never read the body. A receiver
that answers ``200 {"result": "ignored", "reason": "already_final"}`` shows up as green.
"""

from __future__ import annotations

import re

from ..model import Finding
from . import Context, na, sample

CHECK = "2xx responses whose body says 'not applied'"

_IGNORED_RE = re.compile(r"ignored|already[_ -]?(terminal|final|processed|applied)|not[_ -]applied|duplicate|no[_ -]?op", re.IGNORECASE)


def run(ctx: Context) -> list[Finding]:
    if ctx.deliveries is None:
        return [na(3, CHECK, "--deliveries")]
    with_body = [d for d in ctx.deliveries if d.response_body]
    if not with_body:
        return [
            Finding(
                3,
                CHECK,
                "info",
                "deliveries export has no response_body column (or it is empty) — cannot tell 'delivered' from 'applied'",
                next_step="Store the receiver's response body per attempt; it is the only place where 'we returned 200' and 'we applied it' can be told apart.",
            )
        ]

    ok_but_ignored = [
        d for d in with_body if d.response_code is not None and 200 <= d.response_code < 300 and _IGNORED_RE.search(d.response_body)
    ]
    if not ok_but_ignored:
        return [Finding(3, CHECK, "ok", f"{len(with_body)} responses with a body, none of the 2xx ones says it was ignored")]
    ids = sorted({d.payment_id for d in ok_but_ignored})
    return [
        Finding(
            3,
            CHECK,
            "suspect",
            f"{len(ok_but_ignored)} responses returned 2xx but the body says the callback was ignored ({len(ids)} payments)",
            ["examples: " + sample(ids, ctx.options.top_n), f"matched on: {_IGNORED_RE.pattern}"],
            next_step=(
                "Your delivery is green and the receiver's state is the opposite. Parse the body, or at least alert on it. "
                "Then look at why the receiver considered the payment terminal already — usually a status flipped "
                "backwards on your side (see station 5, history)."
            ),
        )
    ]
