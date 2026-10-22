# Harness: Paystack for WooCommerce, a failed verify call inside the charge.success webhook is answered 200

A real WordPress site with WooCommerce and the Paystack plugin from git, a pending checkout order paid with Paystack, and Paystack's
`charge.success` posted to `?wc-api=tbz_wc_paystack_webhook`, signed with the secret key (`x-paystack-signature` = HMAC-SHA512 of
the body). Related: [PaystackOSS/woo-paystack#147](https://github.com/PaystackOSS/woo-paystack/issues/147) (same symptom, another
cause: the `sleep(10)` before the reply).

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]                                  # master on 2026-10-20 (5.8.5)
PAYSTACK_PATCH=fix.patch DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… DB_NAME=paystack_fix bash run.sh   # with the proposed change
PAYSTACK_COMMIT=<sha> bash run.sh                                                                           # another commit
```

Needs PHP 8 with mysqli, [WP-CLI](https://wp-cli.org/), git, curl and an empty MySQL or MariaDB database (`DB_NAME`, default
`paystack_stand`). Each delivery takes over 10 s: the handler sleeps 10 s before verifying.

## What is real and what is not

| Part | |
|---|---|
| WordPress, WooCommerce, the plugin's webhook handler (`process_webhooks()`), its verify call (`get_paystack_transaction()`), `wc_cancel_unpaid_orders()` | **real** |
| The order | created by `create-order.php` the way checkout leaves it before payment: `pending`, stock reduced, `_paystack_txn_ref` built as the plugin builds it |
| The webhook | a POST in Paystack's `charge.success` format, signed with the secret key configured in `seed.php` |
| Paystack API | `stand-fake-paystack.php` answers `GET /transaction/verify/<ref>` through `pre_http_request`: 503, 429, a cURL timeout, or the successful transaction |

## The finding

`process_webhooks()` checks the signature, sleeps, then calls `get_paystack_transaction()`, which returns `false` for any `WP_Error`
and any non-200. On `false` the handler just returns. WooCommerce's `wc-api` dispatcher has already sent `status_header( 200 )`, so
Paystack gets 200, treats the event as delivered and does not resend it. Nothing is logged or noted; the order stays `pending` and
`wc_cancel_unpaid_orders()` cancels it. For bank transfer, USSD and mobile money the webhook is the only path that completes the
order.

## Result

| Verify call | master 2026-10-20 | with `fix.patch` |
|---|---|---|
| 503 | 200, `pending` → **`cancelled`** by `wc_cancel_unpaid_orders()` | 503, `pending`; Paystack's resend → 200, `processing` |
| timeout (`WP_Error`) | 200, `pending` | 503, `pending` |
| 429 | 200, `pending` | 503, `pending` |
| succeeds (control) | 200, `processing` | 200, `processing` |
| duplicate resend after success | — | 200, unchanged |

`fix.patch` answers 503 when the verify call fails, so Paystack's own retries (every 3 minutes for the first 4 tries, then hourly for
72 hours in live mode) recover the order once the API answers.

Run on 2026-10-22 (WordPress 7.1.3, WooCommerce 11.2.1, PHP 8.4, MariaDB 11.4):

```
plugin: 830da0c 2026-10-20
== verify answers 503: charge.success -> HTTP 200
   order=11 status=pending paid_date=none transaction_id=- notes=1 paystack_calls=1
== verify times out (WP_Error): charge.success -> HTTP 200
   order=12 status=pending paid_date=none transaction_id=- notes=1 paystack_calls=1
== verify answers 429: charge.success -> HTTP 200
   order=13 status=pending paid_date=none transaction_id=- notes=1 paystack_calls=1
== control: verify succeeds: charge.success -> HTTP 200
   order=14 status=processing paid_date=set transaction_id=14_1792640160 notes=5 paystack_calls=1
   503 order after wc_cancel_unpaid_orders(): order=11 status=cancelled paid_date=none transaction_id=- notes=3 paystack_calls=1

REPRODUCED: with the verify call failing (503, timeout, 429) the charge.success webhook is answered 200 and nothing is
applied — Paystack treats it as delivered; the order stays pending and WooCommerce cancels it. The same delivery with
verify succeeding completes the order, so a resend would have fixed it.
```

With `PAYSTACK_PATCH=fix.patch`:

```
plugin: 830da0c 2026-10-20 + fix.patch
== verify times out (WP_Error): charge.success -> HTTP 503
   order=11 status=pending paid_date=none transaction_id=- notes=1 paystack_calls=1
== verify answers 429: charge.success -> HTTP 503
   order=12 status=pending paid_date=none transaction_id=- notes=1 paystack_calls=1
== verify answers 503: charge.success -> HTTP 503
   order=13 status=pending paid_date=none transaction_id=- notes=1 paystack_calls=1
== Paystack's resend, verify answers: charge.success -> HTTP 200
   order=13 status=processing paid_date=set transaction_id=13_1792640250 notes=5 paystack_calls=2
== duplicate resend: charge.success -> HTTP 200
   order=13 status=processing paid_date=set transaction_id=13_1792640250 notes=5 paystack_calls=3
== control: verify succeeds: charge.success -> HTTP 200
   order=14 status=processing paid_date=set transaction_id=14_1792640308 notes=5 paystack_calls=1

FIXED: a failed verify call is answered 503, so Paystack resends; the resend completes the order and a duplicate
resend changes nothing.
```

`notes=1` is the stock-reduction note from checkout; the webhook adds none on failure.
