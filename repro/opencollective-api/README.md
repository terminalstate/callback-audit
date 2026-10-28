# Harness: Open Collective, editing a contribution while its SEPA/ACH/Bacs charge is processing loses the payment

One mocha file that runs in the test setup of [opencollective-api](https://github.com/opencollective/opencollective-api)
(real Postgres, the project's own fixtures and helpers), next to its Stripe webhook tests.

```
PGHOST=127.0.0.1 PGPORT=5432 bash run.sh [WORK_DIR]   # opencollective-api main as of 2026-10-28; OC_API_COMMIT=… for another commit
```

Needs git, Node 24 with npm and PostgreSQL 16 or newer (pgcrypto, pg_trgm, btree_gist; PostGIS is not needed) with
`psql`, `pg_restore`, `createdb`, `dropdb` in `PATH` and a `postgres` superuser without a password. About 1.5 GB in
`WORK_DIR`. `run.sh` fetches the pinned commit, installs the locked dependencies, restores the test database with the
project's `db:restore:test`, copies the test in and runs it twice. Redis, S3 and the FIDO metadata download are not
needed; their warnings in the output are expected.

## What is real and what is not

| Part | |
|---|---|
| `updateOrder` GraphQL mutation (v2), `updateSubscriptionDetails`, `/webhooks/stripe` route and `payment_intent.succeeded` handler, models, Postgres | **real**, project code at the pinned commit |
| The edit | sent through `graphqlQueryV2` as the contributor (the website offers "Update contribution amount" for `PROCESSING` contributions: `RecurringContributionsPopUp.js` in opencollective-frontend) |
| Stripe webhook signature | real: `stripe.webhooks.generateTestHeaderString` with `config.stripe.webhookSigningSecret`, checked by the route |
| Stripe API | `nock` for `GET /v1/balance_transactions/:id` (fees for the control case) |
| The order | `fakeOrder` with a SEPA payment method, `status: PROCESSING`, `data.stripePaymentIntent.id` set, as after a confirmed debit |

## The finding

While a recurring contribution paid by a delayed method has its charge in flight, the order is `PROCESSING`.
`updateOrder` has no check for that status, and changing the amount, tier or platform tip removes
`data.stripePaymentIntent` (`server/lib/subscriptions.ts`, `omit(order.data, ['stripePaymentIntent', 'needsConfirmation'])`).
When the debit settles, the webhook looks the order up only by that PaymentIntent id, finds nothing, logs at debug level
and answers 200, so Stripe does not resend it. The contributor has paid, no transaction is recorded and the order stays
`PROCESSING`. Even with the reference kept, the handler compares the PaymentIntent amount with the order's new
`totalAmount` and returns.

## Result

Run on 2026-10-28 (Node 24.21.0, PostgreSQL 17.11, opencollective-api `d04af8f`):

```
  stripe webhook: contribution edited while its delayed charge is PROCESSING
    ✔ control: without an edit, payment_intent.succeeded records the charge and activates the order
    ✔ current behaviour: after an amount edit, the same success is answered 200 and never recorded
  2 passing

    1) if fixed: a success for the charge confirmed before the edit is still recorded
  1 failing
      AssertionError: expected +0 to be above +0
```

With `updateOrder` refusing amount/tier/tip changes while the order is `PROCESSING` (two lines before the `PAUSED`
branch), the "if fixed" case passes and the control still passes.
