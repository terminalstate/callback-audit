# Harness: Flutterwave for WooCommerce, a webhook whose verification fails is recorded as processed and its retry is discarded

A real WordPress site with WooCommerce and the Flutterwave plugin from git, a pending checkout order paid with Flutterwave, and
Flutterwave's `charge.completed` webhook posted to `?wc-api=flw_wc_payment_webhook` with the merchant's secret hash in `verif-hash`.
The plugin verifies the transaction through its own API client; the Flutterwave API behind it is a stand-in. Reported in
[Flutterwave/Woocommerce-v2#105](https://github.com/Flutterwave/Woocommerce-v2/issues/105).

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]                       # master on 2026-10-08 (3.3.2)
FLW_PATCH=fix.patch DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… DB_NAME=flw_fix bash run.sh   # with the proposed change
FLW_COMMIT=<sha> bash run.sh                                                                     # another commit
```

Needs PHP 8 with mysqli, [WP-CLI](https://wp-cli.org/), git, curl and an empty MySQL or MariaDB database (`DB_NAME`, default
`flw_stand`).

## What is real and what is not

| Part | |
|---|---|
| WordPress, WooCommerce, the plugin's webhook handler (`flutterwave_webhooks()`), its SDK (`requery_transaction()`, `verify_by_reference()`) and HTTP client, `wc_cancel_unpaid_orders()` | **real** |
| The order | created by `create-order.php` the way checkout leaves it before payment: `pending`, stock reduced, `tx_ref` built as the plugin builds it |
| The webhook | a POST in Flutterwave's `charge.completed` format with the secret hash configured in `seed.php` |
| Flutterwave API | `stand-fake-flutterwave.php` answers `GET /v3/transactions/verify_by_reference` through `pre_http_request`: a cURL timeout in "outage" mode, the successful transaction otherwise. The plugin's telemetry host is blocked, so nothing leaves the stand |

## The finding

`flutterwave_webhooks()` appends the Flutterwave transaction id (`data.id`) to `_flw_processed_webhook_ids` and saves the order before
it verifies the transaction. When the verification request fails, `requery_transaction()` logs "Awaiting Webhook Verification..." and
returns without changing the order, and the handler answers 201 "Order Processed Successfully". Flutterwave treats anything but 200
as a failure and, with retries enabled, resends the event three times, 30 minutes apart; the resend carries the same `data.id`, so it
is answered 200 "Webhook already processed" without verification, and Flutterwave stops. Nothing else re-checks the order:
WooCommerce cancels it after the hold-stock time.

## Result

| Step | `master` 2026-10-08 | with `fix.patch` |
|---|---|---|
| 1. `charge.completed`, verification times out | 201, `pending`, id recorded | 503, `pending`, id not recorded |
| 2. Flutterwave's retry, API answers | 200 "Webhook already processed", no API call, `pending` | 201, verified, `processing` |
| 3. `wc_cancel_unpaid_orders()` (hold stock 60 min) | **`cancelled`** | `processing` |
| control: first delivery, API answers | `processing` | `processing` |

`fix.patch` makes `requery_transaction()` and `webhook_verify()` return whether Flutterwave gave an answer; the handler answers 503
when it did not and records the id only after a definite result, so the replay protection stays.

Run on 2026-10-21 (WordPress 7.1.3, WooCommerce 11.2.1, PHP 8.4, MariaDB 11.4):

```
plugin: 79d141e 2026-10-08
== 1. webhook, verification times out: HTTP 201 {"status":"success","message":"Order Processed Successfully"}
   order=11 status=pending paid_date=none processed_ids=["5550001"]
== 2. Flutterwave's retry, API back: HTTP 200 {"status":"success","message":"Webhook already processed"}
   order=11 status=pending paid_date=none processed_ids=["5550001"]
   API calls: ["\/v3\/transactions\/verify_by_reference (outage)"]
== after wc_cancel_unpaid_orders(): order=11 status=cancelled paid_date=none processed_ids=["5550001"]
== control: first delivery, API answers: HTTP 201 {"status":"success","message":"Order Processed Successfully"}
   order=12 status=processing paid_date=set processed_ids=["5550001"]

REPRODUCED: the webhook marked the transaction processed before verifying it; the failed verification was answered 201, and
the retry was answered 200 'Webhook already processed' without verifying — the paid order stayed pending and was cancelled.
```

With `FLW_PATCH=fix.patch`:

```
plugin: 79d141e 2026-10-08 + fix.patch
== 1. webhook, verification times out: HTTP 503 {"status":"error","message":"Transaction could not be verified, retry later"}
   order=11 status=pending paid_date=none processed_ids=[]
== 2. Flutterwave's retry, API back: HTTP 201 {"status":"success","message":"Order Processed Successfully"}
   order=11 status=processing paid_date=set processed_ids=["5550001"]
   API calls: ["\/v3\/transactions\/verify_by_reference (outage)","\/v3\/transactions\/verify_by_reference (ok)"]
== after wc_cancel_unpaid_orders(): order=11 status=processing paid_date=set processed_ids=["5550001"]
== control: first delivery, API answers: HTTP 201 {"status":"success","message":"Order Processed Successfully"}
   order=12 status=processing paid_date=set processed_ids=["5550001"]

NOT REPRODUCED with fix.patch: the failed verification was answered 503 and not recorded; the retry verified the
transaction and the order is processing.
```
