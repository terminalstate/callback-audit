import crypto from "node:crypto";
import { lemonSqueezySetup } from "@lemonsqueezy/lemonsqueezy.js";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { lemonSqueezyWebhook } from "../app/src/payment/lemonSqueezy/webhook";

// A credits purchase (one-time order) by a Lemon Squeezy customer. Lemon Squeezy's API is the only thing faked: GET /v1/customers/:id
// answers the Customer object, whose `urls.customer_portal` "Will be `null` if the customer has not bought a subscription in your store"
// (https://docs.lemonsqueezy.com/api/customers/the-customer-object).
function customerResponse(id: string, customerPortal: string | null) {
  return {
    jsonapi: { version: "1.0" },
    links: { self: `https://api.lemonsqueezy.com/v1/customers/${id}` },
    data: {
      type: "customers",
      id,
      attributes: {
        store_id: 1, name: "Stand Buyer", email: "buyer@example.test", status: customerPortal ? "subscribed" : "none",
        city: null, region: null, country: "NL", total_revenue_currency: 1000, mrr: 0, status_formatted: "", country_formatted: "",
        total_revenue_currency_formatted: "", mrr_formatted: "", urls: { customer_portal: customerPortal },
        created_at: "2026-10-19T00:00:00.000000Z", updated_at: "2026-10-19T00:00:00.000000Z", test_mode: true,
      },
      relationships: {},
      links: { self: `https://api.lemonsqueezy.com/v1/customers/${id}` },
    },
  };
}

function orderCreated(customerId: number, orderId: string) {
  return JSON.stringify({
    meta: { event_name: "order_created", custom_data: { user_id: "user-1" } },
    data: {
      type: "orders",
      id: orderId,
      attributes: { customer_id: customerId, status: "paid", first_order_item: { variant_id: 2003 }, order_number: 1001 },
    },
  });
}

async function deliver(body: string) {
  const signature = crypto.createHmac("sha256", "stand-webhook-secret").update(body).digest("hex");
  const request = { body: Buffer.from(body), get: (h: string) => (h.toLowerCase() === "x-signature" ? signature : undefined) };
  let status = 0;
  const response = { status(code: number) { status = code; return this; }, json() { return this; } };
  const user = { update: vi.fn(async () => ({})) };
  const processedWebhookEvent = { create: vi.fn(async () => ({})), delete: vi.fn(async () => ({})) };
  await lemonSqueezyWebhook(request as any, response as any, { entities: { User: user, ProcessedWebhookEvent: processedWebhookEvent } } as any);
  return { status, user };
}

describe("Lemon Squeezy order_created for a credits purchase", () => {
  beforeEach(() => {
    lemonSqueezySetup({ apiKey: "stand-api-key" });
    vi.stubGlobal("fetch", vi.fn(async (url: string) => {
      const id = String(url).split("/customers/")[1];
      const portal = id === "301" ? "https://stand.lemonsqueezy.com/billing?expires=1&signature=x" : null;
      return new Response(JSON.stringify(customerResponse(id, portal)), { status: 200, headers: { "Content-Type": "application/vnd.api+json" } });
    }));
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});
  });

  it("control: a customer who also has a subscription gets the 10 credits", async () => {
    const { status, user } = await deliver(orderCreated(301, "9001"));
    expect(status).toBe(200);
    expect(user.update).toHaveBeenCalledWith(expect.objectContaining({ data: expect.objectContaining({ credits: { increment: 10 } }) }));
  });

  it("a customer without a subscription gets the 10 credits", async () => {
    const { status, user } = await deliver(orderCreated(302, "9002"));
    expect(status).toBe(200);
    expect(user.update).toHaveBeenCalledWith(expect.objectContaining({ data: expect.objectContaining({ credits: { increment: 10 } }) }));
  });
});
