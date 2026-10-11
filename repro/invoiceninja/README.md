# Harness: invoiceninja, a Stripe redirect payment whose customer never comes back is never recorded

A PHPUnit test file, `tests/Feature/PaymentDrivers/Stripe/StripeRedirectMethodWebhookStandTest.php`, that runs inside
invoiceninja's own suite (`MockAccountData`, `DatabaseTransactions`, the project's `phpunit.xml`). Only Stripe's HTTP
API is faked, through the `ApiRequestor::setHttpClient()` seam the project's own Stripe tests use.

```
DB_DATABASE=ninja_stand bash run.sh [WORK_DIR]     # invoiceninja v5-develop at 493c388
```

Needs git, PHP 8.2+ with the extensions listed in invoiceninja's `composer.json`, Composer, and an empty MySQL or
MariaDB database (`DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_DATABASE`; defaults `127.0.0.1`, `3306`,
`root`, `ninja`, `ninja_stand`). `run.sh` clones the pinned commit, installs the locked dependencies, migrates and
seeds, copies the test file in and runs it; it refuses a database that already has tables. Where Packagist is not
reachable it fetches the locked packages from their GitHub sources instead (`fetch_vendor.py`, `write_installed.php`,
`composer.phar` from the Composer GitHub release).

## What is real and what is not

| Part | |
|---|---|
| invoiceninja: the `/payment_webhook/{company_key}/{company_gateway}` route, Stripe signature verification with the gateway's webhook secret, `StripePaymentDriver::processWebhookRequest()`, the `PaymentIntentWebhook` job, payment creation | **real**, on a migrated and seeded database; the queue is `sync`, as in the project's `phpunit.xml` |
| Stripe API: `GET /v1/payment_intents/{id}`, `GET /v1/charges/{id}` | fake: a `succeeded` PaymentIntent with `metadata.payment_hash`, and its charge |
| The customer | approved at the bank and never came back to the return URL (nothing calls the return route) |

## The finding

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

## Result at 493c388 (v5-develop, 2026-10-10)

| test | input | HTTP | what the job did | payment |
|---|---|---|---|---|
| `test_ideal_webhook_via_route_creates_no_payment_current_behaviour` | signed `payment_intent.succeeded` for an iDEAL PaymentIntent, posted to the route | 200 | fetched the PaymentIntent and the charge, logged a Stripe gateway success | **none**, invoice balance unchanged |
| `test_ideal_webhook_creates_no_payment_current_behaviour` | the same PaymentIntent, job run directly | — | same | **none**, invoice balance unchanged |
| `test_sepa_webhook_creates_completed_payment_control` | the same path for a `sepa_debit` PaymentIntent | — | same | COMPLETED, type SEPA |
| `test_ideal_webhook_creates_completed_payment_if_fixed` (group `if-fixed`) | iDEAL; expects a COMPLETED payment | — | — | fails today |

Default run (`--exclude-group if-fixed`): 3 tests OK. `--group if-fixed`: 1 failure, as expected while the bug is present.
