import re
from datetime import datetime, timedelta, timezone

from callback_audit.checks import (
    Context,
    Options,
    counters,
    delivery_bodies,
    history,
    inbound_codes,
    log_patterns,
    retry_ladder,
    run_all,
    sequence,
    stuck_age,
    visibility,
)
from callback_audit.model import Delivery, Event, Inbound, LogCounts, Payment, Transition

NOW = datetime(2026, 9, 13, 9, 0, tzinfo=timezone.utc)


def ctx(**kw) -> Context:
    c = Context(options=Options(now=NOW))
    c.log_patterns = {"signature": re.compile("signature mismatch", re.I), "unknown_status": re.compile("unknown status", re.I)}
    for k, v in kw.items():
        setattr(c, k, v)
    return c


def pay(id, age_hours, status="processing", terminal=False, provider="p"):
    return Payment(id=id, created_at=NOW - timedelta(hours=age_hours), status=status, terminal=terminal, provider=provider)


def by_check(findings, name):
    return next(f for f in findings if f.check == name)


# --- station 7: stuck age ---------------------------------------------------------------------


def test_stuck_age_ok_and_suspect():
    ok = stuck_age.run(ctx(payments=[pay("a", 0.5), pay("b", 100, "succeeded", True)]))[0]
    assert ok.verdict == "ok"
    bad = stuck_age.run(ctx(payments=[pay("a", 30), pay("b", 0.2)]))[0]
    assert bad.verdict == "suspect" and "1 older than 24h" in bad.summary and "id a" in bad.summary


def test_stuck_age_needs_payments():
    assert stuck_age.run(ctx())[0].verdict == "na"


# --- station 7: retry ladder ------------------------------------------------------------------


def d(pid, attempt, code, body=""):
    return Delivery(payment_id=pid, attempt=attempt, sent_at=NOW, response_code=code, response_body=body)


def test_retry_cliff_detected():
    rows = [d(f"p{i}", 7, 500) for i in range(6)] + [d("ok", 1, 200), d("late", 2, 200)]
    f = retry_ladder.run(ctx(deliveries=rows))[0]
    assert f.verdict == "suspect" and "attempt 7" in f.summary


def test_retry_spread_is_ok():
    rows = [d("a", 1, 503), d("b", 2, 503), d("c", 3, 503), d("d", 5, 503), d("e", 1, 200)]
    assert retry_ladder.run(ctx(deliveries=rows))[0].verdict == "ok"


def test_retry_uses_last_attempt_per_payment():
    rows = [d("a", 1, 500), d("a", 2, 200)] * 3
    assert retry_ladder.run(ctx(deliveries=rows))[0].verdict == "ok"


# --- stations 1-2: counters and inbound codes -------------------------------------------------


def ev(pid, at, status, terminal, event_id=""):
    return Event(payment_id=pid, at=at, status=status, terminal=terminal, event_id=event_id)


def inb(at, code, path="/webhooks/x"):
    return Inbound(at=at, status_code=code, path=path)


def test_counters_flags_fewer_received():
    day1 = datetime(2026, 9, 10, 12, 0, tzinfo=timezone.utc)
    events = [ev(f"p{i}", day1, "succeeded", True) for i in range(10)]
    inbound = [inb(day1, 200) for _ in range(4)]
    f = counters.run(ctx(events=events, inbound=inbound))[0]
    assert f.verdict == "suspect" and "2026-09-10" in f.summary


def test_counters_more_received_is_fine():
    day1 = datetime(2026, 9, 10, 12, 0, tzinfo=timezone.utc)
    f = counters.run(ctx(events=[ev("p", day1, "x", True)], inbound=[inb(day1, 200)] * 3))[0]
    assert f.verdict == "ok"


def test_inbound_bad_day_and_gap():
    d1 = datetime(2026, 9, 8, 12, 0, tzinfo=timezone.utc)
    d3 = d1 + timedelta(days=2)
    rows = [inb(d1, 200)] * 7 + [inb(d1, 401)] * 3 + [inb(d3, 200)] * 10
    f = inbound_codes.run(ctx(inbound=rows))[0]
    assert f.verdict == "suspect" and "2026-09-08 at 30%" in f.summary
    assert any("2026-09-09" in line for line in f.details)  # the silent day is listed


def test_inbound_small_days_are_not_flagged():
    d1 = datetime(2026, 9, 8, 12, 0, tzinfo=timezone.utc)
    assert inbound_codes.run(ctx(inbound=[inb(d1, 500), inb(d1, 200)]))[0].verdict == "ok"


# --- stations 3-4: log patterns and delivery bodies -------------------------------------------


def test_log_patterns_share_and_unknown():
    lc = LogCounts(by_pattern_day={"signature": {"2026-09-08": 5}, "unknown_status": {"2026-09-11": 2}}, total_lines=100)
    c = ctx(log_counts=lc, inbound=[inb(NOW, 200)] * 100)
    sig, unk = log_patterns.run(c)
    assert sig.verdict == "suspect" and "5.0%" in sig.summary
    assert unk.verdict == "suspect" and "2 unknown-status" in unk.summary


