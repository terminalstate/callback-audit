# Harness: PayU for WooCommerce, a COMPLETED notification no longer completes the order (master after 2.11.0)

A real WordPress site with WooCommerce and the PayU plugin from git, a checkout order paid with PayU (`payustandard`) in the
status the plugin gives new orders, and PayU's order notifications — PENDING, then COMPLETED — posted to
`?wc-api=wc_gateway_payustandard` and signed with the POS second key. The same run against the released v2.11.0 is the control.

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]          # master on 2026-10-18, control v2.11.0
PAYU_REPO=<git url> PAYU_COMMIT=<sha> bash run.sh                                 # another commit (the control stays v2.11.0)
```

Needs PHP 8 with mysqli, Composer, [WP-CLI](https://wp-cli.org/), git, curl and an empty MySQL or MariaDB database (`DB_NAME`,
default `payu_stand`).

## What is real and what is not

| Part | |
|---|---|
| WordPress, WooCommerce, the plugin's notification handler (`gateway_ipn()`, signature check by the bundled OpenPayU SDK), `wc_cancel_unpaid_orders()` | **real** |
| The order | created by `create-order.php` the way `process_payment()` leaves it once PayU has created its order: transaction id = PayU order id, status = the plugin's setting for new orders |
| The notifications | built by `notify.php` in PayU's format and signed the way the SDK verifies them (`OpenPayu-Signature: …;signature=md5(body + second key);algorithm=MD5`) |
| PayU | not needed: the COMPLETED path makes no call to PayU |

## The finding

`gateway_ipn()` stores the incoming status (`COMPLETED|<orderId>`) in `_payu_order_status` and only then asks whether a
COMPLETED status is stored. For a COMPLETED notification the answer is always yes, so `payment_complete()` is never called;
the notification is answered 200 and PayU does not resend it. Introduced on `master` by 07b8f98 (#118, 2026-09-17); before it
the check looked at the WooCommerce order status, so the released 2.11.0 is not affected.

## Result

| Plugin | New orders | After PENDING + COMPLETED (both HTTP 200) |
|---|---|---|
| `master` 2026-10-18 | on-hold (default) | on-hold, not paid |
| `master` 2026-10-18 | pending | pending → cancelled by `wc_cancel_unpaid_orders()` |
| v2.11.0 | on-hold | processing |
| `master` + reading the flag before storing the status | on-hold or pending | processing; a repeated COMPLETED changes nothing |

Run on 2026-10-19 (WordPress 7.1.3, WooCommerce 11.2.1, PHP 8.4, MariaDB 11.4):

```
plugin: 3ed1ca6 2026-10-12 Products without discount (#119)
seeded product 10
== master, new orders on-hold (plugin default): PENDING -> HTTP 200, COMPLETED -> HTTP 200 body=OID: 11|PS: COMPLETED|TID: STANDPAYU1A|WC AS: on-hold|WC BS:
   order=11 status=on-hold paid_date=none payu_statuses=PENDING|STANDPAYU1A,COMPLETED|STANDPAYU1A
== master, new orders pending (the other choice): PENDING -> HTTP 200, COMPLETED -> HTTP 200 body=OID: 12|PS: COMPLETED|TID: STANDPAYU1B|WC AS: pending|WC BS:
   order=12 status=pending paid_date=none payu_statuses=PENDING|STANDPAYU1B,COMPLETED|STANDPAYU1B
   after wc_cancel_unpaid_orders(): order=12 status=cancelled paid_date=none payu_statuses=PENDING|STANDPAYU1B,COMPLETED|STANDPAYU1B
plugin: 49b0a4f 2026-09-08 Version update (#117) (v2.11.0)
== control, v2.11.0, new orders on-hold: PENDING -> HTTP 200, COMPLETED -> HTTP 200 body=OID: 13|PS: COMPLETED|TID: STANDPAYU1C|WC AS: on-hold|WC BS:
   order=13 status=processing paid_date=set payu_statuses=COMPLETED|STANDPAYU1C

REPRODUCED: on master the COMPLETED notification is answered 200 and stored, but the order is never completed —
it stays on-hold, or (with new orders pending) WooCommerce cancels it as unpaid. v2.11.0 completes the same order.
```
