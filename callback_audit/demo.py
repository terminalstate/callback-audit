"""Generate the synthetic demo dataset used by ``callback-audit --demo``.

Deterministic (seeded). Two fictional providers, "alpha" and "beta", fourteen days of traffic,
and a handful of planted problems so that `callback-audit --demo` shows every kind of finding:

* 23 beta payments stuck in `processing` for 5–9 days: the provider sent a terminal `failed`
  event, local rules never finalised on non-success (stations 5 and 7);
* one bad day for alpha (Sep 8): ~30% of inbound posts rejected with 401 — signature failures,
  and 9 payments from that day never reached a terminal state (station 3);
* one bad day for beta (Sep 10): the provider sent 20 events, only 5 reached the edge (stations 1–2);
* a few 504s from the balancer on Sep 4 (station 2);
* 37 "unknown status mapping" lines on Sep 11 (station 4);
* 3 event ids reused across statuses, 2 out-of-order deliveries (station 5);
* on the sending side: 18 merchant deliveries stuck at exactly attempt 7 (retry ceiling, station 7)
  and 4 that got a 200 whose body says "ignored / already_final" (station 3);
* status history: 2 transitions leaving a terminal status, 1 rapid manual chain (station 5),
  and 3 payments whose history and export disagree (station 6).

Run:  python -m callback_audit.demo <directory>   (writes the six files there)
"""

from __future__ import annotations

import csv
import random
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEMO_NOW = datetime(2026, 9, 13, 9, 0, 0, tzinfo=timezone.utc)

TERMINAL = ("succeeded", "failed", "canceled", "expired")


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def clf(dt: datetime) -> str:
    return dt.strftime("%d/%b/%Y:%H:%M:%S +0000")


