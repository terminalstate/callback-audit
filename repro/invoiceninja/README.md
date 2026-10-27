# Harness: invoiceninja, payment webhooks that leave a payment unfinished

Three PHPUnit test files in `tests/Feature/PaymentDrivers/`, one per finding, that run inside invoiceninja's own
suite (`MockAccountData`, `DatabaseTransactions`, the project's `phpunit.xml`):

- `StripeRedirectMethodWebhookStandTest.php`: a redirect payment (iDEAL, Bancontact, Klarna, …) whose customer never
  comes back is never recorded. Reported in [#13341](https://github.com/invoiceninja/invoiceninja/issues/13341);
  the maintainer has checked in a fix.
- `SubscriptionDelayedSettlementStandTest.php`: a subscription paid with a method that starts as Pending (SEPA, BACS,
  ACH, GoCardless, …) is never completed after the payment settles. Reported in
  [#13343](https://github.com/invoiceninja/invoiceninja/issues/13343).
- `RazorpayWebhookStubStandTest.php`: the Razorpay webhook handler is an empty stub, so a payment whose browser never
  posts back is never recorded.

```
DB_DATABASE=ninja_stand bash run.sh [WORK_DIR]     # invoiceninja v5-develop at 493c388
```

Needs git, PHP 8.2+ with the extensions listed in invoiceninja's `composer.json`, Composer, and an empty MySQL or
MariaDB database (`DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_DATABASE`; defaults `127.0.0.1`, `3306`,
`root`, `ninja`, `ninja_stand`). `run.sh` clones the pinned commit, installs the locked dependencies, migrates and
seeds, copies the test files in and runs them; it refuses a database that already has tables. Where Packagist is not
reachable it fetches the locked packages from their GitHub sources instead (`fetch_vendor.py`, `write_installed.php`,
`composer.phar` from the Composer GitHub release).

## Redirect payment never recorded (#13341)

Only Stripe's HTTP API is faked, through the `ApiRequestor::setHttpClient()` seam the project's own Stripe tests use.

### What is real and what is not

| Part | |
|---|---|
| invoiceninja: the `/payment_webhook/{company_key}/{company_gateway}` route, Stripe signature verification with the gateway's webhook secret, `StripePaymentDriver::processWebhookRequest()`, the `PaymentIntentWebhook` job, payment creation | **real**, on a migrated and seeded database; the queue is `sync`, as in the project's `phpunit.xml` |
| Stripe API: `GET /v1/payment_intents/{id}`, `GET /v1/charges/{id}` | fake: a `succeeded` PaymentIntent with `metadata.payment_hash`, and its charge |
| The customer | approved at the bank and never came back to the return URL (nothing calls the return route) |

### The finding

For iDEAL, Bancontact, EPS, giropay, Przelewy24, Klarna, FPX, Alipay and SOFORT, the payment is written only when the
browser comes back to the return URL ([iDeal.php#L55-L86](https://github.com/invoiceninja/invoiceninja/blob/493c3884e4214028bc5970cb41bafbd9c4d96401/app/PaymentDrivers/Stripe/iDeal.php#L55-L86),
[Bancontact.php#L56-L88](https://github.com/invoiceninja/invoiceninja/blob/493c3884e4214028bc5970cb41bafbd9c4d96401/app/PaymentDrivers/Stripe/Bancontact.php#L56-L88)). If the customer approves in the
banking app and never returns, Stripe still completes the PaymentIntent and sends `payment_intent.succeeded`. The route
answers 200; the job fetches the PaymentIntent and the charge, logs a gateway success, and then creates a payment only
for the six `ASYNC_PAYMENT_TYPES` bank debits, `card` and `promptpay`
([PaymentIntentWebhook.php#L191-L230](https://github.com/invoiceninja/invoiceninja/blob/493c3884e4214028bc5970cb41bafbd9c4d96401/app/PaymentDrivers/Stripe/Jobs/PaymentIntentWebhook.php#L191-L230),
[#L44-L51](https://github.com/invoiceninja/invoiceninja/blob/493c3884e4214028bc5970cb41bafbd9c4d96401/app/PaymentDrivers/Stripe/Jobs/PaymentIntentWebhook.php#L44-L51)). A PaymentIntent created with
`payment_method_types: ['ideal']` matches none of them, and `charge.succeeded` only updates a payment that already
exists ([StripePaymentDriver.php#L899-L913](https://github.com/invoiceninja/invoiceninja/blob/493c3884e4214028bc5970cb41bafbd9c4d96401/app/PaymentDrivers/StripePaymentDriver.php#L899-L913)). Stripe has the
money; the invoice stays unpaid.

Stripe: "Listen for these events rather than waiting on a callback from the client. On the client, the customer could
close the browser window or quit the app before the callback executes" (https://docs.stripe.com/payments/ideal/accept-a-payment?payment-ui=elements&api-integration=paymentintents).

### Result at 493c388 (v5-develop, 2026-10-10)

| test | input | HTTP | what the job did | payment |
|---|---|---|---|---|
| `test_ideal_webhook_via_route_creates_no_payment_current_behaviour` | signed `payment_intent.succeeded` for an iDEAL PaymentIntent, posted to the route | 200 | fetched the PaymentIntent and the charge, logged a Stripe gateway success | **none**, invoice balance unchanged |
| `test_ideal_webhook_creates_no_payment_current_behaviour` | the same PaymentIntent, job run directly | — | same | **none**, invoice balance unchanged |
| `test_sepa_webhook_creates_completed_payment_control` | the same path for a `sepa_debit` PaymentIntent | — | same | COMPLETED, type SEPA |
| `test_ideal_webhook_creates_completed_payment_if_fixed` (group `if-fixed`) | iDEAL; expects a COMPLETED payment | — | — | fails today |

Default run of this file (`--exclude-group if-fixed`): 3 tests OK. `--group if-fixed`: 1 failure, as expected while the
bug is present.

## Subscription never completed after a Pending payment settles (#13343)

Nothing is faked: completing a payment that already exists makes no Stripe API call.

### What is real and what is not

| Part | |
|---|---|
| invoiceninja: `StripePaymentDriver::createPayment()` with a `billing_context` in the PaymentHash (as the SEPA return handler calls it), `SubscriptionService::completePurchase()`, the `/payment_webhook/{company_key}/{company_gateway}` route with Stripe signature verification, the `PaymentIntentWebhook` job | **real**, on a migrated and seeded database; the queue is `sync` |
| The purchase | a subscription with one recurring product, its invoice and a PaymentHash, created with the project's factories |
| The settlement | a signed `payment_intent.succeeded` for the PaymentIntent of the Pending payment |

### The finding

A billing portal purchase is finished by `SubscriptionService::completePurchase()`: it creates the recurring invoice,
swaps the plan for `change_plan` and sends the purchase webhook. `BaseDriver::createPayment()` calls it only when the
payment is created COMPLETED ([BaseDriver.php#L369-L382](https://github.com/invoiceninja/invoiceninja/blob/493c3884e4214028bc5970cb41bafbd9c4d96401/app/PaymentDrivers/BaseDriver.php#L369-L382)).
Stripe SEPA, BACS, ACH, BECS, ACSS and bank transfer, GoCardless, and the redirect methods create the payment as
Pending. When it settles, `payment_intent.succeeded` finds the existing payment and only sets it to COMPLETED
([PaymentIntentWebhook.php#L78-L100](https://github.com/invoiceninja/invoiceninja/blob/493c3884e4214028bc5970cb41bafbd9c4d96401/app/PaymentDrivers/Stripe/Jobs/PaymentIntentWebhook.php#L78-L100));
GoCardless and the hosted ACH poller do the same. The payment is Completed and the invoice Paid, but there is no
recurring invoice, so the subscription is never billed again. A card purchase of the same plan works.

### Result at 493c388 (v5-develop, 2026-10-10)

| test | input | result |
|---|---|---|
| `test_pending_subscription_payment_never_completes_purchase_current_behaviour` | purchase paid with a payment created Pending (as SEPA does), then a signed `payment_intent.succeeded` posted to the route | 200, payment Completed, **0** recurring invoices for the subscription |
| `test_completed_subscription_payment_creates_recurring_invoice_control` | the same purchase with the payment created COMPLETED (as a card is) | 1 recurring invoice with the subscription's `subscription_id` |
| `test_pending_then_settled_subscription_payment_completes_purchase_if_fixed` (group `if-fixed`) | Pending, then settled; expects 1 recurring invoice | fails today (0 instead of 1) |

Default run of this file: 2 tests OK. `--group if-fixed`: 1 failure, as expected while the bug is present.

## Razorpay webhook is an empty stub

No provider HTTP call is faked.

### What is real and what is not

| Part | |
|---|---|
| invoiceninja: the `/payment_webhook/{company_key}/{company_gateway}` route, `RazorpayPaymentDriver::processWebhookRequest()`, the browser-return path `Razorpay\Hosted::paymentResponse()` with the SDK's signature check, payment creation | **real**, on a migrated and seeded database |
| Razorpay | not called: the webhook test posts a realistic `payment.captured` body; the control carries a genuine payment signature computed with the gateway's API secret |
| The customer | approved the payment and closed the tab before the Checkout handler posted back (nothing calls the return route in the webhook tests) |

### The finding

`RazorpayPaymentDriver::processWebhookRequest()` is empty ([RazorpayPaymentDriver.php#L122-L125](https://github.com/invoiceninja/invoiceninja/blob/493c3884e4214028bc5970cb41bafbd9c4d96401/app/PaymentDrivers/RazorpayPaymentDriver.php#L122-L125)),
and the controller returns its `null` as an empty 200 ([PaymentWebhookController.php#L19-L31](https://github.com/invoiceninja/invoiceninja/blob/493c3884e4214028bc5970cb41bafbd9c4d96401/app/Http/Controllers/PaymentWebhookController.php#L19-L31)),
so every Razorpay event sent to the route is acknowledged and dropped. A Razorpay payment is recorded only on the browser
return, after the signature check ([Hosted.php#L82-L138](https://github.com/invoiceninja/invoiceninja/blob/493c3884e4214028bc5970cb41bafbd9c4d96401/app/PaymentDrivers/Razorpay/Hosted.php#L82-L138)).
Razorpay captures authorised payments automatically by default
([capture settings](https://razorpay.com/docs/payments/payments/capture-settings/)), so when the Checkout handler never
runs, Razorpay has the money and the invoice stays unpaid.

Razorpay: "This could be because of a slow network connection or your customer closing the window while processing the
payment." (https://razorpay.com/docs/webhooks/)

### Result at 493c388 (v5-develop, 2026-10-10)

| test | input | result |
|---|---|---|
| `test_captured_webhook_is_a_noop_current_behaviour` | a `payment.captured` event for the order stored in the PaymentHash, posted to the route | 200, empty body, no payment, invoice balance unchanged |
| `test_browser_return_records_completed_payment_control` | the browser return through `Hosted::paymentResponse()` with a valid signature | COMPLETED payment |
| `test_captured_webhook_records_completed_payment_if_fixed` (group `if-fixed`) | `payment.captured`; expects a COMPLETED payment | fails today |

Default run of this file: 2 tests OK. `--group if-fixed`: 1 failure, as expected while the bug is present. The Razorpay
files above are unchanged on v5-develop as of 2026-10-27.
