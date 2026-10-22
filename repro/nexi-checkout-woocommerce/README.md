# Harness: Nexi Checkout for WooCommerce, one failed status read in the deferred webhook job loses the payment

A real WordPress site with WooCommerce and the plugin as released on WordPress.org (2.14.8 = GitHub `master` on 2026-10-06; the
GitHub tree has no `vendor/`), a pending checkout order paid with Swish (`nets_easy_swish`) whose buyer did not come back, and Nexi's
`payment.checkout.completed` posted to `?wc-api=DIBS_Api_Callbacks&dibs-payment-created-callback=1`. The job the handler schedules
(`dibs_payment_created_callback`, +120 s) is run through Action Scheduler's own runner.

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]                                  # 2.14.8
NEXI_PATCH=fix.patch DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… DB_NAME=nets_fix bash run.sh       # with the proposed change
NETS_VERSION=<version> bash run.sh                                                                       # another release
```

Needs PHP 8 with mysqli, [WP-CLI](https://wp-cli.org/), git, curl and an empty MySQL or MariaDB database (`DB_NAME`, default
`nets_stand`).

## What is real and what is not

| Part | |
|---|---|
| WordPress, WooCommerce, the plugin's webhook handler (`payment_created_scheduler()`), its job (`execute_dibs_payment_created_callback()`, `wc_dibs_confirm_dibs_order()`), the cancel hook, Action Scheduler, `wc_cancel_unpaid_orders()` | **real** |
| The order | created by `create-order.php` the way the redirect checkout leaves it before the buyer pays in the Swish app: `pending`, stock reduced, the Nexi payment id in `_dibs_payment_id` |
| The webhook | a POST in Nexi's `payment.checkout.completed` format with an `Authorization` header |
| Nexi API | `stand-fake-nexi.php` answers the plugin's calls through `pre_http_request`: `GET /v1/payments/{id}` times out once and answers "charged" afterwards; every call is recorded |

## The finding

`payment_created_scheduler()` answers 200 at once and schedules one action. `execute_dibs_payment_created_callback()` calls
`wc_dibs_confirm_dibs_order()`, which on a `WP_Error` from the GET adds the note "Error when confirming order" and returns. The action
completes; nothing re-schedules it and nothing else asks Nexi. When the buyer did not return (Nexi documents that mobile wallets do not
guarantee it), the order stays `pending` and `wc_cancel_unpaid_orders()` cancels it. The cancel hook skips Nexi because
`_dibs_date_paid` is empty, so the charge (Swish, A2A, auto-capture) is neither recorded nor refunded; a card reservation stays on the
card.

## Result

| Step | 2.14.8 | with `fix.patch` |
|---|---|---|
| webhook | 200, one job scheduled | 200, one job scheduled |
| job, GET times out | note "Error when confirming order", job complete, nothing scheduled | note, job re-scheduled (+300 s) |
| next | `wc_cancel_unpaid_orders()` → **`cancelled`**, one GET in total, no cancel call to Nexi | job 2: GET answers → **`processing`**, charge `c-1` |
| control: GET succeeds | `processing`, charge `c-1` | — |

`fix.patch` makes `wc_dibs_confirm_dibs_order()` return the `WP_Error` and re-schedules the job with a growing delay, at most 10 attempts.

Run on 2026-10-22 (WordPress 7.1.3, WooCommerce 11.2.1, PHP 8.4, MariaDB 11.4):

```
plugin: dibs-easy-for-woocommerce 2.14.8
== Swish, the job's GET times out once: payment.checkout.completed -> HTTP 200; scheduled: 1
   job (+120 s): [error notice: cURL error 28: Operation timed out after 10001 milliseconds with 0 bytes received] action 10: complete
   order=11 status=pending paid_date=none _dibs_date_paid=none charge_id=- error_notes=1 pending_callbacks=0 nexi_calls=[GET payments/0123456789abcdef0123456789abcd01]
   after wc_cancel_unpaid_orders(): order=11 status=cancelled paid_date=none _dibs_date_paid=none charge_id=- error_notes=1 pending_callbacks=0 nexi_calls=[GET payments/0123456789abcdef0123456789abcd01]
== control: the GET succeeds: payment.checkout.completed -> HTTP 200; scheduled: 1
   job (+120 s): action 13: complete
   order=12 status=processing paid_date=set _dibs_date_paid=set charge_id=c-1 error_notes=0 pending_callbacks=0 nexi_calls=[GET payments/0123456789abcdef0123456789abcd02]

REPRODUCED: one failed GET in the deferred job ends the only path that confirms a Swish payment whose buyer did not come back:
the webhook was already answered 200, nothing re-checks, WooCommerce cancels the order and the cancel hook never calls Nexi —
although Nexi (the fake) answers 'charged' from the second call on. With the GET succeeding the same webhook completes the order.
```

With `NEXI_PATCH=fix.patch`:

```
plugin: dibs-easy-for-woocommerce 2.14.8 + fix.patch
== Swish, the job's GET times out once: payment.checkout.completed -> HTTP 200; scheduled: 1
   job (+120 s): [error notice: cURL error 28: …] action 10: complete
   order=11 status=pending paid_date=none _dibs_date_paid=none charge_id=- error_notes=1 pending_callbacks=1 nexi_calls=[GET payments/0123456789abcdef0123456789abcd03]
   job 2 (re-scheduled): action 11: complete
   order=11 status=processing paid_date=set _dibs_date_paid=set charge_id=c-1 error_notes=1 pending_callbacks=0 nexi_calls=[GET payments/0123456789abcdef0123456789abcd03, GET payments/0123456789abcdef0123456789abcd03]

FIXED: the failed GET re-schedules the job; the second run confirms the Swish payment and the order is processing.
```

The error notice in the job's output is printed by the plugin itself (`wc_add_notice()` inside a background job); it is shortened here.
