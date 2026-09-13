"""Stations 3–4 — what your application log says about rejected and misparsed callbacks.

Two named patterns are counted (defaults in cli.py, overridable):

* ``signature`` — verification failures (station 3). The share against inbound requests tells
  systematic (serialisation, clock, wrong header) from occasional.
* ``unknown_status`` — unknown status / mapping / validation failures (station 4). Any at all is
  worth a look: each one is usually a payment answered with 200 and then forgotten.
"""

from __future__ import annotations

from ..model import Finding
from . import Context, na

SIG_CHECK = "signature verification failures"
UNK_CHECK = "unknown status / validation failures"


def _fmt_days(day_counts: dict[str, int], limit: int = 14) -> str:
    items = sorted(day_counts.items())
    if len(items) > limit:
        items = items[-limit:]
    return ", ".join(f"{d}: {n}" for d, n in items)


def run(ctx: Context) -> list[Finding]:
    if ctx.log_counts is None:
        return [na(3, SIG_CHECK, "--app-log"), na(4, UNK_CHECK, "--app-log")]

    out: list[Finding] = []
    lc = ctx.log_counts

    sig_total = lc.total("signature")
    sig_days = lc.by_pattern_day.get("signature", {})
    if sig_total == 0:
        out.append(
            Finding(
                3,
                SIG_CHECK,
                "ok",
                f"no lines matched the signature-failure pattern in {lc.total_lines} log lines",
                [f"pattern: {ctx.log_patterns['signature'].pattern}"],
            )
        )
    else:
        details = [f"matches by day: {_fmt_days(sig_days)}", f"pattern: {ctx.log_patterns['signature'].pattern}"]
        if ctx.inbound:
            share = sig_total / len(ctx.inbound)
            details.insert(0, f"{sig_total} failures against {len(ctx.inbound)} inbound requests = {share:.1%}")
            verdict = "suspect" if share >= ctx.options.signature_share else "info"
            summary = f"{sig_total} signature failures, {share:.1%} of inbound requests"
        else:
            verdict = "suspect"
            summary = f"{sig_total} signature failures (no inbound log given, so no share)"
        peak_day = max(sig_days.items(), key=lambda kv: kv[1])
        details.append(f"peak day: {peak_day[0]} with {peak_day[1]}")
        out.append(
            Finding(
                3,
                SIG_CHECK,
                verdict,
                summary,
                details,
                next_step=(
                    "Percent-level share is systematic, not noise: signature computed over a re-serialised body instead of raw bytes, "
                    "timestamp window vs clock skew, or a rotated secret. 100% for one provider means the scheme itself "
                    "(wrong header name, hex vs base64, body-only vs method+url+body). Then check what the endpoint returns on "
                    "failure — if it is 200, these callbacks are lost silently."
                ),
            )
        )

    unk_total = lc.total("unknown_status")
    unk_days = lc.by_pattern_day.get("unknown_status", {})
    if unk_total == 0:
        out.append(
            Finding(
                4,
                UNK_CHECK,
                "ok",
                "no lines matched the unknown-status / validation pattern",
                [f"pattern: {ctx.log_patterns['unknown_status'].pattern}"],
            )
        )
    else:
        peak_day = max(unk_days.items(), key=lambda kv: kv[1])
        out.append(
            Finding(
                4,
                UNK_CHECK,
                "suspect",
                f"{unk_total} unknown-status / validation failures (peak {peak_day[0]}: {peak_day[1]})",
                [f"matches by day: {_fmt_days(unk_days)}", f"pattern: {ctx.log_patterns['unknown_status'].pattern}"],
                next_step=(
                    "Each of these is a callback that was accepted and not applied. Find the status value or field that is "
                    "not in your mapping (a known status with empty sub-fields is the classic), and check whether the raw body "
                    "is logged before parsing — if not, you cannot even see what arrived."
                ),
            )
        )
    return out
