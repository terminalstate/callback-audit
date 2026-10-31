# Stand: payment states lost in lago-api webhooks (getlago/lago-api)

Three reproductions in the project's own RSpec suite, run at `main` as of 2026-10-17. The files these paths go through
(the Adyen webhook controller, `HandleEventService`, `Webhooks::ChargebackService`, the job) are unchanged on `main` as of 2026-10-30. Each goes through the real webhook
endpoint, the real signature check and the real jobs; only Flutterwave's verify endpoint is answered by WebMock.
The Adyen CHARGEBACK case is reported in [getlago/lago-api#6960](https://github.com/getlago/lago-api/issues/6960), the Flutterwave case in [#6974](https://github.com/getlago/lago-api/issues/6974).

## What it shows

1. **Adyen CHARGEBACK is never recorded.** The controller passes the `NotificationRequestItem` to the job, and
   `HandleEventService` parses it as such, but `Adyen::Webhooks::BaseService#event` expects the whole notification
   (`["notificationItems"].first`). Every CHARGEBACK job raises `NoMethodError`; with `retry: 0` it goes to the dead set,
   and Adyen has already received `[accepted]`. A second defect sits behind it: the payment is looked up by the
   notification's `pspReference`, which for dispute notifications is the dispute's reference; the disputed payment's
   reference is `originalReference` (Lago's own fixture has both).
2. **Flutterwave: a failed verification call drops a paid `charge.completed`.** `verify_transaction` turns any
   `LagoHttpClient::HttpError` (503, 429…) into `nil`, `call` then returns success, and `HandleEventService` rescues
   everything else. The job ends normally, nothing is retried, and Flutterwave got its 200. The invoice stays pending.
3. **A refund that fails after it succeeded is ignored** (Stripe `charge.refund.updated` → `failed`, Adyen `REFUND_FAILED`,
   GoCardless `failed`/`funds_returned`). `update_status` in all three refund services returns early when the credit
   note's refund is `succeeded`, so the failure never reaches the credit note and `credit_note.provider_refund_failure` is
   not sent.

## Pinned source

- Repository: `https://github.com/getlago/lago-api`
- Commit: `2520eba5856695c343a69e626d05a077f5ef9ba0` (`main`, 2026-10-17)
- Ruby 4.0.6, Rails 8.1.4, stripe 6.5.0, adyen-ruby-api-library 7.3.1, sidekiq 7.3.10, as resolved by `Gemfile.lock`

Code involved (line numbers at the pinned commit):

| Finding | Location |
|---|---|
| 1 | `app/controllers/webhooks_controller.rb` L77-95 (only the item is passed on, `[accepted]` at L90) |
| 1 | `app/services/payment_providers/adyen/handle_incoming_webhook_service.rb` L34 (job enqueued with the item) |
| 1 | `app/services/payment_providers/adyen/handle_event_service.rb` L68-72, L89-91 (item parsed directly, CHARGEBACK branch) |
| 1 | `app/services/payment_providers/adyen/webhooks/base_service.rb` L18-20 (`["notificationItems"].first`) |
| 1 | `app/services/payment_providers/adyen/webhooks/chargeback_service.rb` L10-13 (lookup by `pspReference`) |
| 2 | `app/services/payment_providers/flutterwave/webhooks/charge_completed_service.rb` L27-28, L89-125 (`rescue … nil` at L121-124) |
| 2 | `app/services/payment_providers/flutterwave/handle_event_service.rb` L23-27 (`rescue => e`, log only) |
| 3 | `app/services/credit_notes/refunds/stripe_service.rb` L72-78, `adyen_service.rb` L44-50, `gocardless_service.rb` L60-66 |
| 3 | `app/services/payment_providers/stripe/handle_event_service.rb` L49-55 (`charge.refund.updated`) |
| all | `app/jobs/application_job.rb` L4 (`sidekiq_options retry: 0`) |

## Tests

Three new files under `spec/requests/webhooks/`. No existing file is modified. Examples named "current behaviour" pass
while the bug is present. Examples named "if fixed" are marked `pending`: they fail today, and RSpec reports them as
failures ("Expected pending … to fail") once the bug is fixed. "control" examples show the same path working when the
bug's condition is absent.

| File | Example | Today |
|---|---|---|
| `adyen_chargeback_spec.rb` | current: the delivery is accepted and queued | passes |
| | current: the queued job raises on every run, the CHARGEBACK is never recorded | passes |
| | current: given the whole notification, the dispute's `pspReference` does not find the disputed payment | passes |
| | if fixed: a lost CHARGEBACK marks the invoice's dispute as lost | pending (`NoMethodError`) |
| `flutterwave_verification_error_spec.rb` | control: when the verify call succeeds, the invoice is paid | passes |
| | current: when the verify call answers 503 once, the paid charge is dropped and nothing is retried | passes |
| | if fixed: a transient verify failure is retried and the invoice ends up paid | pending |
| `refund_failed_after_success_spec.rb` | control (Stripe): a refund still pending is marked failed and the failure webhook is sent | passes |
| | current (Stripe): after success, the failure is ignored and no webhook is sent | passes |
| | if fixed (Stripe): the refund is marked failed and the failure webhook is sent | pending |
| | current (Adyen): `REFUND_FAILED` after a successful `REFUND` is ignored | passes |

The "if fixed" examples were checked against temporary patches, which are not part of the stand: (1) parsing the item
in `BaseService#event` and looking the payment up by `originalReference` (with the parsing change alone the example
stays pending, because of the lookup); (2) re-raising 429/5xx from `verify_transaction` and `retry_on
LagoHttpClient::HttpError` in the job; (3) letting `failed` through the early return in the three refund services
(the existing refund and event-handler specs, 96 examples, stay green with that change).

## How to run

```sh
bash run.sh [WORK_DIR]
```

Requirements: git, Ruby 4.0.6 with bundler 4.0.16, PostgreSQL 15+ with the `pg_partman` extension, Redis, and the build
tools for native gems (gcc, make, libpq-dev, libyaml-dev). `DATABASE_URL` (default
`postgres://lago:changeme@localhost:5432/lago_stand_test`) must point at a user that can create the database and its
extensions; `REDIS_HOST_PORT` defaults to `localhost:6379`. The other variables are those of the project's
`.github/workflows/spec.yml`. ClickHouse and Kafka are not needed. The script fetches the commit, runs `bundle install`
into `WORK_DIR`, generates the RSA keys, creates the database and loads the schema, copies the spec files in (it refuses
to overwrite a file) and runs `bundle exec rspec spec/requests/webhooks`.

By hand, in a checkout with the test database ready:

```sh
cp -R tests/spec/. <checkout>/spec/
cd <checkout> && bundle exec rspec spec/requests/webhooks --format documentation
```

## Result at 2520eba

`result-2520eba.txt`, from an end-to-end `bash run.sh` in a new directory: 11 examples, 0 failures, 3 pending. Every
"current behaviour" and "control" example passes; the three "if fixed" examples are pending. Verdict: reproduced.

## What is real and what is stubbed

Real: the routes and `WebhooksController`, the Adyen HMAC check (`Adyen::Utils::HmacValidator`), the Stripe signature check
(`Stripe::Webhook::Signature`), Flutterwave's `verif-hash` check, `InboundWebhooks`, every handler job and service, the
refund services, PostgreSQL and the factories of the suite.

Stubbed: the HTTP call to `api.flutterwave.com/v3/transactions/:id/verify` (WebMock), and the queue - jobs run through
ActiveJob's test adapter instead of Sidekiq, so the dead set itself is not shown; the stand shows that the job raises on
every run and that `ApplicationJob` sets `retry: 0`.

## Limitations

- Sidekiq is not running. That a job raising with `retry: 0` goes to the dead set is Sidekiq's documented behaviour and is
  read from the code, not produced here.
- The CHARGEBACK and REFUND_FAILED notifications are Adyen's sample shapes with test references; the Flutterwave and
  Stripe payloads are minimal events with test ids.
- For Stripe, the refund failure arrives as `charge.refund.updated`, the event Lago subscribes to. Stripe also announces
  failures with `refund.failed`, which Lago does not subscribe to.

## Files

| File | Content |
|---|---|
| `tests/spec/requests/webhooks/adyen_chargeback_spec.rb` | Finding 1 |
| `tests/spec/requests/webhooks/flutterwave_verification_error_spec.rb` | Finding 2 |
| `tests/spec/requests/webhooks/refund_failed_after_success_spec.rb` | Finding 3 |
| `run.sh` | Fetch, install, database, add the specs, run, summarise |
| `result-2520eba.txt` | Result and versions of the end-to-end run |
