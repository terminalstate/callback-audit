# Stand: Stripe webhooks verified only when the queued job runs (medusajs/medusa)

A reproduction with the project's own test setup, at the pinned commit and at the commit with a fix.

## What it shows

`POST /hooks/payment/:provider` answers `200` before anything is verified. It puts the parsed body, the raw body and the request headers on the event bus as a `payment.webhook_received` event (default `delay: 5000`, `attempts: 3`). The Stripe signature is checked only when the subscriber for that event runs. The check is stripe-node's `webhooks.constructEvent(raw, signature, webhookSecret)`, called without `tolerance` and without `receivedAt`. It therefore uses the library's 300 s default tolerance, measured against `Date.now()` at the time the job runs.

As a result, a valid delivery that Stripe has already seen acknowledged with `200` is rejected with "Timestamp outside the tolerance zone" if its job runs more than 300 s after Stripe signed it. The bus retries use the same stored header and fail the same way. Stripe does not resend a delivery that received a 2xx.

The tests show this with the project's own code and real signatures. Signatures come from stripe-node's `webhooks.generateTestHeaderString`, and verification is never mocked. Job time is simulated by moving a fake wall clock forward. The deliveries are not signed with an old timestamp.

## Pinned source

- Repository: `https://github.com/medusajs/medusa`
- Commit: `146c46b0ad1146b40595c8ef586c4d5890982603` (develop, package versions 2.21.2)
- stripe-node: 15.12.0, as resolved by `yarn.lock` for `@medusajs/payment-stripe` (`stripe@^15.5.0`)

Code involved (line numbers at the pinned commit):

| Step | Location |
|---|---|
| Body parser only, raw body kept | `packages/medusa/src/api/hooks/middlewares.ts` L3-9 |
| Queue, then `200` (no verification) | `packages/medusa/src/api/hooks/payment/[provider]/route.ts` L6-38 (emit L22-31, `sendStatus(200)` L37) |
| Job: rehydrate the Buffer, call the payment module | `packages/medusa/src/subscribers/payment-webhook.ts` L28-36 |
| Pass-through to the provider | `packages/modules/payment/src/services/payment-module.ts` L1589-1602, `packages/modules/payment/src/services/payment-provider.ts` L252-259 |
| Verification at job time | `packages/modules/providers/payment-stripe/src/core/stripe-base.ts` L692 → L801-813 (`constructEvent` L805-809) |
| 300 s default tolerance, `Date.now()` unless `receivedAt` is passed | stripe-node 15.12.0 `src/Webhooks.ts` L74, L389-399 |

## Tests

The stand adds two new test files. No existing file is modified.

**`packages/modules/providers/payment-stripe/src/core/__tests__/webhook-verification-delay.spec.ts`** sits next to `stripe-base.spec.ts` and builds the provider the same way, with `new StripeProviderService({}, options)`.

| Test | Shows |
|---|---|
| current behaviour: a delivery signed at receipt is accepted when its job runs 10 s later | The signature is fresh and real (`t=<receipt>,v1=<64 hex>`). `getWebhookActionAndData` returns `{action: "captured", data: {session_id, amount: 49}}`. |
| current behaviour: the same delivery is rejected when its job runs 301 s after receipt | The same payload object, with the same bytes and the same header, rejects with "An error occurred in constructWebhookEvent: Timestamp outside the tolerance zone". |

**`packages/medusa/src/api/hooks/__tests__/payment-webhook-verification-delay.spec.ts`** calls the exported route handler with a minimal request and response, the same style as other unit tests in `packages/medusa`. It also calls the exported subscriber.

| Test | Shows |
|---|---|
| current behaviour: only the raw-body parser is configured in front of the handler | `hooksRoutesMiddlewares` holds one entry for `/hooks/payment/:provider`: `bodyParser: {preserveRawBody: true}` and no `middlewares` list, so nothing but the body parser runs before the handler. |
| current behaviour: a Stripe-signed delivery is answered 200 and queued as received, without verification | Status 200. One `payment.webhook_received` event with `{delay: 5000, attempts: 3}` holding exactly `{provider, payload: {data, rawData, headers}}`. The payment module's `getWebhookActionAndData` is not called. Nothing records a verification result or a receipt time. |
| current behaviour: a delivery with a bogus signature is also answered 200 and queued | stripe-node itself rejects the header ("No signatures found matching the expected signature for payload"). The route still answers 200 and queues the delivery, and it does not call the payment module. |
| current behaviour: a job that runs 10 s after receipt accepts the delivery and starts the payment workflow | The full in-process path: route at T, event JSON round-trip (as BullMQ stores it), real subscriber at T+10 s, then `process-payment-workflow` started with `action: "captured"`. |
| current behaviour: a job that runs 301 s after receipt rejects the delivery on every attempt and never starts the workflow | The same path at T+301, T+302 and T+303 s (the three queued attempts). Each attempt throws "…Timestamp outside the tolerance zone.", and the workflow never starts. |
| if fixed: a job that runs 301 s after receipt accepts the delivery acknowledged at receipt | Marked `it.failing`. It expects acceptance at receipt + 301 s, so it fails today and the suite stays green. Once the code accepts that delivery, jest reports this test as an error and the run turns red. |

