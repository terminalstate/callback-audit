/**
 * Reproduction: a transient Stripe error during TRANSACTION_PROCESS_SESSION is answered with a final
 * CHARGE_FAILURE on the PaymentIntent id and without `time`, so Saleor stamps it with the time it
 * receives it. The later `payment_intent.succeeded` webhook is reported as CHARGE_SUCCESS with
 * `time = event.created`, which is earlier. Saleor ignores a success that is older than a failure with
 * the same pspReference (saleor/payment/transaction_item_calculations.py `_should_increse_amount`,
 * pinned by saleor/payment/tests/test_transaction_item_calculations.py
 * `test_with_charge_success_and_failure_events`), so the charge never counts.
 *
 * Only Stripe's HTTP (global fetch, which the app's Stripe client uses) and the outgoing Saleor GraphQL
 * call are faked; the Stripe webhook signature is computed for real and verified by the app's own
 * StripeWebhookSignatureValidator.
 */
import { type APL } from "@saleor/app-sdk/APL";
import { ok } from "neverthrow";
import Stripe from "stripe";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { mockedAppConfigRepo } from "@/__tests__/mocks/app-config-repo";
import { mockAdyenWebhookUrl, mockedSaleorAppId } from "@/__tests__/mocks/constants";
import { mockAuthData } from "@/__tests__/mocks/mock-auth-data";
import { mockStripeProblemReporter } from "@/__tests__/mocks/mock-stripe-problem-reporter";
import { getMockedRecordedTransaction } from "@/__tests__/mocks/mocked-recorded-transaction";
import { mockedStripePaymentIntentId } from "@/__tests__/mocks/mocked-stripe-payment-intent-id";
import { MockedTransactionRecorder } from "@/__tests__/mocks/mocked-transaction-recorder";
import { mockedSaleorApiUrl } from "@/__tests__/mocks/saleor-api-url";
import { getMockedTransactionProcessSessionEvent } from "@/__tests__/mocks/saleor-events/transaction-process-session-event";
import { getMockedPaymentIntentSucceededEvent } from "@/__tests__/mocks/stripe-events/mocked-payment-intent-succeeded";
import { mockStripeWebhookSecret } from "@/__tests__/mocks/stripe-webhook-secret";
import { StripeWebhookUseCase } from "@/app/api/webhooks/stripe/use-case";
import { WebhookParams } from "@/app/api/webhooks/stripe/webhook-params";
import { appContextContainer } from "@/lib/app-context";
import { StripeProblemReporter } from "@/modules/app-problems";
import { type ITransactionEventReporter } from "@/modules/saleor/transaction-event-reporter";
import { StripePaymentIntentsApiFactory } from "@/modules/stripe/stripe-payment-intents-api-factory";
import { StripeWebhookManager } from "@/modules/stripe/stripe-webhook-manager";
import { StripeWebhookSignatureValidator } from "@/modules/stripe/stripe-webhook-signature-validator";

import { TransactionProcessSessionUseCase } from "./use-case";

vi.mock("@saleor/app-problems", () => ({
  AppProblemsReporter: class {
    reportProblem() {
      return Promise.resolve({ isErr: () => false });
    }
    clearProblems() {
      return Promise.resolve({ isErr: () => false });
    }
  },
}));

const piId = mockedStripePaymentIntentId;

/** Run like the route does: inside a fresh request AppContext (route.ts wraps handlers with wrapRequest). */
const inRequest = (fn: () => Promise<Response>) =>
  appContextContainer.wrapRequest(fn as never)({} as never) as Promise<Response>;

/** The PaymentIntent as Stripe returns it once the card payment went through. */
const succeededPaymentIntent = (createdSec: number) => ({
  ...getMockedPaymentIntentSucceededEvent().data.object,
  id: piId,
  created: createdSec,
  currency: "usd",
  amount: 1000,
  amount_received: 1000,
  status: "succeeded",
  payment_method: null,
});