def generate(out: Path, now: datetime = DEMO_NOW, seed: int = 42) -> dict[str, Path]:
    """Write payments.csv, events.csv, history.csv, deliveries.csv, inbound.log and app.log into ``out``."""
    rng = random.Random(seed)
    NOW = now
    START = NOW - timedelta(days=14)
    out.mkdir(parents=True, exist_ok=True)
    payments: list[dict] = []
    events: list[dict] = []
    inbound: list[tuple[datetime, str, str, int, str]] = []  # (at, remote, path, code, ua)
    app_log: list[tuple[datetime, str]] = []
    history: list[dict] = []
    deliveries: list[dict] = []

    ev_counter = 0

    def new_event_id() -> str:
        nonlocal ev_counter
        ev_counter += 1
        return f"evt_{ev_counter:05d}"

    def post(at: datetime, provider: str, code: int) -> None:
        remote = "203.0.113.10" if provider == "alpha" else "198.51.100.7"
        ua = f"{provider}-webhooks/2.1"
        inbound.append((at, remote, f"/webhooks/{provider}", code, ua))

    def add_payment(
        pid: str,
        created: datetime,
        provider: str,
        final: str,
        *,
        stuck_local: str | None = None,
        reject_terminal: bool = False,
        drop_terminal: bool = False,
        reuse_id: bool = False,
        out_of_order: bool = False,
        no_finalize: bool = False,
    ) -> None:
        t_proc = created + timedelta(seconds=rng.randint(5, 90))
        t_final = t_proc + timedelta(seconds=rng.randint(30, 1200))
        # provider events
        e1 = new_event_id()
        e2 = new_event_id()
        e3 = e2 if reuse_id else new_event_id()
        events.append({"payment_id": pid, "at": iso(created), "status": "created", "event_id": e1})
        events.append({"payment_id": pid, "at": iso(t_proc), "status": "processing", "event_id": e2})
        events.append({"payment_id": pid, "at": iso(t_final), "status": final, "event_id": e3})
        if out_of_order:
            events.append(
                {"payment_id": pid, "at": iso(t_final + timedelta(seconds=3)), "status": "processing", "event_id": new_event_id()}
            )
        # inbound posts, one per event
        post(created + timedelta(milliseconds=rng.randint(50, 900)), provider, 200)
        post(t_proc + timedelta(milliseconds=rng.randint(50, 900)), provider, 200)
        if reject_terminal:
            post(t_final + timedelta(milliseconds=rng.randint(50, 900)), provider, 401)
            app_log.append(
                (t_final + timedelta(seconds=1), f"WARNING webhooks.{provider}: signature mismatch for payment {pid}; responding 401")
            )
        elif drop_terminal:
            pass  # never reached the edge
        else:
            post(t_final + timedelta(milliseconds=rng.randint(50, 900)), provider, 200)
        if out_of_order:
            post(t_final + timedelta(seconds=3, milliseconds=400), provider, 200)
            app_log.append(
                (t_final + timedelta(seconds=3), f"INFO webhooks.{provider}: ignoring processing after terminal for payment {pid}")
            )
        # local status + history
        history.append({"payment_id": pid, "at": iso(created), "from_status": "", "to_status": "created"})
        history.append({"payment_id": pid, "at": iso(t_proc + timedelta(seconds=1)), "from_status": "created", "to_status": "processing"})
        local_status = final
        updated = t_final + timedelta(seconds=1)
        if stuck_local is not None:
            local_status = stuck_local
            updated = t_proc + timedelta(seconds=1)
            if no_finalize:
                app_log.append(
                    (
                        t_final + timedelta(seconds=1),
                        f"INFO webhooks.{provider}: payment {pid} status={final} is not a success, leaving as is",
                    )
                )
        else:
            history.append({"payment_id": pid, "at": iso(updated), "from_status": "processing", "to_status": final})
        payments.append({"id": pid, "created_at": iso(created), "updated_at": iso(updated), "status": local_status, "provider": provider})

    n = 0

    def pid() -> str:
        nonlocal n
        n += 1
        return f"pay_{n:04d}"

    # healthy traffic, 14 days
    for _ in range(270):
        created = START + timedelta(seconds=rng.randint(0, int((NOW - START).total_seconds()) - 3600))
        provider = "alpha" if rng.random() < 0.6 else "beta"
        final = rng.choices(TERMINAL, weights=(85, 8, 5, 2))[0]
        day = created.date()
        # Sep 4: a few balancer 504s for beta (the handler was slow, the provider retried)
        if provider == "beta" and day == datetime(2026, 9, 4).date() and rng.random() < 0.25:
            post(created + timedelta(seconds=rng.randint(100, 900)), provider, 504)
            app_log.append(
                (
                    created + timedelta(seconds=rng.randint(100, 900)),
                    "WARNING webhooks.beta: handler took 34.2s for a callback (ingress timeout is 30s)",
                )
            )
        # Sep 10: beta events do not reach the edge (IP allowlist after their egress change)
        drop = provider == "beta" and day == datetime(2026, 9, 10).date() and rng.random() < 0.75
        if drop:
            add_payment(pid(), created, provider, final, stuck_local="processing", drop_terminal=True)
        else:
            add_payment(pid(), created, provider, final)

    # the stuck cohort: beta, 5-9 days old, provider said "failed", local rules never finalised on non-success
    for _ in range(23):
        created = NOW - timedelta(days=rng.uniform(5, 9))
        add_payment(pid(), created, "beta", "failed", stuck_local="processing", no_finalize=True)

    # alpha bad day: Sep 8, signature failures on the terminal event -> stuck in processing
    for _ in range(9):
        created = datetime(2026, 9, 8, rng.randint(8, 18), rng.randint(0, 59), 0, tzinfo=timezone.utc)
        add_payment(pid(), created, "alpha", "succeeded", stuck_local="processing", reject_terminal=True)
    # more 401s that day on alpha's non-terminal posts too (the scheme was wrong for a whole deploy)
    for _ in range(14):
        at = datetime(2026, 9, 8, rng.randint(8, 19), rng.randint(0, 59), rng.randint(0, 59), tzinfo=timezone.utc)
        post(at, "alpha", 401)
        app_log.append((at, "WARNING webhooks.alpha: signature mismatch (header webhook-signature missing or malformed); responding 401"))

    # event id reuse and out-of-order, beta
    for _ in range(3):
        created = NOW - timedelta(days=rng.uniform(1, 4))
        add_payment(pid(), created, "beta", "succeeded", reuse_id=True)
    for _ in range(2):
        created = NOW - timedelta(days=rng.uniform(1, 4))
        add_payment(pid(), created, "alpha", "succeeded", out_of_order=True)

    # Sep 11: unknown status mapping — provider sends "cancelled" with empty sub-fields
    for _ in range(37):
        at = datetime(2026, 9, 11, rng.randint(0, 23), rng.randint(0, 59), rng.randint(0, 59), tzinfo=timezone.utc)
        app_log.append((at, "ERROR webhooks.beta: unknown status mapping status='cancelled' action='' event='' — responding 200"))
        post(at, "beta", 200)

    # station 6: history says succeeded, export says processing (recent, so they are not 'stuck' yet)
    for _ in range(3):
        created = NOW - timedelta(hours=rng.uniform(1.5, 3))
        p = pid()
        add_payment(p, created, "alpha", "succeeded")
        payments[-1]["status"] = "processing"

    # station 5: leaving terminal + rapid manual chain
    victims = [p for p in payments if p["status"] == "canceled"][:2]
    for p in victims:
        t = NOW - timedelta(days=1, hours=2)
        history.append({"payment_id": p["id"], "at": iso(t), "from_status": "canceled", "to_status": "processing"})
        history.append({"payment_id": p["id"], "at": iso(t + timedelta(minutes=3)), "from_status": "processing", "to_status": "succeeded"})
        p["status"] = "succeeded"
    chain = [p for p in payments if p["status"] == "succeeded"][5]
    t = NOW - timedelta(days=2, hours=5)
    for i, (a, b) in enumerate((("succeeded", "in_dispute"), ("in_dispute", "canceled"), ("canceled", "succeeded"))):
        history.append({"payment_id": chain["id"], "at": iso(t + timedelta(seconds=7 * i)), "from_status": a, "to_status": b})

    # sender side: deliveries to merchants for ~200 payments
    delivered = rng.sample(payments, 200)
    for p in delivered:
        base = datetime.strptime(p["updated_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        if rng.random() < 0.15:
            deliveries.append({"payment_id": p["id"], "attempt": 1, "sent_at": iso(base), "response_code": 502, "response_body": ""})
            deliveries.append(
                {
                    "payment_id": p["id"],
                    "attempt": 2,
                    "sent_at": iso(base + timedelta(seconds=30)),
                    "response_code": 200,
                    "response_body": '{"status":"ok"}',
                }
            )
        else:
            deliveries.append(
                {"payment_id": p["id"], "attempt": 1, "sent_at": iso(base), "response_code": 200, "response_body": '{"status":"ok"}'}
            )
    ceiling = rng.sample([p for p in payments if p not in delivered], 18)
    for p in ceiling:
        base = datetime.strptime(p["updated_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        for attempt, delay_min in enumerate((0, 1, 3, 10, 30, 60, 120), start=1):
            code = rng.choice((500, 500, 503, ""))
            deliveries.append(
                {
                    "payment_id": p["id"],
                    "attempt": attempt,
                    "sent_at": iso(base + timedelta(minutes=delay_min)),
                    "response_code": code,
                    "response_body": "" if code == "" else '{"error":"internal"}',
                }
            )
    # a few deliveries still inside the ladder (recent, legitimately mid-retry)
    mid_retry = rng.sample([p for p in payments if p not in delivered and p not in ceiling], 5)
    for k, p in enumerate(mid_retry):
        base = NOW - timedelta(minutes=rng.randint(5, 40))
        for attempt in range(1, 1 + (k % 3) + 1):
            deliveries.append(
                {
                    "payment_id": p["id"],
                    "attempt": attempt,
                    "sent_at": iso(base + timedelta(minutes=attempt - 1)),
                    "response_code": 503,
                    "response_body": '{"error":"unavailable"}',
                }
            )
    ignored = rng.sample([p for p in payments if p not in delivered and p not in ceiling and p not in mid_retry], 4)
    for p in ignored:
        base = datetime.strptime(p["updated_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        deliveries.append(
            {
                "payment_id": p["id"],
                "attempt": 1,
                "sent_at": iso(base),
                "response_code": 200,
                "response_body": '{"status":"ok","action":"ignored","reason":"already_final"}',
            }
        )

    # noise in the access log and the app log
    for _ in range(400):
        at = START + timedelta(seconds=rng.randint(0, int((NOW - START).total_seconds())))
        inbound.append((at, "10.0.0.5", "/health", 200, "kube-probe/1.29"))
    for _ in range(600):
        at = START + timedelta(seconds=rng.randint(0, int((NOW - START).total_seconds())))
        app_log.append(
            (
                at,
                rng.choice(
                    (
                        "INFO payments.router: dispatched to provider",
                        "INFO webhooks: applied status transition",
                        "INFO scheduler: timeout task scheduled",
                        "DEBUG http.client: 200 in 0.12s",
                    )
                ),
            )
        )

    # write everything, sorted by time
    payments.sort(key=lambda p: p["created_at"])
    events.sort(key=lambda e: e["at"])
    history.sort(key=lambda h: h["at"])
    deliveries.sort(key=lambda d: (d["sent_at"], d["attempt"]))
    inbound.sort(key=lambda r: r[0])
    app_log.sort(key=lambda r: r[0])

    with (out / "payments.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["id", "created_at", "updated_at", "status", "provider"])
        w.writeheader()
        w.writerows(payments)
    with (out / "events.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["payment_id", "at", "status", "event_id"])
        w.writeheader()
        w.writerows(events)
    with (out / "history.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["payment_id", "at", "from_status", "to_status"])
        w.writeheader()
        w.writerows(history)
    with (out / "deliveries.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["payment_id", "attempt", "sent_at", "response_code", "response_body"])
        w.writeheader()
        w.writerows(deliveries)
    with (out / "inbound.log").open("w") as fh:
        for at, remote, path, code, ua in inbound:
            fh.write(f'{remote} - - [{clf(at)}] "POST {path} HTTP/1.1" {code} 17 "-" "{ua}"\n')
    with (out / "app.log").open("w") as fh:
        for at, line in app_log:
            fh.write(f"{iso(at)} {line}\n")

    return {name: out / name for name in ("payments.csv", "events.csv", "history.csv", "deliveries.csv", "inbound.log", "app.log")}


def main(argv: list[str] | None = None) -> int:
    import sys

    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print("usage: python -m callback_audit.demo <directory>", file=sys.stderr)
        return 2
    paths = generate(Path(args[0]))
    for name, p in paths.items():
        print(f"{name}: {p.stat().st_size} bytes")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