def test_log_patterns_below_threshold_is_info():
    lc = LogCounts(by_pattern_day={"signature": {"2026-09-08": 1}}, total_lines=100)
    sig, unk = log_patterns.run(ctx(log_counts=lc, inbound=[inb(NOW, 200)] * 1000))
    assert sig.verdict == "info" and unk.verdict == "ok"


def test_delivery_bodies():
    rows = [
        d("a", 1, 200, '{"status":"ok"}'),
        d("b", 1, 200, '{"action":"ignored","reason":"already_final"}'),
        d("c", 1, 500, "ignored"),
    ]
    f = delivery_bodies.run(ctx(deliveries=rows))[0]
    assert f.verdict == "suspect" and "(1 payments)" in f.summary and "b" in f.details[0]


def test_delivery_bodies_without_bodies_is_info():
    assert delivery_bodies.run(ctx(deliveries=[d("a", 1, 200)]))[0].verdict == "info"


# --- station 5: sequence and history ----------------------------------------------------------


def test_sequence_terminal_mismatch_reuse_and_order():
    t0 = NOW - timedelta(days=2)
    events = [
        ev("stuck", t0, "processing", False, "e1"),
        ev("stuck", t0 + timedelta(minutes=1), "failed", True, "e2"),
        ev("fine", t0, "processing", False, "e3"),
        ev("fine", t0 + timedelta(minutes=1), "succeeded", True, "e3"),  # reused id
        ev("ooo", t0, "succeeded", True, "e4"),
        ev("ooo", t0 + timedelta(seconds=5), "processing", False, "e5"),
    ]
    payments = [pay("stuck", 48), pay("fine", 48, "succeeded", True), pay("ooo", 48, "succeeded", True)]
    fs = sequence.run(ctx(events=events, payments=payments))
    assert by_check(fs, sequence.CHECK_TERMINAL).verdict == "suspect"
    assert "stuck" in by_check(fs, sequence.CHECK_TERMINAL).details[1]
    assert by_check(fs, sequence.CHECK_REUSE).verdict == "suspect" and "fine/e3" in by_check(fs, sequence.CHECK_REUSE).details[0]
    assert by_check(fs, sequence.CHECK_ORDER).verdict == "info" and "ooo" in by_check(fs, sequence.CHECK_ORDER).details[0]


def test_sequence_without_payments_still_checks_reuse_and_order():
    fs = sequence.run(ctx(events=[ev("a", NOW, "x", True, "e1")]))
    assert by_check(fs, sequence.CHECK_TERMINAL).verdict == "na"
    assert by_check(fs, sequence.CHECK_REUSE).verdict == "ok"


def tr(pid, at, a, b):
    return Transition(payment_id=pid, at=at, from_status=a, to_status=b)


def test_history_leaving_terminal_and_rapid_chain():
    t0 = NOW - timedelta(days=1)
    hist = [
        tr("normal", t0, "", "created"),
        tr("normal", t0 + timedelta(seconds=10), "created", "processing"),
        tr("normal", t0 + timedelta(seconds=40), "processing", "succeeded"),
        tr("flip", t0, "succeeded", "in_dispute"),
        tr("flip", t0 + timedelta(seconds=7), "in_dispute", "canceled"),
        tr("flip", t0 + timedelta(seconds=14), "canceled", "succeeded"),
    ]
    c = ctx(history=hist)
    c.inputs["terminal_statuses"] = "succeeded,failed,canceled"
    fs = history.run(c)
    leave = by_check(fs, history.CHECK_LEAVE)
    rapid = by_check(fs, history.CHECK_RAPID)
    assert leave.verdict == "suspect" and "flip" in leave.details[1] and "normal" not in leave.details[1]
    assert rapid.verdict == "suspect" and "flip" in rapid.details[0] and "normal" not in rapid.details[0]


def test_history_fast_normal_lifecycle_is_ok():
    t0 = NOW - timedelta(days=1)
    hist = [
        tr("n", t0, "", "created"),
        tr("n", t0 + timedelta(seconds=5), "created", "processing"),
        tr("n", t0 + timedelta(seconds=9), "processing", "succeeded"),
    ]
    c = ctx(history=hist)
    c.inputs["terminal_statuses"] = "succeeded"
    assert all(f.verdict == "ok" for f in history.run(c))


# --- station 6: visibility --------------------------------------------------------------------


def test_visibility_disagreement():
    hist = [tr("a", NOW - timedelta(hours=1), "processing", "succeeded"), tr("b", NOW - timedelta(hours=1), "processing", "succeeded")]
    payments = [pay("a", 2, "processing"), pay("b", 2, "succeeded", True)]
    f = visibility.run(ctx(history=hist, payments=payments))[0]
    assert f.verdict == "suspect" and "a" in f.details[1] and "1 payments" in f.summary


def test_visibility_na_without_history():
    assert visibility.run(ctx(payments=[pay("a", 1)]))[0].verdict == "na"


# --- everything together ----------------------------------------------------------------------


def test_run_all_with_nothing_is_all_na():
    fs = run_all(ctx())
    assert fs and all(f.verdict == "na" for f in fs)
    assert [f.station for f in fs] == sorted(f.station for f in fs)
