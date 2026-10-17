# Stand: Stripe charge.refunded records a refund made in EverShop a second time (evershopcommerce/evershop)

A reproduction in the project's own jest suite, at the v2.3.0 release and at `dev` as of 2026-10-17.

## What it shows

An admin refund in EverShop calls `stripe.refunds.create` and records the refund under the refund's `re_…` id. Stripe then
sends `charge.refunded` for the same refund. The webhook takes the refund from `charge.refunds?.data?.[0]` and, when that list is
missing, records the refund under `charge.id` with `charge.amount_refunded`.

Since API version 2022-11-15, Stripe does not include `refunds` in Charge objects unless it is expanded, and webhook payloads
follow the API version of the endpoint. So the fallback runs: the refund is recorded again under `ch_…`, with the cumulative
`amount_refunded`. The duplicate check in `recordRefund()` compares ids only, and `re_…` is not `ch_…`.

- Partial refund of 30 on a 100 order: two refund rows, 30 + 30. The refunded total that the status and the refundable remainder
  are computed from becomes 60.
- Full refund: 200 refunded on a 100 capture, and `order_refunded` is emitted twice (a second "order refunded" email).

## Pinned source

- Repository: `https://github.com/evershopcommerce/evershop`
- Commit: `f33f72cd02bc20fd5d9b2b111bdda46b79b77200` (tag `v2.3.0`). The same run at `dev` `e68b06a54f50f42548d2014fb2212cc8f7626869`
  (2026-10-17) gives the same result; the files below did not change between the two.
- stripe-node: 21.0.1, as resolved by `package-lock.json`

Code involved (line numbers at the pinned commit):

| Step | Location |
|---|---|
| Admin refund: Stripe call, returns the `re_…` id | `packages/evershop/src/modules/stripe/bootstrap.ts` L129-146 |
| Core refund: records it under that id | `packages/evershop/src/modules/oms/services/refundOrder.ts` L94-108 |
| Duplicate check by id, insert, `order_refunded` | `packages/evershop/src/modules/oms/services/recordRefund.ts` L83, L110-122, L134-145 |
| `isRefundAlreadyRecorded()` | `packages/evershop/src/modules/oms/services/refundStatus.ts` L73-78 |
| `charge.refunded`: `charge.refunds?.data?.[0]`, else `charge.id` and `charge.amount_refunded` | `packages/evershop/src/modules/stripe/api/stripeWebHook/[bodyJson]webhook.ts` L99-128 |

## Test

One new file, `packages/evershop/src/modules/stripe/tests/unit/chargeRefundedWebhook.test.js`, next to the module's other unit
tests. No existing file is modified. The tests describe the expected behaviour, so they fail while the bug is present.

| Test | At the pinned commit |
|---|---|
| records a refund made in the Stripe Dashboard once | passes (control: a refund made outside EverShop, delivered twice, is recorded once) |
| does not record a partial refund a second time | fails: refund rows `re_test_admin` 30 and `ch_test_1` 30 |
| does not report a full refund twice | fails: 200 refunded on a 100 capture |

The event is built as Stripe sends it on current API versions (no `refunds` list) and signed with stripe-node's
`webhooks.generateTestHeaderString`, so the handler's real signature check runs.

## How to run

```sh
bash run.sh [WORK_DIR]                                                        # v2.3.0
EVERSHOP_COMMIT=e68b06a54f50f42548d2014fb2212cc8f7626869 bash run.sh [WORK_DIR]   # dev, 2026-10-17
```

`WORK_DIR` must be new or empty; a temporary directory is used when it is omitted. The script fetches the commit, runs
`npm ci --ignore-scripts` (this skips only the root `prepare` script, `husky install`), copies the test file in (it refuses to
overwrite a file), runs `npm run compile` and `npm run compile:db` as the repository's jest config expects (it runs the compiled
tests in `dist`), and runs jest on `packages/evershop/dist/modules/stripe`.

Requirements: bash, git, Node.js 22 with npm, about 1.5 GB of disk. Network: GitHub and the npm registry. The run takes about
two minutes.

By hand, in a checkout after `npm ci`:

```sh
cp tests/packages/evershop/src/modules/stripe/tests/unit/chargeRefundedWebhook.test.js <checkout>/packages/evershop/src/modules/stripe/tests/unit/
cd <checkout> && npm run compile && npm run compile:db
ALLOW_CONFIG_MUTATIONS=true NODE_OPTIONS=--experimental-vm-modules node node_modules/jest/bin/jest.js packages/evershop/dist/modules/stripe
```

## Result

`result-f33f72c.txt` (v2.3.0) and `result-e68b06a.txt` (dev, 2026-10-17), both from an end-to-end `bash run.sh` in a new
directory: the control passes, the two refund tests fail, the module's other 14 tests pass. Verdict: reproduced.

## What is real and what is stubbed

Real, unchanged: the webhook handler, `recordRefund()` and the refund-status helpers, stripe-node's signature check.

Stubbed:
- **The database.** `@evershop/postgres-query-builder` and the connection are replaced by an in-memory `payment_transaction`
  table that answers the queries these code paths make (order lookup by payment intent, refunded sum, transaction list, upsert).
- **Config** (a test endpoint secret), **settings**, **logging**, **event emission** (recorded), the **order activity log** and
  **`updatePaymentStatus`** (recorded).

The admin refund is represented by calling `recordRefund()` with a `re_…` id, which is what `refundOrder()` does after the
Stripe call. Stripe's API is not called.

## Limitations

- No Postgres, HTTP server or Stripe account is involved. A query the fake table does not recognise returns no rows; a change in
  the queries could make the stand pass or fail for reasons unrelated to the finding.
- The precondition is a webhook endpoint on API version 2022-11-15 or later, which is what the Stripe Dashboard creates today.
  An endpoint pinned to an older version still receives `refunds` in the Charge, and then the webhook records the latest refund
  under its own `re_…` id (a duplicate is then avoided for the latest refund only).

## Files

| File | Content |
|---|---|
| `tests/packages/evershop/src/modules/stripe/tests/unit/chargeRefundedWebhook.test.js` | The test |
| `run.sh` | Fetch, install, add the test, compile, run, summarise |
| `result-f33f72c.txt` | Result and versions of the run at v2.3.0 |
| `result-e68b06a.txt` | Result and versions of the run at `dev`, 2026-10-17 |
