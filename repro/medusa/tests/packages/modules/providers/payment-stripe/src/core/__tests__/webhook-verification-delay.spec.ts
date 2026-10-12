/**
 * Stripe webhook signature verification runs when the queued job runs.
 *
 * `POST /hooks/payment/:provider` answers 200 and only queues the parsed body,
 * the raw body and the headers. The Stripe signature is checked later, when the
 * `payment.webhook_received` job calls `getWebhookActionAndData`, which calls
 * stripe-node's `webhooks.constructEvent(raw, signature, webhookSecret)` with
 * no `tolerance` and no `receivedAt`. The default 300 s tolerance is therefore
 * measured against `Date.now()` at job time, not at receipt.
 *
 * These tests sign one `payment_intent.succeeded` delivery with stripe-node's
 * own `webhooks.generateTestHeaderString` (real HMAC-SHA256, timestamp = the
 * clock at receipt) and then move a fake wall clock forward to the moment the
 * queued job runs. Signature verification itself is not mocked.
 *
 * All identifiers and secrets below are test values.
 */
import type { ProviderWebhookPayload } from "@medusajs/framework/types"
import { PaymentActions } from "@medusajs/framework/utils"
import Stripe from "stripe"

import StripeProviderService from "../../services/stripe-provider"
import type { StripeOptions } from "../../types"

const WEBHOOK_SECRET = "whsec_test_webhook_delay_stand"

const options: StripeOptions = {
  apiKey: "sk_test_123",
  webhookSecret: WEBHOOK_SECRET,
}

// The moment Stripe signs the delivery and the route acknowledges it with 200.
const RECEIVED_AT_MS = Date.UTC(2026, 0, 15, 12, 0, 0)
const SECONDS = 1000

const SESSION_ID = "payses_test_webhook_delay"

const rawBody = JSON.stringify(
  {
    id: "evt_test_webhook_delay",
    object: "event",
    type: "payment_intent.succeeded",
    created: RECEIVED_AT_MS / 1000,
    livemode: false,
    data: {
      object: {
        id: "pi_test_webhook_delay",
        object: "payment_intent",
        amount: 4900,
        amount_received: 4900,
        currency: "eur",
        status: "succeeded",
        metadata: { session_id: SESSION_ID },
      },
    },
  },
  null,
  2
)

/**
 * Fake only the wall clock (`Date`, `Date.now()`); timers and ticks stay real.
 */
function useFakeClock(nowMs: number) {
  jest.useFakeTimers({
    now: nowMs,
    doNotFake: [
      "hrtime",
      "nextTick",
      "performance",
      "queueMicrotask",
      "requestAnimationFrame",
      "cancelAnimationFrame",
      "requestIdleCallback",
      "cancelIdleCallback",
      "setImmediate",
      "clearImmediate",
      "setInterval",
      "clearInterval",
      "setTimeout",
      "clearTimeout",
    ],
  })
}

describe("StripeBase: webhook signature is verified when the queued job runs", () => {
  let provider: StripeProviderService
  let signatureHeader: string
  let queuedPayload: ProviderWebhookPayload["payload"]

  beforeEach(() => {
    // Receipt: Stripe signs the delivery and the route answers 200.
    useFakeClock(RECEIVED_AT_MS)

    signatureHeader = new Stripe(
      "sk_test_123"
    ).webhooks.generateTestHeaderString({
      payload: rawBody,
      secret: WEBHOOK_SECRET,
      timestamp: Math.floor(Date.now() / 1000),
    })

    // The payload as the route queues it and as the payment.webhook_received
    // subscriber hands it to the provider (raw body as a Buffer).
    queuedPayload = {
      data: JSON.parse(rawBody),
      rawData: Buffer.from(rawBody),
      headers: {
        "content-type": "application/json",
        "stripe-signature": signatureHeader,
      },
    }

    provider = new StripeProviderService({}, options)
  })

  afterEach(() => {
    jest.useRealTimers()
  })

  it("current behaviour: a delivery signed at receipt is accepted when its job runs 10 s later", async () => {
    // A fresh, real signature: t = receipt time, v1 = HMAC-SHA256 hex.
    expect(signatureHeader).toMatch(
      new RegExp(`^t=${RECEIVED_AT_MS / 1000},v1=[0-9a-f]{64}$`)
    )

    jest.setSystemTime(RECEIVED_AT_MS + 10 * SECONDS)

    await expect(
      provider.getWebhookActionAndData(queuedPayload)
    ).resolves.toEqual({
      action: PaymentActions.SUCCESSFUL,
      data: { session_id: SESSION_ID, amount: 49 },
    })
  })

  it("current behaviour: the same delivery is rejected when its job runs 301 s after receipt", async () => {
    jest.setSystemTime(RECEIVED_AT_MS + 301 * SECONDS)

    await expect(
      provider.getWebhookActionAndData(queuedPayload)
    ).rejects.toThrow(
      "An error occurred in constructWebhookEvent: Timestamp outside the tolerance zone"
    )
  })
})