/**
 * Fake Stripe API. `paymentIntentGet` decides what GET /v1/payment_intents/:id answers; nothing else
 * is expected to be called.
 */
const installFakeStripe = (paymentIntentGet: () => Response) => {
  const calls: string[] = [];

  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(typeof input === "string" ? input : input.toString());

      calls.push(`${init?.method ?? "GET"} ${url.pathname}`);

      if (url.hostname === "api.stripe.com" && url.pathname === `/v1/payment_intents/${piId}`) {
        return paymentIntentGet();
      }

      throw new Error(`Unexpected request in test: ${init?.method} ${url.toString()}`);
    }),
  );

  return calls;
};

const stripeJson = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "request-id": "req_test" },
  });

const stripeRateLimited = () =>
  stripeJson(429, {
    error: {
      code: "rate_limit",
      message: "Too many requests hit the API too quickly.",
      type: "invalid_request_error",
    },
  });

describe("Transient Stripe error in TRANSACTION_PROCESS_SESSION vs the later payment_intent.succeeded", () => {
  const reportedToSaleor: Parameters<ITransactionEventReporter["reportTransactionEvent"]>[0][] = [];
  const saleorReporter = {
    reportTransactionEvent: vi.fn(async (variables) => {
      reportedToSaleor.push(variables);

      return ok({ createdEventId: "event-id" });
    }),
  } satisfies ITransactionEventReporter;

  let transactionRecorder: MockedTransactionRecorder;

  beforeEach(() => {
    reportedToSaleor.length = 0;
    transactionRecorder = new MockedTransactionRecorder();
    // Recorded by TRANSACTION_INITIALIZE_SESSION when the PaymentIntent was created.
    transactionRecorder.recordTransaction(mockAuthData, getMockedRecordedTransaction());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const processSession = () =>
    new TransactionProcessSessionUseCase({
      appConfigRepo: mockedAppConfigRepo,
      stripePaymentIntentsApiFactory: new StripePaymentIntentsApiFactory(),
      transactionRecorder,
    }).execute({
      appId: mockedSaleorAppId,
      saleorApiUrl: mockedSaleorApiUrl,
      event: getMockedTransactionProcessSessionEvent(),
      problemReporter: mockStripeProblemReporter,
    });

  const stripeWebhook = (event: Stripe.Event) => {
    const rawBody = JSON.stringify(event);
    const signatureHeader = Stripe.webhooks.generateTestHeaderString({
      payload: rawBody,
      secret: mockStripeWebhookSecret,
    });

    const apl = {
      get: vi.fn(async () => mockAuthData),
      set: vi.fn(),
      delete: vi.fn(),
      getAll: vi.fn(),
    } satisfies APL;

    return new StripeWebhookUseCase({
      apl,
      appConfigRepo: mockedAppConfigRepo,
      webhookEventVerifyFactory: (stripeClient) =>
        StripeWebhookSignatureValidator.createFromClient(stripeClient),
      transactionEventReporterFactory: () => saleorReporter,
      problemReporterFactory: () => new StripeProblemReporter({} as never),
      transactionRecorder,
      webhookManager: new StripeWebhookManager(),
      stripePaymentIntentsApiFactory: new StripePaymentIntentsApiFactory(),
    }).execute({
      rawBody,
      signatureHeader,
      webhookParams: WebhookParams.createFromWebhookUrl(mockAdyenWebhookUrl)._unsafeUnwrap(),
    });
  };

  it("current behaviour: the 429 becomes a final CHARGE_FAILURE (200, no time), the later success carries an older time", async () => {
    // The payment succeeded at Stripe a minute ago (the storefront calls transactionProcess after confirmPayment).
    const succeededAtSec = Math.floor(Date.now() / 1000) - 60;

    // 1. Storefront -> Saleor transactionProcess -> app; Stripe's GET answers 429 (not retried by stripe-node).
    const stripeCalls = installFakeStripe(stripeRateLimited);

    const processResponse = await inRequest(async () =>
      (await processSession())._unsafeUnwrap().getResponse(),
    );
    const processBody = await processResponse.json();
    // Saleor stores an event without `time` with the moment it receives the response.
    const failureStampedAt = Date.now();

    expect(stripeCalls).toStrictEqual([`GET /v1/payment_intents/${piId}`]);
    expect(processResponse.status).toBe(200);
    expect(processBody.result).toBe("CHARGE_FAILURE");
    expect(processBody.pspReference).toBe(piId);
    expect(processBody).not.toHaveProperty("time");

    // 2. Stripe -> app: payment_intent.succeeded, correctly signed.
    vi.unstubAllGlobals();
    installFakeStripe(() => stripeJson(200, succeededPaymentIntent(succeededAtSec)));

    const event = getMockedPaymentIntentSucceededEvent();

    event.created = succeededAtSec;
    Object.assign(event.data.object, succeededPaymentIntent(succeededAtSec));

    const webhookResponse = await inRequest(async () =>
      (await stripeWebhook(event))._unsafeUnwrap().getResponse(),
    );

    // The app answers 200 to Stripe: Stripe will never send this event again.
    expect(webhookResponse.status).toBe(200);
    expect(reportedToSaleor).toHaveLength(1);

    const success = reportedToSaleor[0];

    expect(success.type).toBe("CHARGE_SUCCESS");
    expect(success.pspReference).toBe(piId);
    expect(new Date(success.time).getTime()).toBe(succeededAtSec * 1000);

    // Same pspReference, success older than the failure: Saleor's recalculation counts the failure, charged = 0.
    expect(new Date(success.time).getTime()).toBeLessThan(failureStampedAt);
  });

  it("control: the webhook signature check is real, a tampered body is rejected and nothing is reported", async () => {
    installFakeStripe(() => stripeJson(200, succeededPaymentIntent(Math.floor(Date.now() / 1000))));

    const event = getMockedPaymentIntentSucceededEvent();
    const rawBody = JSON.stringify(event);
    const signatureHeader = Stripe.webhooks.generateTestHeaderString({
      payload: rawBody,
      secret: mockStripeWebhookSecret,
    });

    const response = await inRequest(async () => {
      const result = await new StripeWebhookUseCase({
        apl: { get: vi.fn(async () => mockAuthData), set: vi.fn(), delete: vi.fn(), getAll: vi.fn() },
        appConfigRepo: mockedAppConfigRepo,
        webhookEventVerifyFactory: (stripeClient) =>
          StripeWebhookSignatureValidator.createFromClient(stripeClient),
        transactionEventReporterFactory: () => saleorReporter,
        problemReporterFactory: () => mockStripeProblemReporter,
        transactionRecorder,
        webhookManager: new StripeWebhookManager(),
        stripePaymentIntentsApiFactory: new StripePaymentIntentsApiFactory(),
      }).execute({
        rawBody: rawBody.replace('"amount":1000', '"amount":1'),
        signatureHeader,
        webhookParams: WebhookParams.createFromWebhookUrl(mockAdyenWebhookUrl)._unsafeUnwrap(),
      });

      return result.isOk() ? result.value.getResponse() : result.error.getResponse();
    });

    expect(response.status).toBe(400);
    expect(reportedToSaleor).toHaveLength(0);
  });

  it.fails("if fixed: a transient Stripe error is not reported as a final failure on the PaymentIntent id", async () => {
    installFakeStripe(stripeRateLimited);

    const processResponse = await inRequest(async () => {
      const processResult = await processSession();

      return processResult.isOk()
        ? processResult.value.getResponse()
        : processResult.error.getResponse();
    });
    const body = processResponse.ok ? await processResponse.json() : {};

    // Either a non-2xx answer (Saleor keeps the transaction as it was and the storefront can retry),
    // or a result that does not carry the PaymentIntent id (it then cannot mask the webhook's success).
    expect(processResponse.ok === false || body.pspReference !== piId).toBe(true);
  });
});
