# Harness: Payfast for WooCommerce, an ITN is answered 200 when its validation request to Payfast fails

A real WordPress site with WooCommerce and the Payfast plugin (WordPress.org release), a South African shop in sandbox
mode, and a `pending` order. The script posts a signed ITN, as Payfast sends it, to the plugin's `?wc-api=WC_Gateway_PayFast`
while the plugin's server-to-server validation request fails, then runs WooCommerce's unpaid-order cleanup.

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]          # Payfast Gateway 1.7.9
```

Needs PHP 8 with mysqli, [WP-CLI](https://wp-cli.org/), curl and an empty MySQL or MariaDB database (`DB_NAME`, default
`payfast_stand`).

## What is real and what is not

| Part | |
|---|---|
| WordPress, WooCommerce, the plugin's ITN handler (signature, amount, order key, status), `wc_cancel_unpaid_orders()` | **real** |
| The ITN | built by `itn.php` and signed the way Payfast documents it (fields in order, urlencoded, passphrase, md5) |
| Payfast | fake: the must-use plugin answers only the plugin's `POST …/eng/query/validate` (`pre_http_request`): a cURL timeout (`outage`) or `VALID` (`ok`) |

## The finding

`check_itn_response()` always ends with `header( 'HTTP/1.0 200 OK' )`, whatever `handle_itn_request()` decided. A failed
validation request is treated like a forged ITN: logged, no order note, 200. Payfast re-sends only when it gets no 200
("If no 200 response is returned the notification will be re-sent immediately, then after 10 minutes and then at
exponentially longer intervals until eventually stopping", developers.payfast.co.za/docs), so the only notification of the
payment is dropped and WooCommerce cancels the paid order.

## Result

| Validation request | 1.7.9 | answering 503 for a failed validation |
|---|---|---|
| fails | 200, order `pending` → `cancelled` | 503; Payfast's re-sent ITN with validation working → `processing` |
| `VALID` | 200, order `processing` | the same |

The right column was checked with a temporary local change (503 when the validation request gets no answer); it is not part
of `run.sh`.

Run on 2026-10-18 (WordPress 7.1.3, WooCommerce 11.2.1, Payfast Gateway 1.7.9 — the same code as `trunk` on that day, PHP 8.4,
MariaDB 11.4):

```
== ITN, validation request fails: HTTP 200
   order=11 status=pending paid_date=none last_note="Stock levels reduced: Stand product (10&rarr;9)"
   calls: ["POST sandbox.payfast.co.za\/eng\/query\/validate (outage)"]
== after wc_cancel_unpaid_orders(): order=11 status=cancelled paid_date=none last_note="Email \"Cancelled order\" sent."
== control: HTTP 200
   order=12 status=processing paid_date=set last_note="Email \"Processing order\" sent."

REPRODUCED: the ITN for a completed payment got HTTP 200 although the plugin could not validate it with Payfast,
so Payfast will not re-send it; the order stayed pending without a note and WooCommerce cancelled it.
Control: the same ITN with validation answering VALID completes the order.
```