In jest's output, the `if fixed` test shows `✓` / `passed` today. For an `it.failing` test, that means its body failed, as declared.

## How to run

```sh
bash run.sh [WORK_DIR]                                   # develop at 146c46b
MEDUSA_REPO=https://github.com/terminalstate/medusa.git MEDUSA_COMMIT=b3693d8d314ae99c4e889d8c789ed4a2dc6b6924 bash run.sh [WORK_DIR]   # the fix
```

`WORK_DIR` must be new or empty, and a temporary directory is used when it is omitted. The script runs these steps:

1. Fetch the pinned commit from GitHub (`git fetch --depth 1 origin <sha>`) and check `HEAD`.
2. Run `corepack enable --install-directory <WORK_DIR>/bin yarn`. This leaves any global yarn installation alone. With `COREPACK_NPM_REGISTRY` set, corepack downloads yarn 3.2.1 (the version from `packageManager`) from the npm registry.
3. Run `yarn install --immutable` at the repository root.
4. Run `yarn turbo run build --filter='@medusajs/payment-stripe...'`. This builds `@medusajs/payment-stripe` and the 10 workspace packages it depends on (framework, utils, types, modules-sdk, orchestration, workflows-sdk, query, cli, deps, telemetry). The tests import those packages from `dist`, like the repository's unit tests do after `yarn build`.
5. Copy `tests/**` into the clone. The script refuses to overwrite any existing file, and `git status` afterwards shows only the two new files.
6. Run each file with its workspace's own jest config (`jest.config.js` in the package directory), the same jest binary the packages' `test` scripts use. It then prints the table below and the versions.

Requirements: bash, git, and Node.js 22 with corepack (the packages declare `>=22.22.0`). The run needs about 2.5 GB inside `WORK_DIR`, and the clone, corepack cache, yarn cache and logs all stay there. Network access goes to GitHub and the npm registry only, with yarn, turbo and Medusa telemetry switched off through environment variables. On 2 CPUs the end-to-end run took 2 min 36 s: install about 1 min, build about 1.5 min, tests about 5 s. The exit status is 0 when both jest runs are green.

To run the tests by hand in an existing checkout of the same commit (after `yarn install` and the build in step 4):

```sh
cp -R tests/. <checkout>/
cd <checkout>/packages/modules/providers/payment-stripe && ../../../../node_modules/.bin/jest --runTestsByPath src/core/__tests__/webhook-verification-delay.spec.ts
cd <checkout>/packages/medusa && ../../node_modules/.bin/jest --forceExit --runTestsByPath src/api/hooks/__tests__/payment-webhook-verification-delay.spec.ts
```

## Result at 146c46b

From an end-to-end `bash run.sh` in a new, empty directory (see `result-146c46b.txt` and `env.txt`):

| # | level | kind | jest | reading | test |
|---|---|---|---|---|---|
| 1 | provider | current behaviour | passed | holds | a delivery signed at receipt is accepted when its job runs 10 s later |
| 2 | provider | current behaviour | passed | holds | the same delivery is rejected when its job runs 301 s after receipt |
| 3 | route | current behaviour | passed | holds | only the raw-body parser is configured in front of the handler |
| 4 | route | current behaviour | passed | holds | a Stripe-signed delivery is answered 200 and queued as received, without verification |
| 5 | route | current behaviour | passed | holds | a delivery with a bogus signature is also answered 200 and queued |
| 6 | route->job | current behaviour | passed | holds | a job that runs 10 s after receipt accepts the delivery and starts the payment workflow |
| 7 | route->job | current behaviour | passed | holds | a job that runs 301 s after receipt rejects the delivery on every attempt and never starts the workflow |
| 8 | route->job | if fixed (it.failing) | passed | fails today, as expected while the bug is present | a job that runs 301 s after receipt accepts the delivery acknowledged at receipt |

Verdict: reproduced. Jest reported `Tests: 2 passed, 2 total` for payment-stripe and `Tests: 6 passed, 6 total` for medusa, and both exit codes were 0.

