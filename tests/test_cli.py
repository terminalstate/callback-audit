import json
from pathlib import Path

import pytest

from callback_audit.cli import main

EXAMPLES = Path(__file__).resolve().parent.parent / "examples" / "woocommerce-stripe"
EXAMPLE_ARGS = [
    "--stripe",
    str(EXAMPLES / "stripe_payments.csv"),
    "--woo-orders",
    str(EXAMPLES / "orders.csv"),
    "--app-log",
    str(EXAMPLES / "stripe-plugin.log"),
    "--now",
    "2026-09-26T12:00:00Z",
]


def test_demo_markdown(capsys):
    assert main(["--demo"]) == 0
    out = capsys.readouterr().out
    assert out.startswith("# callback-audit report")
    assert "SUSPECT" in out and "retry ceiling" in out and "Station 7" in out


def test_demo_json(capsys):
    assert main(["--demo", "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["tool"] == "callback-audit"
    stations = {f["station"] for f in payload["findings"]}
    assert stations == {1, 2, 3, 4, 5, 6, 7}
    assert any(f["verdict"] == "suspect" for f in payload["findings"])


def test_no_inputs_prints_help(capsys):
    assert main([]) == 2
    assert "usage:" in capsys.readouterr().out


def test_bad_input_is_a_clean_error(tmp_path, capsys):
    p = tmp_path / "p.csv"
    p.write_text("id,status\na,x\n")
    assert main(["--payments", str(p), "--terminal", "x"]) == 1
    err = capsys.readouterr().err
    assert "created_at" in err and "Traceback" not in err


def test_partial_inputs_mark_the_rest_na(tmp_path, capsys):
    p = tmp_path / "p.csv"
    p.write_text("id,created_at,status\na,2026-09-01T00:00:00Z,succeeded\n")
    assert main(["--payments", str(p), "--terminal", "succeeded", "--now", "2026-09-02T00:00:00Z"]) == 0
    out = capsys.readouterr().out
    assert "none in a non-terminal state" in out and "not checked: needs --deliveries" in out


def test_demo_generator_is_deterministic(tmp_path):
    from callback_audit.demo import generate

    a = generate(tmp_path / "a")
    b = generate(tmp_path / "b")
    assert set(a) == {"payments.csv", "events.csv", "history.csv", "deliveries.csv", "inbound.log", "app.log"}
    for name in a:
        assert a[name].read_bytes() == b[name].read_bytes()


def test_demo_dir_keeps_files(tmp_path, capsys):
    assert main(["--demo", "--demo-dir", str(tmp_path / "d")]) == 0
    assert (tmp_path / "d" / "payments.csv").exists()


def test_woocommerce_stripe_example(capsys):
    assert main(EXAMPLE_ARGS) == 0
    out = capsys.readouterr().out
    assert "1 payment succeeded at the provider but is closed as a failure locally" in out
    assert "2 payments are terminal at the provider but non-terminal locally" in out
    assert "2 of them succeeded at the provider" in out
    assert "examples: 1004" in out and "examples: 1003, 1005" in out
    assert "4 signature failures" in out
    assert "Notes on the inputs:" in out and "joined: 12 orders in both exports" in out
    assert "Success statuses: completed,processing,refunded (provider: succeeded)" in out


def test_woocommerce_stripe_example_json(capsys):
    assert main([*EXAMPLE_ARGS, "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert any(n.startswith("stripe: 15 payments read") for n in payload["notes"])
    outcome = next(f for f in payload["findings"] if f["check"] == "provider success, local terminal failure")
    assert outcome["verdict"] == "suspect"


def test_platform_exports_replace_the_generic_inputs(capsys):
    with pytest.raises(SystemExit):
        main(["--woo-orders", str(EXAMPLES / "orders.csv"), "--payments", str(EXAMPLES / "orders.csv")])
    assert "replaces --payments" in capsys.readouterr().err


def test_platform_export_errors_are_clean(tmp_path, capsys):
    p = tmp_path / "s.csv"
    p.write_text("id,Created date (UTC),Status\nch_1,2026-09-20 10:00:00,Paid\n")
    assert main(["--stripe", str(p), "--woo-orders", str(EXAMPLES / "orders.csv")]) == 1
    err = capsys.readouterr().err
    assert "metadata" in err and "Traceback" not in err
