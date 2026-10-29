# Harness: Liberapay, a failed Stripe transfer inside the webhook is never retried

One pytest module that runs in the test setup of [liberapay.com](https://github.com/liberapay/liberapay.com)
(`tests/py`, real Postgres, the project's own `Harness`), plus the two candidate fixes as patches.

```
LIBERAPAY_DIR=<checkout> PYTHON=<python> PSQL=<psql> DATABASE_URL="host=... port=... user=... dbname=..." ./run.sh
```

Needs Python 3.12 with `requirements_base.txt` and pytest, vcrpy, html5lib, Faker, and PostgreSQL. `run.sh` checks out
`master` as of 2026-10-29 (`LIBERAPAY_COMMIT=...` for another), recreates the schema with `recreate-schema.sh test`, runs
the module before any fix, then with each fix, together with `test_payins.py`, `test_schedule.py` and `test_cron.py`,
and restores the checkout at the end.

## What is real and what is not

| Part | |
|---|---|
| `www/callbacks/stripe.spt`, `settle_charge`, `execute_transfer`, the payin/transfer/donation tables, all payment cron jobs registered in `liberapay/main.py` | **real**, project code |
| Stripe webhook signature | real: HMAC-SHA256 of the payload with the test secret, checked by `stripe.Webhook.construct_event` |
| Stripe API | `unittest.mock.patch` of `stripe.Transfer.create`, `stripe.BalanceTransaction.retrieve`, `stripe.Charge.retrieve` (as `TestRefundsStripe` does); VCR in `none` mode, so any other HTTP call fails the test |
| The failure | the first `Transfer.create` raises `stripe.InvalidRequestError` (missing `transfers` capability), every later call succeeds |

Each test delivers the event like Stripe (again only after a non-2xx), then runs every payment cron job, then opens the
payer's pages, and checks the end state.

## Result

Run on 2026-10-29 (Python 3.12.15, PostgreSQL 17.11, liberapay.com `9f41a3a`):

```
== before: harness
SEPA: webhook answers [200]
  Transfer.create calls in total: 1
  final state: {'payin_status': 'succeeded', 'transfer_status': 'pending', 'transfer_remote_id': None, ..., 'paid_in_advance': None, 'donation_offered_for_renewal': False, 'automatic_renewal_scheduled': False}
card: charge.succeeded (uncaptured) answered [200]
  Transfer.create calls: 0
PASSED ...::test_control_transfer_succeeds_first_time
FAILED ...::test_card_transfer_failure_is_retried
FAILED ...::test_sepa_transfer_failure_is_retried

== with fix-transfer-retry-webhook.patch: harness
SEPA: webhook answers [500, 200]   -> transfer succeeded, paid_in_advance 51.65 EUR, renewal scheduled
card: still not retried            -> 1 failed, 2 passed
existing modules: 85 passed

== with fix-transfer-retry-cron.patch: harness
3 passed (SEPA and card both retried by the hourly job)
existing modules: 85 passed
```

The control case (no failure) shows what the failed case should end with: transfer `succeeded`, 51.65 EUR paid in
advance, the donation offered for renewal and an automatic renewal scheduled.