Versions: node v22.22.0, corepack 0.34.0, yarn 3.2.1, stripe-node 15.12.0, jest 29.7.0, @swc/jest 0.2.39, typescript 5.9.3, turbo 1.13.4.

## Result with the fix (b3693d8)

The same `run.sh`, end to end in a new directory, at the commit of the PR (`MEDUSA_COMMIT=b3693d8…`; see
`result-b3693d8.txt`). The route now records `receivedAt` and the provider checks the signature against it:

| # | test | result |
|---|---|---|
| 4 | a Stripe-signed delivery is answered 200 and queued as received | does not hold any more: the queued payload also has `receivedAt` |
| 7 | a job that runs 301 s after receipt rejects the delivery on every attempt | does not hold any more: the delivery is accepted |
| 8 | if fixed: a job that runs 301 s after receipt accepts the delivery | passes (jest reports the `it.failing` test as an error, as it should) |

The other five tests are unchanged, including the provider-level ones: a payload without `receivedAt` is still checked
against the current time.

## What is real and what is stubbed

These parts are the project's own code or library code, unchanged:
- the route handler and its middleware configuration;
- the `payment.webhook_received` subscriber, including its Buffer rehydration;
- `@medusajs/payment-stripe`, both from source for the provider tests and as the built package for the route-to-job tests;
- stripe-node signing and verification.

These parts are stubbed:
- **The containers.** `req.scope` and the subscriber's container resolve only what the code asks for, and any other key throws.
- **A recording event bus.**
- **A pass-through payment module.** Its `getWebhookActionAndData` does what `PaymentModuleService` and `PaymentProviderService` do at this commit: it picks `pp_<provider>` and forwards `payload`.
- **A recording workflow engine.**
- **A virtual mock of `@medusajs/core-flows`.** The subscriber imports it only for the workflow id string, so the mock avoids building core-flows.
- **The wall clock.** `jest.useFakeTimers` fakes only `Date`, and every timer stays real.
- **The bus serialization.** The route-to-job tests imitate the Redis/BullMQ JSON round trip with `JSON.parse(JSON.stringify(event))`.

## Checking that the "if fixed" test turns red

Before the fix was written, the route-to-job suite was run against two temporary patches, which were reverted afterwards and are not part of the stand. Patch A is what the PR does. After each provider change, `@medusajs/payment-stripe` was rebuilt.

- **Patch A: receipt time passed to the check.** The route adds `receivedAt: Date.now()` to `payload`, and `StripeBase.constructWebhookEvent` passes it as the sixth argument of `constructEvent`. The `if fixed` test then reports as an error, so the suite turns red. Two current-behaviour tests fail, as they should once the behaviour changes: the queued payload shape, and the rejection at 301 s.
- **Patch B: verification at the door only.** The route calls the payment module's `getWebhookActionAndData` before queuing and answers 400 if it throws. The `if fixed` test stays green, which is correct: the job still re-verifies with the job-time clock, so the delay problem remains. The two route tests about acknowledging without verification turn red.
- **Patches A and B together.** The `if fixed` test turns red.

The provider-level tests stayed green under all three patches. They describe the provider's behaviour for a payload that carries no receipt time. That is why the `if fixed` test sits in the route-to-job suite. A provider-only test cannot see a fix that records the receipt time in the route.

## Limitations

- No Redis, BullMQ worker, database or HTTP server is involved. Queue latency is represented only by the gap between receipt time and job time on the fake clock. The finding's precondition, a worker that reaches the job more than about 300 s after Stripe signed it, is assumed, not produced.
- The route is called directly with the request the framework's JSON parser would produce (`body` plus `rawBody`). The parser itself is covered by the framework's own `bodyparser.spec.ts`.
- A fix that changes how the payment module forwards the event, rather than the route, the subscriber or the provider, would not be seen by the pass-through stub.
- The event is a minimal `payment_intent.succeeded` with test identifiers. Its amount is 4900 in EUR minor units, which maps to 49.

## Files

| File | Content |
|---|---|
| `tests/packages/modules/providers/payment-stripe/src/core/__tests__/webhook-verification-delay.spec.ts` | Provider-level tests |
| `tests/packages/medusa/src/api/hooks/__tests__/payment-webhook-verification-delay.spec.ts` | Route-level tests, route-to-job tests and the `if fixed` test |
| `run.sh` | Clone, install, build, copy, run and summarise |
| `result-146c46b.txt` | Output summary of the end-to-end run at the pinned commit |
| `result-b3693d8.txt` | Output summary of the end-to-end run at the commit with the fix |
| `env.txt` | Tool and library versions of that run |
