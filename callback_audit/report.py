"""Render findings as Markdown (for humans) or JSON (for everything else)."""

from __future__ import annotations

import json
from datetime import datetime

from . import __version__
from .model import STATIONS, Finding

_MARK = {"suspect": "SUSPECT", "ok": "ok", "info": "info", "na": "n/a"}


def to_markdown(findings: list[Finding], *, now: datetime, inputs: dict[str, str], notes: list[str] | None = None) -> str:
    lines: list[str] = []
    lines.append("# callback-audit report")
    lines.append("")
    lines.append(f"Generated at {now.isoformat()} (UTC), callback-audit {__version__}. Read-only: no database, no network, no writes.")
    lines.append("")
    shown = {k: v for k, v in inputs.items() if k not in ("terminal_statuses", "success_statuses")}
    lines.append("Inputs: " + (", ".join(f"{k}={v}" for k, v in shown.items()) or "none"))
    if inputs.get("terminal_statuses"):
        lines.append(f"Terminal statuses: {inputs['terminal_statuses']}")
    if inputs.get("success_statuses"):
        lines.append(f"Success statuses: {inputs['success_statuses']}")
    if notes:
        lines.append("")
        lines.append("Notes on the inputs:")
        lines.extend(f"- {n}" for n in notes)
    lines.append("")

    suspects = [f for f in findings if f.verdict == "suspect"]
    lines.append(
        f"**{len(suspects)} suspect** finding(s), {sum(1 for f in findings if f.verdict == 'ok')} ok, "
        f"{sum(1 for f in findings if f.verdict == 'info')} info, {sum(1 for f in findings if f.verdict == 'na')} not checked."
    )
    lines.append("")
    lines.append("| Station | Check | Verdict | Summary |")
    lines.append("|---|---|---|---|")
    for f in findings:
        lines.append(f"| {f.station} | {f.check} | {_MARK[f.verdict]} | {f.summary.replace('|', '/')} |")
    lines.append("")

    current_station = None
    for f in findings:
        if f.station != current_station:
            current_station = f.station
            lines.append(f"## Station {f.station} — {STATIONS[f.station]}")
            lines.append("")
        lines.append(f"### {_MARK[f.verdict]}: {f.check}")
        lines.append("")
        lines.append(f.summary)
        if f.details:
            lines.append("")
            lines.append("```")
            lines.extend(f.details)
            lines.append("```")
        if f.next_step and f.verdict in ("suspect", "info", "na"):
            lines.append("")
            lines.append(f"Next: {f.next_step}")
        lines.append("")

    lines.append("---")
    lines.append(
        "Verdicts: SUSPECT = worth a human's next hour; ok = nothing in this export; info = a fact to keep in mind; n/a = the input that would answer it was not given."
    )
    lines.append("Naive timestamps in inputs are interpreted as UTC.")
    return "\n".join(lines) + "\n"


def to_json(findings: list[Finding], *, now: datetime, inputs: dict[str, str], notes: list[str] | None = None) -> str:
    payload = {
        "tool": "callback-audit",
        "version": __version__,
        "generated_at": now.isoformat(),
        "inputs": inputs,
        "notes": list(notes or []),
        "stations": {str(k): v for k, v in STATIONS.items()},
        "findings": [f.as_dict() for f in findings],
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
