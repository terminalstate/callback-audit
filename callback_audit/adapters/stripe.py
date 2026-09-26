"""Stripe payments -> provider events, keyed by the order each payment belongs to.

Two inputs are understood:

* the Dashboard export of payments (CSV) **with the metadata columns included**. The
  WooCommerce Stripe plugin writes ``order_id`` (the order number) and ``site_url`` on every
  payment; ``metadata:order_id``, ``order_id (metadata)``, ``metadata.order_id`` and plain
  ``order_id`` are all accepted as column names;
* JSON from the Stripe API: a list object (``{"object": "list", "data": [...]}``), a bare
  array, or one object or list per line (pages saved one after another). PaymentIntents,
  Charges and Checkout Sessions are understood.

Each Stripe object becomes one event: ``payment_id`` is the order it belongs to (from the
metadata), ``ref`` is the Stripe id, ``at`` is when it was created, and ``status`` is folded into
the API's vocabulary (``succeeded``, ``requires_capture``, ``refunded``, ``canceled`` ...).
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from ..checks import sample
from ..model import Event, Finding
from ..readers import InputError
from ..timeparse import TimeParseError, parse_ts
from . import AdapterResult, _n, find_column, read_rows

TERMINAL = frozenset({"succeeded", "canceled", "failed", "refunded", "partially_refunded", "disputed"})
SUCCESS = frozenset({"succeeded"})

# The plugin's Adaptive Pricing flow creates the payment through a Checkout Session with only
# checkout_type/site_url/payment_type in its metadata; order_id is written on it only after the
# plugin has matched the payment to its order. A successful one without order_id was never matched.
ADAPTIVE_PRICING = "adaptive_pricing_checkout"
CHECK_UNLINKED = "provider success without an order reference"

_ALIASES = {
    "paid": "succeeded",
    "successful": "succeeded",
    "success": "succeeded",
    "uncaptured": "requires_capture",
    "authorized": "requires_capture",
    "refund_pending": "refunded",
    "partial_refund": "partially_refunded",
    "cancelled": "canceled",
    "expired": "canceled",
    "blocked": "failed",
    "declined": "failed",
    "pending": "processing",
    "incomplete": "requires_payment_method",
}

_ID = ("id", "paymentintent id", "payment intent id", "charge id")
_CREATED = ("created date (utc)", "created (utc)", "created", "created date", "created_at", "created at")
_STATUS = ("status",)
_AMOUNT = ("amount",)
_REFUNDED = ("amount refunded", "amount_refunded")
_CAPTURED = ("captured",)
_FALSE = {"false", "no", "0", "f", "n"}


def normalize_status(raw: str) -> str:
    """Fold Dashboard wording ("Paid", "Partially refunded", "Uncaptured") into the API's status names."""
    key = "_".join(raw.strip().lower().replace("-", " ").split())
    if "dispute" in key:
        return "disputed"
    return _ALIASES.get(key, key)


def _meta_candidates(key: str) -> tuple[str, ...]:
    return (
        f"metadata:{key}",
        f"metadata: {key}",
        f"{key} (metadata)",
        f"metadata.{key}",
        f"metadata[{key}]",
        f"metadata_{key}",
        key,
    )


@dataclass(frozen=True)
class _Row:
    ref: str
    order: str
    site: str
    at: datetime
    status: str
    checkout_type: str = ""


def _amount(value: str) -> float | None:
    v = value.replace(",", "").strip()
    try:
        return float(v) if v else None
    except ValueError:
        return None


