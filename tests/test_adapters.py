import json
from pathlib import Path

import pytest

from callback_audit.adapters import join_notes, stripe, woocommerce
from callback_audit.readers import InputError

EXAMPLES = Path(__file__).resolve().parent.parent / "examples" / "woocommerce-stripe"


def by_order(events):
    out = {}
    for e in events:
        out.setdefault(e.payment_id, []).append(e)
    return out


# --- Stripe: Dashboard CSV ----------------------------------------------------------------------


def test_stripe_dashboard_csv_statuses_and_notes():
    res = stripe.read_payments(EXAMPLES / "stripe_payments.csv")
    ev = by_order(res.records)
    assert "" not in ev  # the payment without order metadata is not an event
    assert [e.status for e in ev["1003"]] == ["succeeded"]
    assert ev["1003"][0].terminal and ev["1003"][0].ref == "ch_ex_1003"
    assert ev["1006"][0].status == "requires_payment_method" and not ev["1006"][0].terminal
    assert ev["1007"][0].status == "refunded"  # "Refunded"
    assert ev["1008"][0].status == "failed"
    assert ev["1013"][0].status == "partially_refunded"  # "Paid" with 40.00 of 140.00 refunded
    assert ev["1014"][0].status == "requires_capture"  # "Uncaptured"
    assert sorted(e.status for e in ev["1012"]) == ["failed", "succeeded"]
    assert res.notes[0].startswith("stripe: 15 payments read (Dashboard CSV); 1 without order_id metadata")


def test_stripe_csv_paid_but_not_captured_is_an_authorisation(tmp_path):
    p = tmp_path / "s.csv"
    p.write_text("id,Created date (UTC),Status,Captured,order_id (metadata)\nch_1,2026-09-20 10:00:00,Paid,false,7\n")
    assert stripe.read_payments(p).records[0].status == "requires_capture"


def test_stripe_csv_other_header_spellings(tmp_path):
    p = tmp_path / "s.csv"
    p.write_text("ID,created,STATUS,metadata.order_id\npi_1,1758362400,succeeded,42\n")
    (e,) = stripe.read_payments(p).records
    assert (e.payment_id, e.status, e.ref) == ("42", "succeeded", "pi_1")


def test_stripe_csv_metadata_colon_naming(tmp_path):
    p = tmp_path / "s.csv"
    p.write_text("id,Created date (UTC),Status,metadata:order_id,metadata:site_url\nch_1,2026-09-20 10:00:00,Paid,7,https://shop.example\n")
    (e,) = stripe.read_payments(p, site_url="shop.example").records
    assert (e.payment_id, e.status) == ("7", "succeeded")


def test_stripe_csv_without_order_metadata_says_what_to_do(tmp_path):
    p = tmp_path / "s.csv"
    p.write_text("id,Created date (UTC),Status\nch_1,2026-09-20 10:00:00,Paid\n")
    with pytest.raises(InputError, match="metadata"):
        stripe.read_payments(p)


def test_stripe_csv_where_no_payment_has_order_metadata(tmp_path):
    p = tmp_path / "s.csv"
    p.write_text("id,Created date (UTC),Status,order_id (metadata)\nch_1,2026-09-20 10:00:00,Paid,\n")
    with pytest.raises(InputError, match="--stripe-order-key"):
        stripe.read_payments(p)


def test_stripe_custom_order_key(tmp_path):
    p = tmp_path / "s.csv"
    p.write_text("id,Created date (UTC),Status,order_number (metadata)\nch_1,2026-09-20 10:00:00,Paid,A-7\n")
    assert stripe.read_payments(p, order_key="order_number").records[0].payment_id == "A-7"


def test_stripe_site_url_filter_and_collision_note(tmp_path):
    p = tmp_path / "s.csv"
    p.write_text(
        "id,Created date (UTC),Status,order_id (metadata),site_url (metadata)\n"
        "ch_1,2026-09-20 10:00:00,Paid,7,https://shop.example\n"
        "ch_2,2026-09-20 10:05:00,Paid,7,https://other.example\n"
    )
    both = stripe.read_payments(p)
    assert len(both.records) == 2 and any("--site-url" in n for n in both.notes)
    one = stripe.read_payments(p, site_url="shop.example")
    assert [e.ref for e in one.records] == ["ch_1"] and "1 from other sites left out" in one.notes[0]
    with pytest.raises(InputError, match="site_url"):
        stripe.read_payments(p, site_url="nowhere.example")


def test_stripe_status_names():
    assert stripe.normalize_status("Paid") == "succeeded"
    assert stripe.normalize_status("Partially refunded") == "partially_refunded"
    assert stripe.normalize_status("Uncaptured") == "requires_capture"
    assert stripe.normalize_status("Cancelled") == "canceled"
    assert stripe.normalize_status("Dispute needs response") == "disputed"
    assert stripe.normalize_status("requires_action") == "requires_action"


# --- Stripe: API JSON ---------------------------------------------------------------------------


def pi(id, status, order, created=1758362400, **extra):
    return {"id": id, "object": "payment_intent", "status": status, "created": created, "metadata": {"order_id": order}, **extra}


