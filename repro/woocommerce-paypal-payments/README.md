# Harness: WooCommerce PayPal Payments, a paid iDEAL order stays pending and is cancelled when the fee lookup fails

A real WordPress site with WooCommerce and PayPal Payments. The script posts a `PAYMENT.CAPTURE.COMPLETED` delivery for
an iDEAL order to the plugin's own `/wp-json/paypal/v1/incoming` endpoint while PayPal's API briefly fails, then runs
WooCommerce's unpaid-order cleanup.

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]        # PayPal Payments 4.1.3 (dev/develop)
PPCP_REPO=https://github.com/<fork>/woocommerce-paypal-payments PPCP_COMMIT=<sha> bash run.sh [WORK_DIR]   # another commit
```

Needs PHP 8 with mysqli, [WP-CLI](https://wp-cli.org/), Composer, git, curl and an empty MySQL or MariaDB database
(`DB_NAME`, default `ppcp_stand`; it is created if missing). `run.sh` downloads WordPress 7.1.3, installs WooCommerce
11.2.1, checks out PayPal Payments at the pinned commit (`composer install --no-dev`), adds the must-use plugin, seeds
the shop and starts PHP's built-in server on `PORT` (default 8898).

## What is real and what is not

| Part | |
|---|---|
| WordPress, WooCommerce, PayPal Payments: the REST route, `IncomingWebhookEndpoint`, the webhook signature check, `PaymentCaptureCompleted`, the local APM listener, `FeesUpdater`, `Orders::order()`, `wc_cancel_unpaid_orders()` | **real**, over HTTP on a real database |
| PayPal REST API | fake: the must-use plugin `stand-fake-paypal.php` answers WordPress HTTP calls to the PayPal API hosts (`pre_http_request`). The OAuth token and `verify-webhook-signature` (SUCCESS) are answered as PayPal does; `GET /v2/checkout/orders/{id}` answers 503 `SERVICE_UNAVAILABLE` (`outage`) or the completed order with its capture and fee (`ok`) |
| The shop | `seed.php`: NL/EUR, connected to an invented sandbox merchant, iDEAL on, stock management on, hold stock 60 minutes |
| The order | `create-order.php`: the state an iDEAL checkout leaves behind, `pending`, linked to the PayPal order, stock held |
| The delivery | `PAYMENT.CAPTURE.COMPLETED` with `custom_id` = the order id and `supplementary_data.related_ids.order_id` = the PayPal order id |

## The finding

For local APMs (iDEAL, Bancontact, BLIK, EPS, P24, Trustly, …) `PAYMENT.CAPTURE.COMPLETED` is what moves the order out of
`pending`. Before `payment_complete()` the handler fires
`woocommerce_paypal_payments_payment_capture_completed_webhook_handler`
([PaymentCaptureCompleted.php#L105-L119](https://github.com/woocommerce/woocommerce-paypal-payments/blob/8ab95eb470dd069c13d1647a5b8af7e8d570f2b1/modules/ppcp-webhooks/src/Handler/PaymentCaptureCompleted.php#L105-L119)),
and the local APM listener calls `FeesUpdater::update()`, which fetches the PayPal order for the fee
([LocalAlternativePaymentMethodsModule.php#L270-L281](https://github.com/woocommerce/woocommerce-paypal-payments/blob/8ab95eb470dd069c13d1647a5b8af7e8d570f2b1/modules/ppcp-local-alternative-payment-methods/src/LocalAlternativePaymentMethodsModule.php#L270-L281)).
`FeesUpdater` catches `WooCommerce\PayPalCommerce\Button\Exception\RuntimeException`
([FeesUpdater.php#L69-L80](https://github.com/woocommerce/woocommerce-paypal-payments/blob/8ab95eb470dd069c13d1647a5b8af7e8d570f2b1/modules/ppcp-wc-gateway/src/Helper/FeesUpdater.php#L69-L80)),
but `Orders::order()` throws the global `\RuntimeException` or `PayPalApiException`
([Orders.php#L185-L202](https://github.com/woocommerce/woocommerce-paypal-payments/blob/8ab95eb470dd069c13d1647a5b8af7e8d570f2b1/modules/ppcp-api-client/src/Endpoint/Orders.php#L185-L202)).
The exception escapes before `payment_complete()`, and `IncomingWebhookEndpoint` answers it with 200
`{"success":false}`
([IncomingWebhookEndpoint.php#L219-L238](https://github.com/woocommerce/woocommerce-paypal-payments/blob/8ab95eb470dd069c13d1647a5b8af7e8d570f2b1/modules/ppcp-webhooks/src/IncomingWebhookEndpoint.php#L219-L238)).
PayPal does not resend a delivery that got a 2xx, so the order stays `pending` until WooCommerce cancels it, with the
money captured at PayPal.

## Result at 4.1.3, run on 2026-10-12

The pinned commit is `dev/develop` since 2026-09-30; the files above are the same in the 4.1.3 release and on
`dev/release/4.2.0` as of 2026-10-16.

| PayPal's answer to the order fetch | 4.1.3 | with `FeesUpdater` catching `\RuntimeException` |
|---|---|---|
| 503 `SERVICE_UNAVAILABLE` | 200 `{"success":false}`, order `pending`; after the hold-stock time `cancelled` by `wc_cancel_unpaid_orders()` | 200 `{"success":true}`, `processing` (no fee meta) |
| the completed order (control) | 200 `{"success":true}`, `processing` | the same |

`run.sh` prints `REPRODUCED` and exits 0 while the bug is present; on a commit with a fix it says what changed and
exits 1.