def _read_csv(path: Path, order_key: str) -> list[_Row]:
    rows, fields = read_rows(path)
    col_id = find_column(fields, _ID)
    col_created = find_column(fields, _CREATED) or next((f for f in fields if f.lower().startswith("created")), None)
    col_status = find_column(fields, _STATUS)
    missing = [name for name, col in (("id", col_id), ("created date", col_created), ("status", col_status)) if col is None]
    if missing:
        raise InputError(f"{path}: does not look like a Stripe payments export — no {', '.join(missing)} column; found {', '.join(fields)}")
    col_order = find_column(fields, _meta_candidates(order_key))
    col_ctype = find_column(fields, _meta_candidates("checkout_type"))
    if col_order is None and col_ctype is None:
        raise InputError(
            f"{path}: no metadata:{order_key} column, so payments cannot be matched to orders. Export again with the "
            f"metadata columns included (the WooCommerce Stripe plugin writes {order_key} on every payment), or pass "
            f"--stripe-order-key if your integration uses another key; found {', '.join(fields)}"
        )
    col_site = find_column(fields, _meta_candidates("site_url"))
    col_amount = find_column(fields, _AMOUNT)
    col_refunded = find_column(fields, _REFUNDED)
    col_captured = find_column(fields, _CAPTURED)

    out: list[_Row] = []
    for i, row in enumerate(rows, start=2):
        status = normalize_status(row.get(col_status, ""))
        if status == "succeeded":
            if col_captured and row.get(col_captured, "").lower() in _FALSE:
                status = "requires_capture"
            elif col_amount and col_refunded:
                amount, refunded = _amount(row.get(col_amount, "")), _amount(row.get(col_refunded, ""))
                if amount and refunded and refunded > 0:
                    status = "refunded" if refunded >= amount else "partially_refunded"
        try:
            at = parse_ts(row.get(col_created, ""))
        except TimeParseError as exc:
            raise InputError(f"{path}, row {i}, column {col_created}: {exc}") from exc
        out.append(
            _Row(
                ref=row.get(col_id, ""),
                order=row.get(col_order, "") if col_order else "",
                site=row.get(col_site, "") if col_site else "",
                at=at,
                status=status,
                checkout_type=row.get(col_ctype, "") if col_ctype else "",
            )
        )
    return out


def _json_objects(path: Path) -> list[dict]:
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError as exc:
        raise InputError(f"{path}: {exc}") from exc
    try:
        docs = [json.loads(text)]
    except json.JSONDecodeError:
        docs = []
        for n, line in enumerate(text.splitlines(), start=1):
            if not line.strip():
                continue
            try:
                docs.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise InputError(f"{path}, line {n}: not JSON ({exc.msg})") from exc

    objects: list[dict] = []

    def take(doc: object) -> None:
        if isinstance(doc, list):
            for item in doc:
                take(item)
        elif isinstance(doc, dict):
            if isinstance(doc.get("data"), list) and "id" not in doc:  # a list object: one page of results
                take(doc["data"])
            else:
                objects.append(doc)

    for doc in docs:
        take(doc)
    return objects


def _json_status(obj: dict) -> str:
    kind = str(obj.get("object", ""))
    if kind == "checkout.session":
        if obj.get("payment_status") == "paid":
            return "succeeded"
        return "canceled" if obj.get("status") == "expired" else "requires_payment_method"
    status = normalize_status(str(obj.get("status", "")))
    charge = obj if kind == "charge" else obj.get("latest_charge")  # a payment intent shows refunds only via an expanded charge
    if status == "succeeded" and isinstance(charge, dict):
        if kind == "charge" and charge.get("captured") is False:
            return "requires_capture"
        if charge.get("refunded") is True:
            return "refunded"
        refunded = charge.get("amount_refunded")
        if isinstance(refunded, (int, float)) and refunded > 0:
            return "partially_refunded"
    return status


def _read_json(path: Path, order_key: str) -> list[_Row]:
    out: list[_Row] = []
    for obj in _json_objects(path):
        ref = str(obj.get("id", ""))
        meta = obj.get("metadata")
        meta = meta if isinstance(meta, dict) else {}
        created = obj.get("created")
        if created is None:
            raise InputError(f"{path}: object {ref or '(no id)'} has no 'created' timestamp")
        try:
            at = parse_ts(created)
        except TimeParseError as exc:
            raise InputError(f"{path}: object {ref}: {exc}") from exc
        out.append(
            _Row(
                ref=ref,
                order=str(meta.get(order_key, "") or ""),
                site=str(meta.get("site_url", "") or ""),
                at=at,
                status=_json_status(obj),
                checkout_type=str(meta.get("checkout_type", "") or ""),
            )
        )
    return out


def _looks_like_json(path: Path) -> bool:
    try:
        with path.open(encoding="utf-8-sig") as fh:
            head = fh.read(4096).lstrip()
    except OSError as exc:
        raise InputError(f"{path}: {exc}") from exc
    return head[:1] in ("{", "[")


