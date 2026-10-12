/**
 * POST /hooks/payment/:provider and the payment.webhook_received job.
 *
 * The route answers 200 after queuing the parsed body, the raw body and the
 * headers on the event bus; nothing is verified before the 200. The Stripe
 * signature is verified only when the `payment.webhook_received` subscriber
 * runs, through `getWebhookActionAndData` -> stripe-node `constructEvent`
 * with the default 300 s tolerance measured against `Date.now()` at job
 * time. A valid delivery whose job runs more than 300 s after Stripe signed
 * it is therefore rejected after Stripe already received its 200.
 *
 * Real: the route handler and its middleware config, the subscriber, the
 * Stripe provider (`@medusajs/payment-stripe`, built from this checkout) and
 * stripe-node signing and verification. Stubbed: the containers
 * (`req.scope`, the subscriber's container), a recording event bus, a
 * pass-through payment module (it forwards `payload` to the provider like
 * PaymentModuleService and PaymentProviderService do) and a recording
 * workflow engine. Time is simulated with a fake wall clock.
 *
 * All identifiers and secrets below are test values.
 */
import {
  Modules,
  PaymentActions,
  PaymentWebhookEvents,
} from "@medusajs/framework/utils"
import StripeModuleProvider from "@medusajs/payment-stripe"
import Stripe from "stripe"

import paymentWebhookHandler, {
  config as paymentWebhookSubscriberConfig,
} from "../../../subscribers/payment-webhook"
import { hooksRoutesMiddlewares } from "../middlewares"
import { POST } from "../payment/[provider]/route"

// The subscriber imports @medusajs/core-flows only for the id of the workflow
// it hands to the workflow engine, which is a recording stub in this file.
// A virtual mock keeps the test independent of a core-flows build.
jest.mock(
  "@medusajs/core-flows",
  () => ({ processPaymentWorkflowId: "process-payment-workflow" }),
  { virtual: true }
)

const WEBHOOK_SECRET = "whsec_test_webhook_delay_stand"
const STRIPE_OPTIONS = { apiKey: "sk_test_123", webhookSecret: WEBHOOK_SECRET }

// Route parameter for the `stripe` service of a Stripe provider registered
// with id `stripe`, i.e. payment provider `pp_stripe_stripe`.
const PROVIDER_PARAM = "stripe_stripe"

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

const stripe = new Stripe("sk_test_123")

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

/** Signs `rawBody` the way Stripe does, at the current (fake) time. */
function signNow() {
  return stripe.webhooks.generateTestHeaderString({
    payload: rawBody,
    secret: WEBHOOK_SECRET,
    timestamp: Math.floor(Date.now() / 1000),
  })
}

type QueuedEvent = {
  message: { name: string; data: any }
  options: { delay?: number; attempts?: number }
}

function createRecordingEventBus() {
  const emitted: QueuedEvent[] = []

  return {
    emitted,
    emit: async (
      message: QueuedEvent["message"],
      options: QueuedEvent["options"]
    ) => {
      emitted.push({ message, options })
    },
  }
}

/**
 * A payment module whose `getWebhookActionAndData` forwards `payload` to the
 * `pp_stripe_stripe` provider, like PaymentModuleService and
 * PaymentProviderService do. The provider comes from the module provider
 * exported by @medusajs/payment-stripe.
 */
function createPaymentModule() {
  const StripeProviderService = (StripeModuleProvider.services as any[]).find(
    (service) => service.identifier === "stripe"
  )

  const providers: Record<string, any> = {
    pp_stripe_stripe: new StripeProviderService({}, STRIPE_OPTIONS),
  }

  return {
    getWebhookActionAndData: jest.fn(
      async (eventData: { provider: string; payload: unknown }) => {
        const providerId = eventData.provider.startsWith("pp_")
          ? eventData.provider
          : `pp_${eventData.provider}`

        return await providers[providerId].getWebhookActionAndData(
          eventData.payload
        )
      }
    ),
  }
}

function createResponse() {
  const res = {
    statusCode: undefined as number | undefined,
    body: undefined as unknown,
    status(code: number) {
      res.statusCode = code
      return res
    },
    send(body: unknown) {
      res.body = body
      return res
    },
    sendStatus(code: number) {
      res.statusCode = code
      return res
    },
  }

  return res
}

