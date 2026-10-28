# Harness: Saleor Stripe app, a transient Stripe error hides a later successful charge

One vitest file that runs in the Stripe app's own unit project (`apps/stripe` in
[saleor/apps](https://github.com/saleor/apps)), next to the app's tests for `TRANSACTION_PROCESS_SESSION`.
Reported in [saleor/apps#2448](https://github.com/saleor/apps/issues/2448).

```
bash run.sh [WORK_DIR]          # saleor/apps main as of 2026-10-28; SALEOR_APPS_COMMIT=… for another commit
```

Needs git and Node 22 or 24 with corepack (pnpm comes from the repo's `packageManager`); about 1 GB in `WORK_DIR`.
`run.sh` clones the pinned commit, installs the locked dependencies of the Stripe app, copies the test in and runs it.

## What is real and what is not

| Part | |
|---|---|
| `TransactionProcessSessionUseCase`, `StripeWebhookUseCase`, `StripePaymentIntentHandler`, `StripePaymentIntentsApiFactory` (with the app's `stripe` client), `StripeWebhookSignatureValidator` | **real**, app code at the pinned commit |
| Stripe API | `fetch` stub for `GET /v1/payment_intents/:id`: 429 in the first step, the succeeded PaymentIntent in the second |
| Stripe webhook signature | real: `Stripe.webhooks.generateTestHeaderString` with the test config's secret, checked by the app |
| Saleor | the outgoing `transactionEventReport` is a `vi.fn()` that records what would be sent; config repo, APL and transaction recorder are the app's own test mocks |
| Saleor core's recalculation | not run here; the rule is in `saleor/saleor`, `saleor/payment/transaction_item_calculations.py` (`_should_increse_amount`), pinned by `test_with_charge_success_and_failure_events` |

## The finding

When `transactionProcess` can't fetch the PaymentIntent from Stripe (429, a 5xx after the SDK's retries, a socket
error), the app still answers 200 with a final `CHARGE_FAILURE` on the PaymentIntent id and no `time`, so Saleor stores
it with the time it receives it. The payment itself went through, so Stripe then sends `payment_intent.succeeded`, and the
app reports `CHARGE_SUCCESS` with `time = event.created`, which is earlier. Saleor does not count a success that is older
than a failure with the same pspReference. Stripe has the money, the transaction shows 0 charged, and the app answers 200
to the webhook, so Stripe does not send it again.

## Result

Run on 2026-10-28 (Node 22.23.4, vitest 3.1.1, stripe 18.1.0):

```
== saleor/apps at f001ac7 2026-10-28, stripe 18.1.0
 ✓ current behaviour: the 429 becomes a final CHARGE_FAILURE (200, no time), the later success carries an older time
 ✓ control: the webhook signature check is real, a tampered body is rejected and nothing is reported
 ✓ if fixed: a transient Stripe error is not reported as a final failure on the PaymentIntent id
      Tests  3 passed (3)
```

"if fixed" is an `it.fails` test: it passes while the bug is there. Once a transient error no longer ends up as a final
failure on the PaymentIntent id, it turns red, and so does "current behaviour".