def test_stripe_json_list_object(tmp_path):
    p = tmp_path / "s.json"
    page = {
        "object": "list",
        "has_more": False,
        "data": [
            pi("pi_1", "succeeded", "1"),
            pi("pi_2", "requires_payment_method", "2"),
            pi("pi_3", "succeeded", "3", latest_charge={"id": "ch_3", "refunded": True, "amount_refunded": 500}),
            pi("pi_4", "succeeded", "4", latest_charge={"id": "ch_4", "refunded": False, "amount_refunded": 100}),
            {
                "id": "ch_5",
                "object": "charge",
                "status": "succeeded",
                "captured": False,
                "created": 1758362400,
                "metadata": {"order_id": "5"},
            },
            {
                "id": "cs_6",
                "object": "checkout.session",
                "status": "complete",
                "payment_status": "paid",
                "created": 1758362400,
                "metadata": {"order_id": "6"},
            },
            {
                "id": "cs_7",
                "object": "checkout.session",
                "status": "expired",
                "payment_status": "unpaid",
                "created": 1758362400,
                "metadata": {"order_id": "7"},
            },
        ],
    }
    p.write_text(json.dumps(page))
    res = stripe.read_payments(p)
    got = {e.payment_id: e.status for e in res.records}
    assert got == {
        "1": "succeeded",
        "2": "requires_payment_method",
        "3": "refunded",
        "4": "partially_refunded",
        "5": "requires_capture",
        "6": "succeeded",
        "7": "canceled",
    }
    assert "(API JSON)" in res.notes[0]


def test_stripe_json_pages_one_per_line_and_bare_array(tmp_path):
    p = tmp_path / "s.jsonl"
    p.write_text(
        json.dumps({"object": "list", "data": [pi("pi_1", "succeeded", "1")]}) + "\n\n" + json.dumps([pi("pi_2", "canceled", "2")]) + "\n"
    )
    assert {e.payment_id: e.status for e in stripe.read_payments(p).records} == {"1": "succeeded", "2": "canceled"}


def test_stripe_json_broken_line_is_a_clean_error(tmp_path):
    p = tmp_path / "s.jsonl"
    p.write_text(json.dumps(pi("pi_1", "succeeded", "1")) + "\n{not json\n")
    with pytest.raises(InputError, match="line 2"):
        stripe.read_payments(p)


# --- WooCommerce --------------------------------------------------------------------------------


def test_woo_hpos_export():
    res = woocommerce.read_orders(EXAMPLES / "orders.csv")
    orders = {p.id: p for p in res.records}
    assert len(orders) == 12  # one PayPal order and one refund row left out
    assert "1009" not in orders and "1011" not in orders
    assert orders["1003"].status == "pending" and not orders["1003"].terminal
    assert orders["1004"].status == "cancelled" and orders["1004"].terminal
    assert orders["1005"].status == "on-hold" and orders["1005"].provider == "stripe_sepa"
    assert "matched on the `id` column" in res.notes[0] and "order-numbering plugin" in res.notes[0]
    assert any("1 order paid with other methods" in n for n in res.notes)
    assert any("1 non-order row" in n for n in res.notes)


def test_woo_all_gateways_keeps_other_methods():
    orders = {p.id for p in woocommerce.read_orders(EXAMPLES / "orders.csv", all_gateways=True).records}
    assert "1009" in orders and "1011" not in orders


def test_woo_legacy_export_without_payment_method(tmp_path):
    p = tmp_path / "o.csv"
    p.write_text("ID,post_status,post_date_gmt\n7,wc-pending,2026-09-20 10:00:00\n8,wc-completed,2026-09-20 11:00:00\n")
    res = woocommerce.read_orders(p)
    assert [(o.id, o.status, o.terminal) for o in res.records] == [("7", "pending", False), ("8", "completed", True)]
    assert any("no payment_method column" in n for n in res.notes)


def test_woo_wp_cli_pages_prefer_number_and_skip_repeated_headers(tmp_path):
    p = tmp_path / "o.csv"
    p.write_text(
        "id,number,status,date_created_gmt,payment_method\n"
        "7,A-7,pending,2026-09-20T10:00:00,stripe\n"
        "id,number,status,date_created_gmt,payment_method\n"
        "8,A-8,processing,2026-09-20T11:00:00,stripe\n"
        "8,A-8,processing,2026-09-20T11:00:00,stripe\n"
    )
    res = woocommerce.read_orders(p)
    assert [o.id for o in res.records] == ["A-7", "A-8"]
    assert "matched on the `number` column" in res.notes[0]
    assert any("1 repeated row" in n for n in res.notes)


def test_woo_status_names():
    assert woocommerce.normalize_status("Pending payment") == "pending"
    assert woocommerce.normalize_status("wc-on-hold") == "on-hold"
    assert woocommerce.normalize_status("Canceled") == "cancelled"
    assert woocommerce.normalize_status("wc-checkout-draft") == "checkout-draft"


def test_woo_missing_columns(tmp_path):
    p = tmp_path / "o.csv"
    p.write_text("order,total\n7,10.00\n")
    with pytest.raises(InputError, match="status"):
        woocommerce.read_orders(p)


# --- join ---------------------------------------------------------------------------------------


def test_join_notes_count_orders_only_the_provider_knows():
    orders = woocommerce.read_orders(EXAMPLES / "orders.csv").records
    events = stripe.read_payments(EXAMPLES / "stripe_payments.csv").records
    notes = join_notes(orders, events, set(stripe.SUCCESS))
    assert notes[0] == "joined: 12 orders in both exports"
    assert notes[1].startswith("1 order only in the provider export (1 with a successful payment)")
