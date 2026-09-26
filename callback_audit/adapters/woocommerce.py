"""WooCommerce orders -> local payments, keyed by the order number the payment provider knows.

Takes a CSV with one row per order. Column names are matched ignoring case, so any of these works:

* HPOS storage (``wp_wc_orders``): ``id, status, date_created_gmt`` + ``payment_method, type``;
* legacy storage (``wp_posts``): ``ID, post_status, post_date_gmt`` (+ ``payment_method`` from postmeta);
* WP-CLI ``wp wc shop_order list --format=csv``: ``id, number, status, date_created_gmt, payment_method``.
  Pages glued together are fine: repeated header lines are skipped.

A ``number`` column wins over ``id``: the Stripe plugin stores the order *number* in the
payment's metadata, which differs from the id when an order-numbering plugin is active.

Do not use a WooCommerce -> Analytics export for this. By default Analytics leaves out pending,
failed and cancelled orders, which are exactly the ones this is looking for.
"""

from __future__ import annotations

from pathlib import Path

from ..model import Payment
from ..readers import InputError
from ..timeparse import TimeParseError, parse_ts
from . import AdapterResult, _n, find_column, read_rows

TERMINAL = frozenset({"processing", "completed", "refunded", "cancelled", "failed", "trash"})
SUCCESS = frozenset({"processing", "completed", "refunded"})

_NUMBER = ("number", "order_number", "order number", "order #", "order no", "order no.")
_ID = ("id", "order_id", "order id", "post_id")
_STATUS = ("status", "post_status", "order_status", "order status")
_CREATED = ("date_created_gmt", "post_date_gmt", "date_created", "created_at", "date created", "order date", "post_date", "date")
_METHOD = ("payment_method", "_payment_method", "payment method")
_TYPE = ("type", "post_type", "order_type")

_ALIASES = {"pending-payment": "pending", "canceled": "cancelled"}


def normalize_status(raw: str) -> str:
    """``wc-pending``, ``Pending payment`` and ``pending`` are the same status."""
    s = raw.strip().lower()
    if s.startswith("wc-"):
        s = s[3:]
    s = "-".join(s.replace("_", " ").split())
    return _ALIASES.get(s, s)


def read_orders(
    path: Path,
    terminal: set[str] | frozenset[str] = TERMINAL,
    all_gateways: bool = False,
    method_prefix: str = "stripe",
) -> AdapterResult[Payment]:
    """Read a WooCommerce orders export into local payments keyed by order number."""
    rows, fields = read_rows(path)
    col_number = find_column(fields, _NUMBER)
    col_key = col_number or find_column(fields, _ID)
    col_status = find_column(fields, _STATUS)
    col_created = find_column(fields, _CREATED)
    missing = [name for name, col in (("id or number", col_key), ("status", col_status), ("date_created_gmt", col_created)) if col is None]
    if missing:
        raise InputError(
            f"{path}: does not look like a WooCommerce orders export — no {', '.join(missing)} column; found {', '.join(fields)}"
        )
    col_method = find_column(fields, _METHOD)
    col_type = find_column(fields, _TYPE)

    out: list[Payment] = []
    seen: set[str] = set()
    not_orders = drafts = other_methods = duplicates = 0
    for i, row in enumerate(rows, start=2):
        if col_type and row.get(col_type, "") not in ("", "shop_order"):
            not_orders += 1  # refunds, subscriptions
            continue
        status = normalize_status(row.get(col_status, ""))
        if status == "auto-draft":
            drafts += 1
            continue
        method = row.get(col_method, "") if col_method else ""
        if col_method and not all_gateways and not method.lower().startswith(method_prefix):
            other_methods += 1
            continue
        key = row.get(col_key, "").lstrip("#").strip()
        if not key:
            raise InputError(f"{path}, row {i}: empty {col_key}")
        if key in seen:
            duplicates += 1
            continue
        seen.add(key)
        try:
            created = parse_ts(row.get(col_created, ""))
        except TimeParseError as exc:
            raise InputError(f"{path}, row {i}, column {col_created}: {exc}") from exc
        out.append(Payment(id=key, created_at=created, status=status, terminal=status in terminal, provider=method))

    if not out:
        raise InputError(
            f"{path}: no orders left to check ({other_methods} paid with other methods, {not_orders} rows that are not orders)"
        )

    head = f"woo-orders: {_n(len(out), 'order')} read, matched on the `{col_key}` column"
    if col_number is None:
        head += " (Stripe's order_id metadata holds the order number; if an order-numbering plugin is active, export the number)"
    notes = [head]
    if other_methods:
        notes.append(f"woo-orders: {_n(other_methods, 'order')} paid with other methods left out (--all-gateways keeps them)")
    if not col_method:
        notes.append("woo-orders: no payment_method column, so orders of every payment method are counted in the age check")
    if not_orders:
        notes.append(f"woo-orders: {_n(not_orders, 'non-order row')} left out (refunds, subscriptions)")
    if drafts:
        notes.append(f"woo-orders: {_n(drafts, 'auto-draft')} left out")
    if duplicates:
        notes.append(f"woo-orders: {_n(duplicates, 'repeated row')} for the same order ignored")
    return AdapterResult(out, notes)
