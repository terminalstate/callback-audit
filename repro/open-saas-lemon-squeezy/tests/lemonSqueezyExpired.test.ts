import crypto from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { lemonSqueezyWebhook } from "../app/src/payment/lemonSqueezy/webhook";

// The template's setup docs (lemon-squeezy.mdx, deploying.mdx) list order_created, subscription_created, subscription_updated and
// subscription_cancelled but not subscription_expired. When a cancelled subscription's grace period ends, Lemon Squeezy sends subscription_updated
// with status "expired" ("Customers should no longer have access", https://docs.lemonsqueezy.com/api/subscriptions/the-subscription-object).
// The user is still stored as cancel_at_period_end, which the template treats as having access.
async function deliver(body: string) {
  const signature = crypto.createHmac("sha256", "stand-webhook-secret").update(body).digest("hex");
  const request = { body: Buffer.from(body), get: (h: string) => (h.toLowerCase() === "x-signature" ? signature : undefined) };
  let status = 0;
  const response = { status(code: number) { status = code; return this; }, json() { return this; } };
  const user = { update: vi.fn(async () => ({})) };
  await lemonSqueezyWebhook(request as any, response as any, { entities: { User: user, ProcessedWebhookEvent: {} } } as any);
  return { status, user };
}

describe("Lemon Squeezy subscription_updated at the end of a cancelled subscription", () => {
  it("ends the user's access when the subscription expires", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    const body = JSON.stringify({
      meta: { event_name: "subscription_updated", custom_data: { user_id: "user-1" } },
      data: { type: "subscriptions", id: "7001", attributes: { customer_id: 302, status: "expired", variant_id: 2001 } },
    });
    const { status, user } = await deliver(body);
    expect(status).toBe(200);
    expect(user.update).toHaveBeenCalledWith(expect.objectContaining({ data: expect.objectContaining({ subscriptionStatus: "deleted" }) }));
  });
});