/**
 * Calls the real route handler with the request the framework hands it for
 * `POST /hooks/payment/stripe_stripe`: the JSON body parser configured with
 * `preserveRawBody: true` (see ../middlewares.ts) leaves the parsed body on
 * `req.body` and the exact bytes on `req.rawBody`.
 */
async function postWebhook(
  signature: string,
  {
    eventBus,
    paymentModule,
  }: {
    eventBus: ReturnType<typeof createRecordingEventBus>
    paymentModule: ReturnType<typeof createPaymentModule>
  }
) {
  const req = {
    params: { provider: PROVIDER_PARAM },
    body: JSON.parse(rawBody),
    rawBody: Buffer.from(rawBody),
    headers: {
      "content-type": "application/json",
      "stripe-signature": signature,
    },
    scope: {
      resolve: (key: string) => {
        switch (key) {
          case Modules.PAYMENT:
            return paymentModule
          case Modules.EVENT_BUS:
            return eventBus
          default:
            throw new Error(
              `Unexpected dependency resolved by the route: ${key}`
            )
        }
      },
    },
  }

  const res = createResponse()
  await POST(req as any, res as any)

  return res
}

describe("POST /hooks/payment/:provider", () => {
  beforeEach(() => {
    useFakeClock(RECEIVED_AT_MS)
  })

  afterEach(() => {
    jest.useRealTimers()
  })

  it("current behaviour: only the raw-body parser is configured in front of the handler", () => {
    expect(hooksRoutesMiddlewares).toEqual([
      {
        method: ["POST"],
        bodyParser: { preserveRawBody: true },
        matcher: "/hooks/payment/:provider",
      },
    ])
  })

  it("current behaviour: a Stripe-signed delivery is answered 200 and queued as received, without verification", async () => {
    const signature = signNow()
    const eventBus = createRecordingEventBus()
    const paymentModule = createPaymentModule()

    const res = await postWebhook(signature, { eventBus, paymentModule })

    expect(res.statusCode).toBe(200)
    expect(paymentModule.getWebhookActionAndData).not.toHaveBeenCalled()
    expect(eventBus.emitted).toHaveLength(1)

    const [{ message, options }] = eventBus.emitted
    expect(message.name).toBe(PaymentWebhookEvents.WebhookReceived)
    expect(options).toEqual({ delay: 5000, attempts: 3 })
    expect(message.data).toEqual({
      provider: PROVIDER_PARAM,
      payload: {
        data: JSON.parse(rawBody),
        rawData: Buffer.from(rawBody),
        headers: {
          "content-type": "application/json",
          "stripe-signature": signature,
        },
      },
    })
    // Only the request is queued: no verification result, no receipt time.
    expect(Object.keys(message.data).sort()).toEqual(["payload", "provider"])
    expect(Object.keys(message.data.payload).sort()).toEqual([
      "data",
      "headers",
      "rawData",
    ])
  })

  it("current behaviour: a delivery with a bogus signature is also answered 200 and queued", async () => {
    const bogusSignature = `t=${Math.floor(Date.now() / 1000)},v1=${"0".repeat(
      64
    )}`

    // stripe-node rejects this header for this body and secret...
    expect(() =>
      stripe.webhooks.constructEvent(rawBody, bogusSignature, WEBHOOK_SECRET)
    ).toThrow("No signatures found matching the expected signature for payload")

    const eventBus = createRecordingEventBus()
    const paymentModule = createPaymentModule()

    const res = await postWebhook(bogusSignature, { eventBus, paymentModule })

    // ...but the route acknowledges it and queues it all the same.
    expect(res.statusCode).toBe(200)
    expect(paymentModule.getWebhookActionAndData).not.toHaveBeenCalled()
    expect(eventBus.emitted).toHaveLength(1)
    expect(eventBus.emitted[0].message.name).toBe(
      PaymentWebhookEvents.WebhookReceived
    )
    expect(
      eventBus.emitted[0].message.data.payload.headers["stripe-signature"]
    ).toBe(bogusSignature)
  })
})

