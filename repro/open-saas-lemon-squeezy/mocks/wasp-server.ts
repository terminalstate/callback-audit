// Stand-in for the module Wasp generates as `wasp/server`: only what the Lemon Squeezy webhook uses.
export const env = {
  LEMONSQUEEZY_WEBHOOK_SECRET: "stand-webhook-secret",
  LEMONSQUEEZY_API_KEY: "stand-api-key",
  LEMONSQUEEZY_STORE_ID: "1",
  PAYMENTS_HOBBY_SUBSCRIPTION_PLAN_ID: "2001",
  PAYMENTS_PRO_SUBSCRIPTION_PLAN_ID: "2002",
  PAYMENTS_CREDITS_10_PLAN_ID: "2003",
};
export class HttpError extends Error {
  statusCode: number;
  constructor(statusCode: number, message?: string) {
    super(message);
    this.statusCode = statusCode;
  }
}
export type MiddlewareConfigFn = (config: Map<string, unknown>) => Map<string, unknown>;
export type PrismaClient = any;
