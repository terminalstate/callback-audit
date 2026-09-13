"""Command line entry point."""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from . import __version__
from .checks import Context, Options, run_all
from .readers import InputError, count_log_patterns, read_deliveries, read_events, read_history, read_inbound, read_payments
from .report import to_json, to_markdown
from .timeparse import TimeParseError, parse_ts

DEFAULT_PATTERNS = {
    "signature": r"signature (mismatch|invalid|verification failed|failed)|invalid signature|bad signature|hmac (mismatch|invalid)",
    "unknown_status": r"unknown status|no status mapping|unknown event|validation ?error|unmapped status|unexpected status",
}


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="callback-audit",
        description=(
            "Read-only audit of webhook/callback delivery: finds where payments stop short of a terminal state. "
            "Feed it exports; it prints a report by station. It never connects to a database or the network."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "inputs (all optional, each unlocks checks):\n"
            "  --payments   CSV: id,created_at,status[,updated_at,provider,terminal]\n"
            "  --deliveries CSV: payment_id,attempt[,sent_at,response_code,response_body]   (you are the sender)\n"
            "  --events     CSV: payment_id,at,status[,event_id,terminal]                   (provider's view)\n"
            "  --inbound    nginx combined access log, or CSV: at,status_code[,path,remote,user_agent]\n"
            "  --app-log    application log, plain text, one line per record\n"
            "  --history    CSV: payment_id,at,from_status,to_status\n"
            "\n"
            "try it:  callback-audit --demo\n"
        ),
    )
    p.add_argument("--version", action="version", version=f"callback-audit {__version__}")
    p.add_argument("--demo", action="store_true", help="generate a synthetic dataset and run on it")
    p.add_argument("--demo-dir", type=Path, help="with --demo: write the generated dataset here instead of a temp dir")
    p.add_argument("--payments", type=Path)
    p.add_argument("--terminal", help="comma-separated terminal statuses for --payments/--history (case-insensitive)")
    p.add_argument("--deliveries", type=Path)
    p.add_argument("--events", type=Path)
    p.add_argument("--provider-terminal", help="terminal statuses as the provider names them (defaults to --terminal)")
    p.add_argument("--inbound", type=Path)
    p.add_argument("--path-filter", help="keep only inbound requests whose path contains this substring, e.g. /webhooks/")
    p.add_argument("--app-log", type=Path)
    p.add_argument("--signature-pattern", default=DEFAULT_PATTERNS["signature"], help="regex for signature failures in --app-log")
    p.add_argument(
        "--unknown-status-pattern",
        default=DEFAULT_PATTERNS["unknown_status"],
        help="regex for unknown status / validation failures in --app-log",
    )
    p.add_argument("--history", type=Path)
    p.add_argument("--now", help="reference time (ISO 8601 or epoch); default: current time")
    p.add_argument("--stuck-hours", type=float, default=24.0, help="a non-terminal payment older than this is stuck (default 24)")
    p.add_argument("--top", type=int, default=10, help="example ids to print per finding (default 10)")
    p.add_argument("--json", action="store_true", help="print JSON instead of Markdown")
    return p


def _statuses(arg: str | None) -> set[str] | None:
    if not arg:
        return None
    return {s.strip().lower() for s in arg.split(",") if s.strip()}


def _demo_args(args: argparse.Namespace) -> argparse.Namespace:
    from .demo import DEMO_NOW, generate

    out = args.demo_dir or Path(tempfile.mkdtemp(prefix="callback-audit-demo-"))
    paths = generate(out)
    args.payments = paths["payments.csv"]
    args.deliveries = paths["deliveries.csv"]
    args.events = paths["events.csv"]
    args.inbound = paths["inbound.log"]
    args.app_log = paths["app.log"]
    args.history = paths["history.csv"]
    args.terminal = args.terminal or "succeeded,failed,canceled,expired"
    args.path_filter = args.path_filter or "/webhooks/"
    args.now = args.now or DEMO_NOW.isoformat()
    return args


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.demo:
        args = _demo_args(args)

    if not any((args.payments, args.deliveries, args.events, args.inbound, args.app_log, args.history)):
        parser.print_help()
        return 2

    try:
        now = parse_ts(args.now) if args.now else datetime.now(tz=timezone.utc)
    except TimeParseError as exc:
        parser.error(str(exc))

    terminal = _statuses(args.terminal)
    provider_terminal = _statuses(args.provider_terminal) or terminal
    patterns = {
        "signature": re.compile(args.signature_pattern, re.IGNORECASE),
        "unknown_status": re.compile(args.unknown_status_pattern, re.IGNORECASE),
    }

    ctx = Context(options=Options(now=now, stuck_hours=args.stuck_hours, top_n=args.top), log_patterns=patterns)
    inputs: dict[str, str] = {}
    try:
        if args.payments:
            ctx.payments = read_payments(args.payments, terminal)
            inputs["payments"] = str(args.payments)
        if args.deliveries:
            ctx.deliveries = read_deliveries(args.deliveries)
            inputs["deliveries"] = str(args.deliveries)
        if args.events:
            ctx.events = read_events(args.events, provider_terminal)
            inputs["events"] = str(args.events)
        if args.inbound:
            ctx.inbound = read_inbound(args.inbound, args.path_filter)
            inputs["inbound"] = str(args.inbound) + (f" (filter {args.path_filter})" if args.path_filter else "")
        if args.app_log:
            ctx.log_counts = count_log_patterns(args.app_log, patterns)
            inputs["app_log"] = str(args.app_log)
        if args.history:
            ctx.history = read_history(args.history)
            inputs["history"] = str(args.history)
    except InputError as exc:
        print(f"callback-audit: {exc}", file=sys.stderr)
        return 1
    if args.terminal:
        inputs["terminal_statuses"] = args.terminal
    ctx.inputs = inputs

    findings = run_all(ctx)
    out = to_json(findings, now=now, inputs=inputs) if args.json else to_markdown(findings, now=now, inputs=inputs)
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
