# Harness: Checkout.com for WooCommerce, classic mode — a 3-D Secure payment is not linked to the order before the redirect

A real WordPress site with WooCommerce and the Checkout.com plugin (WordPress.org release) in classic mode, a NAS sandbox
account with 3-D Secure on, and an order in the state `process_payment()` leaves when the payment needs 3-D Secure. The
script posts signed `payment_approved` and `payment_captured` webhooks, as Checkout.com sends them, to the plugin's
`?wc-api=wc_checkoutcom_webhook`, then runs WooCommerce's unpaid-order cleanup.

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]          # Checkout.com plugin 5.1.4.4
```

Needs PHP 8 with mysqli, [WP-CLI](https://wp-cli.org/), curl and an empty MySQL or MariaDB database (`DB_NAME`, default
`cko_stand`).

## What is real and what is not

| Part | |
|---|---|
| WordPress, WooCommerce, the plugin's classic webhook handler (signature, order lookup, payment id check, event handlers), `wc_cancel_unpaid_orders()` | **real** |
| The order | created by `create-order.php` as `process_payment()` leaves it on the 3-D Secure branch: `pending`, stock reduced, the "3d Redirect waiting" note, no `_cko_payment_id`. With a payment id argument — as `callback_handler()` leaves it when the buyer comes back (the control) |
| The webhooks | built in `run.sh` and signed the way the plugin checks them for NAS accounts: `Cko-Signature` = HMAC-SHA256 of the body with `"Bearer " + secret key` |
| Checkout.com | never called; the keys in `seed.php` are invented |
| `stand-status-observer.php` | observation only: records the status the handler sets with `http_response_code()` |

## The finding

In classic mode `create_payment()` returns only the redirect URL for a payment that needs 3-D Secure, and `process_payment()`
redirects without storing the payment id; redirect APMs (iDEAL and others) do the same. `_cko_payment_id` is written only by
`callback_handler()`, when the browser comes back to `success_url`. The webhook handler requires `_cko_payment_id` to equal
`data.id` and answers 422 otherwise. If the buyer completes 3-D Secure but does not come back, every webhook for the captured
payment is rejected, nothing links the payment to the order later, and WooCommerce cancels the order after the hold-stock time.

The handler sets the 422 with `http_response_code()` after WooCommerce has already called `status_header( 200 )`, so under
php-fpm and the PHP built-in server it goes out as 200 (see [../php-status-line](../php-status-line/)) and Checkout.com does not
retry; Apache mod_php sends 422. Retries would not help either way.

## Result

Run on 2026-10-20 (WordPress 7.1.3, WooCommerce 11.2.1, Checkout.com plugin 5.1.4.4 — the same code as `master` on that day,
PHP 8.4, MariaDB 11.4, PHP built-in server):

```
== buyer did not return: approved, captured, captured (retry) -> handler set 422 422 422, HTTP on the wire 200 200 200
   order=11 status=pending paid_date=none cko_payment_id=none last_note="Checkout.com 3d Redirect waiting. URL : https:\/\/3ds2-sandbox.ckotech.co\/interceptor\/3ds_stand"
== after wc_cancel_unpaid_orders(): order=11 status=cancelled paid_date=none cko_payment_id=none last_note="Email \"Cancelled order\" sent."
== control (buyer returned): approved, captured -> handler set 200 200, HTTP on the wire 200 200
   order=12 status=processing paid_date=set cko_payment_id=pay_standB last_note="Email \"Processing order\" sent."

REPRODUCED: signed webhooks for the captured payment are rejected (422) on every delivery because the order has no
_cko_payment_id (the 422 goes out as HTTP 200 200 200 here, see the note at the top); WooCommerce then cancels
the paid order. Control: once the payment id is stored, the same events complete it.
```