def _unlinked_finding(rows: list[_Row], order_key: str, top_n: int) -> Finding:
    """Successful payments that carry no order reference at all: the join cannot see them, so say so here."""
    won = [r for r in rows if not r.order and r.status in SUCCESS]
    adaptive = [r for r in won if r.checkout_type == ADAPTIVE_PRICING]
    other = [r for r in won if r.checkout_type != ADAPTIVE_PRICING]

    def listed(items: list[_Row]) -> str:
        return sample((f"{r.ref} ({r.at:%Y-%m-%d %H:%M} UTC)" for r in sorted(items, key=lambda r: r.at)), top_n)

    if adaptive:
        summary = (
            f"{len(adaptive)} successful Adaptive Pricing payments were never linked to an order"
            if len(adaptive) != 1
            else "1 successful Adaptive Pricing payment was never linked to an order"
        ) + f" (no {order_key} in the metadata)"
        if other:
            summary += f"; {_n(len(other), 'other successful payment')} without {order_key}"
        details = ["adaptive pricing: " + listed(adaptive)]
        if other:
            details.append("other: " + listed(other))
        return Finding(
            5,
            CHECK_UNLINKED,
            "suspect",
            summary,
            details,
            next_step=(
                f"The plugin writes {order_key} on an Adaptive Pricing payment only after it has matched the payment to its order "
                "(a payment from the last few minutes may still be waiting for it), so these are the ones it never matched: "
                "the customer paid, and the order most likely sits in Pending payment or "
                "was cancelled as unpaid. Open each payment in Stripe, find the order by customer and time, then complete or refund it. "
                "The order lookup for Adaptive Pricing was reworked in woocommerce-gateway-stripe#5757: check that your plugin "
                "version includes it."
            ),
        )
    if other:
        return Finding(
            5,
            CHECK_UNLINKED,
            "info",
            f"{_n(len(other), 'successful payment')} without {order_key} — usually other integrations (invoices, payment links)",
            ["examples: " + listed(other)],
            next_step="If any of them was a store order, the plugin never linked it: find the order by customer and time.",
        )
    return Finding(5, CHECK_UNLINKED, "ok", f"every successful payment carries {order_key}")


def read_payments(
    path: Path,
    terminal: set[str] | frozenset[str] = TERMINAL,
    order_key: str = "order_id",
    site_url: str | None = None,
    top_n: int = 10,
) -> AdapterResult[Event]:
    """Read a Stripe payments export (Dashboard CSV or API JSON) into provider events keyed by order."""
    as_json = _looks_like_json(path)
    rows = _read_json(path, order_key) if as_json else _read_csv(path, order_key)
    if not rows:
        raise InputError(f"{path}: no payments in the file")

    notes: list[str] = []
    other_sites = 0
    if site_url:
        needle = site_url.lower()
        kept_rows = [r for r in rows if needle in r.site.lower()]
        other_sites = len(rows) - len(kept_rows)
        if not kept_rows:
            raise InputError(f"{path}: no payment has a site_url containing {site_url!r}")
    else:
        kept_rows = rows
    with_order = [r for r in kept_rows if r.order]
    unlinked = _unlinked_finding(kept_rows, order_key, top_n)
    if not with_order and unlinked.verdict != "suspect":
        raise InputError(
            f"{path}: none of the {len(kept_rows)} payments carries '{order_key}' metadata, so none can be matched to an order "
            "(wrong key? pass --stripe-order-key)"
        )
    kept = with_order
    if not site_url:
        sites = sorted({r.site for r in with_order if r.site})
        if len(sites) > 1:
            shown = ", ".join(sites[:3]) + (", …" if len(sites) > 3 else "")
            notes.append(
                f"stripe: payments come from {len(sites)} sites ({shown}); order numbers of different stores can collide — pass --site-url"
            )

    head = (
        f"stripe: {_n(len(rows), 'payment')} read ({'API JSON' if as_json else 'Dashboard CSV'}); "
        f"{len(kept_rows) - len(with_order)} without {order_key} metadata cannot be matched to an order"
    )
    if site_url:
        head += f"; {other_sites} from other sites left out (--site-url {site_url})"
    notes.insert(0, head)

    events = [Event(payment_id=r.order, at=r.at, status=r.status, terminal=r.status in terminal, ref=r.ref) for r in kept]
    return AdapterResult(events, notes, [unlinked])
