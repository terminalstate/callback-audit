# Harness: GoCardless for WooCommerce, Pay by Bank — one failed API read in the billing_requests.fulfilled job loses a paid order

A real WordPress site with WooCommerce and the plugin as released on WordPress.org (3.0.3; `includes/class-wc-gocardless-gateway.php`
is identical to GitHub `develop` on 2026-10-18), a pending Pay by Bank order whose billing request was still `fulfilling` when the
buyer came back (or whose buyer never came back), and GoCardless's webhooks posted to `?wc-api=wc_gateway_gocardless&request=webhook`,
signed with the webhook secret (`Webhook-Signature` = HMAC-SHA256 of the body). The jobs the endpoint queues are run through Action
Scheduler's own runner. Reported in
[gocardless/woocommerce-gateway-gocardless#208](https://github.com/gocardless/woocommerce-gateway-gocardless/issues/208).

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]                                  # 3.0.3
GC_PATCH=fix.patch DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… DB_NAME=gc_fix bash run.sh           # with the proposed change
GC_VERSION=<version> bash run.sh                                                                         # another release
```

Needs PHP 8 with mysqli, [WP-CLI](https://wp-cli.org/), git, curl and an empty MySQL or MariaDB database (`DB_NAME`, default
`gocardless_stand`).

## What is real and what is not

| Part | |
|---|---|
| WordPress, WooCommerce, the plugin's webhook endpoint (`_handle_webhook()`), its jobs (`_process_billing_request_event_fulfilled()`, `_process_payment_event()`), Action Scheduler, `wc_cancel_unpaid_orders()` | **real** |
| The order | created by `create-order.php` the way the checkout leaves it when the bank's answer is still `fulfilling`: `pending`, stock reduced, the billing request stored by the gateway's own `update_order_resource()`, no payment |
| The webhooks | `billing_requests.fulfilled` and `payments.confirmed` in GoCardless's format, signed with the shop's webhook secret (`sign.php`) |
| GoCardless API | `stand-fake-gocardless.php` answers the plugin's calls through `pre_http_request`: `GET /billing_requests/{id}` times out once and answers `fulfilled` afterwards, `GET /payments/{id}` answers `confirmed`; every call is recorded |

## The finding

`_handle_webhook()` queues each event and answers 200. `_process_billing_request_event_fulfilled()` fetches the billing request; on a
`WP_Error` it logs "Failed to retrieve billing request." and returns `false`. The action completes and nothing re-queues it. The payment
is never attached (`_gocardless_payment_id` stays empty), so the later `payments.confirmed` event — which looks the order up only by that
meta — cannot find the order. The order stays `pending` and `wc_cancel_unpaid_orders()` cancels it, while the Pay by Bank payment has
been made.

## Result

| Step | 3.0.3 | with `fix.patch` |
|---|---|---|
| `billing_requests.fulfilled` | 200, one job | 200, one job |
| job, GET billing_requests times out | "Failed to retrieve billing request.", job complete, nothing queued | same, and the event is queued again (+300 s) |
| next | `payments.confirmed` → 200, order not found; `wc_cancel_unpaid_orders()` → **`cancelled`**, no payment id | job 2: GET answers → **`processing`**, payment `PM…` |
| control: GET succeeds | `processing`, payment `PM…` | — |

`fix.patch` re-queues the same event when the billing-request GET fails, with a growing delay, at most 10 attempts.

Run on 2026-10-22 (WordPress 7.1.3, WooCommerce 11.2.1, PHP 8.4, MariaDB 11.4). "GET creditors" calls are the plugin's own creditor
look-ups on each load; the fake answers them with an empty object.

```
plugin: woocommerce-gateway-gocardless 3.0.3
== Pay by Bank, the job's GET billing_requests times out once: billing_requests.fulfilled -> HTTP 200; job: action 10: complete
   order=11 status=pending paid_date=none payment_id=- gc_calls=[GET creditors, GET creditors, GET billing_requests/BR11STAND, GET creditors]
   payments.confirmed -> HTTP 200; job: action 11: complete
   order=11 status=pending paid_date=none payment_id=- gc_calls=[GET creditors, GET creditors, GET billing_requests/BR11STAND, GET creditors, GET creditors, GET creditors, GET creditors, GET creditors]
   after wc_cancel_unpaid_orders(): order=11 status=cancelled paid_date=none payment_id=- gc_calls=[GET creditors, GET creditors, GET billing_requests/BR11STAND, GET creditors, GET creditors, GET creditors, GET creditors, GET creditors, GET creditors, GET creditors]
== control: the GET succeeds: billing_requests.fulfilled -> HTTP 200; job: action 14: complete
   order=12 status=processing paid_date=set payment_id=PM12 gc_calls=[GET creditors, GET creditors, GET billing_requests/BR12STAND, GET payments/PM12, GET creditors]

REPRODUCED: one failed GET in the billing_requests.fulfilled job leaves a paid Pay by Bank order without its payment: the webhook
was answered 200, the job ends, payments.confirmed cannot find the order, and WooCommerce cancels it. With the GET succeeding the
same webhook completes the order.
```

```
plugin: woocommerce-gateway-gocardless 3.0.3 + fix.patch
== Pay by Bank, the job's GET billing_requests times out once: billing_requests.fulfilled -> HTTP 200; job: action 10: complete
   order=11 status=pending paid_date=none payment_id=- gc_calls=[GET creditors, GET creditors, GET billing_requests/BR11STAND, GET creditors]
   job 2 (re-queued): action 11: complete
   order=11 status=processing paid_date=set payment_id=PM11 gc_calls=[GET creditors, GET creditors, GET billing_requests/BR11STAND, GET creditors, GET creditors, GET creditors, GET billing_requests/BR11STAND, GET payments/PM11, GET creditors]

FIXED: the failed GET re-queues the event; the second run attaches the payment and the order is processing.
```