describe("POST /hooks/payment/:provider -> event bus -> payment.webhook_received job", () => {
  afterEach(() => {
    jest.useRealTimers()
  })

  /** Stripe signs and delivers at `atMs`; the route answers and queues. */
  async function receiveAt(atMs: number) {
    useFakeClock(atMs)

    const eventBus = createRecordingEventBus()
    const res = await postWebhook(signNow(), {
      eventBus,
      paymentModule: createPaymentModule(),
    })

    expect(res.statusCode).toBe(200)
    expect(eventBus.emitted).toHaveLength(1)

    return eventBus.emitted[0]
  }

  /**
   * Runs one attempt of the queued job at `atMs` with the real subscriber.
   * The Redis event bus (BullMQ) stores job data as JSON, so the subscriber
   * receives the raw body as a serialized Buffer and rehydrates it itself.
   */
  async function runJobAt(atMs: number, queued: QueuedEvent) {
    jest.setSystemTime(atMs)

    const message = JSON.parse(JSON.stringify(queued.message))
    const paymentModule = createPaymentModule()
    const workflowEngine = { run: jest.fn().mockResolvedValue({}) }

    const container = {
      resolve: (key: string) => {
        switch (key) {
          case Modules.PAYMENT:
            return paymentModule
          case Modules.WORKFLOW_ENGINE:
            return workflowEngine
          default:
            throw new Error(
              `Unexpected dependency resolved by the subscriber: ${key}`
            )
        }
      },
    }

    let error: Error | undefined
    try {
      await paymentWebhookHandler({
        event: { name: message.name, data: message.data, metadata: {} },
        container,
        pluginOptions: {},
      } as any)
    } catch (err) {
      error = err as Error
    }

    return { error, workflowRuns: workflowEngine.run.mock.calls }
  }

  it("current behaviour: a job that runs 10 s after receipt accepts the delivery and starts the payment workflow", async () => {
    const queued = await receiveAt(RECEIVED_AT_MS)

    expect(paymentWebhookSubscriberConfig.event).toBe(queued.message.name)

    const job = await runJobAt(RECEIVED_AT_MS + 10 * SECONDS, queued)

    expect(job.error).toBeUndefined()
    expect(job.workflowRuns).toEqual([
      [
        "process-payment-workflow",
        {
          input: {
            action: PaymentActions.SUCCESSFUL,
            data: { session_id: SESSION_ID, amount: 49 },
          },
        },
      ],
    ])
  })

  it("current behaviour: a job that runs 301 s after receipt rejects the delivery on every attempt and never starts the workflow", async () => {
    const queued = await receiveAt(RECEIVED_AT_MS)

    // The route queues `attempts: 3`; the Redis event bus retries a failed
    // job without backoff, each attempt with the same stored header.
    expect(queued.options.attempts).toBe(3)

    for (let attempt = 0; attempt < queued.options.attempts!; attempt++) {
      const job = await runJobAt(
        RECEIVED_AT_MS + (301 + attempt) * SECONDS,
        queued
      )

      expect(job.error?.message).toBe(
        "An error occurred in constructWebhookEvent: Timestamp outside the tolerance zone."
      )
      expect(job.workflowRuns).toEqual([])
    }
  })

  // Marked as failing: it fails on the current code, so the suite stays
  // green. Once a fix lets a delivery acknowledged at receipt pass
  // verification regardless of queue latency, this test passes and
  // `it.failing` reports it as an error, i.e. the suite turns red.
  it.failing(
    "if fixed: a job that runs 301 s after receipt accepts the delivery acknowledged at receipt",
    async () => {
      const queued = await receiveAt(RECEIVED_AT_MS)

      const job = await runJobAt(RECEIVED_AT_MS + 301 * SECONDS, queued)

      expect(job.error).toBeUndefined()
      expect(job.workflowRuns).toEqual([
        [
          "process-payment-workflow",
          {
            input: {
              action: PaymentActions.SUCCESSFUL,
              data: { session_id: SESSION_ID, amount: 49 },
            },
          },
        ],
      ])
    }
  )
})
