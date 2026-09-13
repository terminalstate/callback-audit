from pathlib import Path

import pytest

from callback_audit.readers import InputError, read_deliveries, read_inbound, read_payments


def write(tmp_path: Path, name: str, text: str) -> Path:
    p = tmp_path / name
    p.write_text(text)
    return p


def test_payments_with_terminal_list(tmp_path):
    p = write(tmp_path, "p.csv", "id,created_at,status,provider\na,2026-09-01T00:00:00Z,Succeeded,x\nb,2026-09-01T00:00:00Z,processing,x\n")
    rows = read_payments(p, {"succeeded"})
    assert [r.terminal for r in rows] == [True, False]
    assert rows[0].provider == "x" and rows[0].updated_at is None


def test_payments_with_terminal_column_wins(tmp_path):
    p = write(tmp_path, "p.csv", "id,created_at,status,terminal\na,1700000000,weird,true\nb,1700000000,succeeded,0\n")
    rows = read_payments(p, None)
    assert [r.terminal for r in rows] == [True, False]


def test_payments_without_terminal_info_is_an_error(tmp_path):
    p = write(tmp_path, "p.csv", "id,created_at,status\na,1700000000,x\n")
    with pytest.raises(InputError, match="--terminal"):
        read_payments(p, None)


def test_missing_column_names_the_file_and_column(tmp_path):
    p = write(tmp_path, "p.csv", "id,status\na,x\n")
    with pytest.raises(InputError, match="created_at"):
        read_payments(p, {"x"})


def test_bad_timestamp_names_row_and_column(tmp_path):
    p = write(tmp_path, "p.csv", "id,created_at,status\na,not-a-date,x\n")
    with pytest.raises(InputError, match="row 2, column created_at"):
        read_payments(p, {"x"})


def test_deliveries_non_http_outcome(tmp_path):
    p = write(
        tmp_path,
        "d.csv",
        "payment_id,attempt,sent_at,response_code,response_body\na,1,2026-09-01T00:00:00Z,timeout,\na,2,2026-09-01T00:01:00Z,200,ok\n",
    )
    rows = read_deliveries(p)
    assert rows[0].response_code is None and rows[1].response_code == 200


def test_inbound_nginx_and_filter(tmp_path):
    log = (
        '203.0.113.9 - - [10/Sep/2026:13:55:36 +0000] "POST /webhooks/alpha HTTP/1.1" 200 12 "-" "alpha/1.0"\n'
        '10.0.0.5 - - [10/Sep/2026:13:55:37 +0000] "GET /health HTTP/1.1" 200 2 "-" "kube-probe"\n'
        "garbage line\n"
    )
    p = write(tmp_path, "access.log", log)
    rows = read_inbound(p)
    assert len(rows) == 2 and rows[0].path == "/webhooks/alpha" and rows[0].user_agent == "alpha/1.0"
    assert len(read_inbound(p, "/webhooks/")) == 1


def test_inbound_csv(tmp_path):
    p = write(tmp_path, "in.csv", "at,status_code,path\n2026-09-10T00:00:00Z,401,/webhooks/x\n2026-09-10T00:00:01Z,200,/webhooks/x\n")
    rows = read_inbound(p)
    assert [r.status_code for r in rows] == [401, 200]


def test_inbound_unparseable(tmp_path):
    p = write(tmp_path, "x.log", "nothing here\nnor here\n")
    with pytest.raises(InputError, match="combined"):
        read_inbound(p)
