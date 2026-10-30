# Harness: Open SaaS with Lemon Squeezy: credits without a subscription; access after a subscription expires

The template's `template/app/src/payment/lemonSqueezy/webhook.ts` runs under vitest with the real
`@lemonsqueezy/lemonsqueezy.js` SDK. Wasp's generated modules (`wasp/server`, `wasp/server/api`) and `@prisma/client`
are stand-ins in `mocks/`; only Lemon Squeezy's API is faked (`GET /v1/customers/:id`), and the request carries a real
HMAC `X-Signature`.
Reported in [wasp-lang/open-saas#755](https://github.com/wasp-lang/open-saas/issues/755).

```
bash run.sh [WORK_DIR]          # open-saas main as of 2026-10-28; OPENSAAS_COMMIT=… for another commit
```

Needs git, Node 20+ and npm (about 60 MB in `WORK_DIR`).

## What is real and what is not

| Part | |
|---|---|
| `lemonSqueezyWebhook`, `handleOrderCreated`, `processWebhookEventOnce` | **real** (template code, sparse checkout) |
| `@lemonsqueezy/lemonsqueezy.js` | real, 3.3.1 (the template asks for `^3.2.0`) |
| Lemon Squeezy API | `fetch` stub: the Customer object, `urls.customer_portal` set for customer 301 and `null` for 302 |
| `wasp/server`, `@prisma/client` | stand-ins: env values, `HttpError`, the Prisma error class |
| Database | `User.update` and `ProcessedWebhookEvent.create/delete` are `vi.fn()` |

## The finding

`order_created` fetches the customer portal URL before it writes the credits, and `fetchUserCustomerPortalUrl` throws
when `urls.customer_portal` is empty. Lemon Squeezy documents that field as "`null` if the customer has not bought a
subscription in your store". A customer whose only purchase is a credits pack therefore gets a 400 on every delivery,
including Lemon Squeezy's retries and a manual resend, and the credits are never added.

## Result

Run on 2026-10-20 (Node 22, vitest 4.1.12):

```
== open-saas at 5859df7 2026-10-19, @lemonsqueezy/lemonsqueezy.js 3.3.1
   ✓ control: a customer who also has a subscription gets the 10 credits
   × a customer without a subscription gets the 10 credits
     → expected 400 to be 200
      Tests  1 failed | 1 passed (2)
== with fix.patch
      Tests  2 passed (2)
```

`fix.patch` returns the portal URL as optional instead of throwing; `updateUserLemonSqueezyPaymentDetails` already
leaves the stored URL untouched when it is `undefined`.

## Second finding: a subscription that expires keeps its access

`tests/lemonSqueezyExpired.test.ts`. The template's setup docs (`lemon-squeezy.mdx`, `deploying.mdx`) tell the merchant to
send `order_created`, `subscription_created`, `subscription_updated` and `subscription_cancelled`, but not
`subscription_expired`. When a cancelled subscription's grace period ends, Lemon Squeezy then reports it as
`subscription_updated` with `status: "expired"`. `handleSubscriptionUpdated` only acts on `active` and `past_due`, so the
user stays `cancel_at_period_end`, which `isUserSubscribed` and the account page treat as subscribed.

Run on 2026-10-30 (Node 24, vitest 4.1.12), open-saas `c2c6285` (2026-10-28):

```
== subscription_updated with status expired (template docs list no subscription_expired)
     × ends the user's access when the subscription expires
       expected "vi.fn()" to be called with arguments: [ ObjectContaining{ data: ObjectContaining{ subscriptionStatus: "deleted" } } ]
```

With `expired` handled in `subscription_updated` (the same update `handleSubscriptionExpired` makes) the test passes.

