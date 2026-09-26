# A real "orders stuck in pending" bug, and the audit that finds it

*A worked case for [callback-audit](https://github.com/terminalstate/callback-audit): take a
current, public bug in a widely-installed payment plugin, reproduce it against the plugin's own
code, and point the tool at the result. Everything here is public and reproducible — no private
data, no live Stripe account, no database.*

## TL;DR

In **woocommerce-gateway-stripe 11.0.0** (the official WooCommerce Stripe gateway, 700k+ active installs on WordPress.org),
a webhook that **fails signature validation** — a rotated signing secret, a clock more than five
minutes off, an empty secret — is answered with **HTTP 204**. Stripe treats any 2xx as *delivered*
and never retries. So the callback that would have moved the order to a terminal state is dropped,
the order sits in **`pending`** indefinitely, and Stripe's own dashboard shows the payment
**succeeded**. There is exactly one narrow exception where the plugin answers 400 instead (below).

By HTTP status the endpoint looks **100% healthy** — every response is a 2xx. The loss is only
visible when you cross-check *your* order states against the *provider's* view. That cross-check is
what callback-audit does: on the reproduced data it flags the problem at **stations 5 and 7**
(and station 3, once its signature pattern is fixed — see the last section), while the by-response-code
checks stay green.

## The bug, in the plugin's own code

`includes/class-wc-stripe-webhook-handler.php`, method `check_for_webhook()` (v11.0.0):

```php
if ( WC_Stripe_Webhook_State::VALIDATION_SUCCEEDED !== $validation_result ) {
    WC_Stripe_Logger::error( 'Webhook validation failed (' . $validation_result . ')', [ ... ] );
    WC_Stripe_Webhook_State::set_last_webhook_failure_at( time() );

    if ( WC_Stripe_Webhook_State::VALIDATION_FAILED_SIGNATURE_MISMATCH === $validation_result
         && $this->has_duplicate_webhooks_setup() ) {
        // ... only when MORE THAN ONE webhook is configured:
        status_header( 400 );   // tell Stripe the endpoint is misconfigured
        exit;
    }

    // Every other validation failure — including a plain signature mismatch on a
    // single-webhook store, an out-of-range timestamp, or an empty secret:
    // "A webhook endpoint must return a 2xx HTTP status code to prevent future
    //  webhook delivery failures." @see https://docs.stripe.com/webhooks#acknowledge-events-immediately
    status_header( 204 );
    exit;
}
```

The 204 is deliberate: the plugin does not want Stripe to disable the endpoint over a transient
problem, so it acknowledges even what it rejected. The cost is that a **persistent** validation
failure — the usual one being a **rotated secret** where the dashboard and the plugin setting drift
apart — is now silent. Stripe sees 204, marks the event delivered, and stops. The 400 branch that
*would* make Stripe surface the misconfiguration only fires when the store has **more than one**
webhook configured (`has_duplicate_webhooks_setup()`); the common single-webhook store never gets it.

This is not hypothetical wording. Shop owners hit exactly this shape — paid orders left at pending
after a plugin update or a secret change — in the plugin's own tracker and the WordPress.org forum
through 2025–2026.

## Why it hides

Three facts line up so that nothing obvious complains:

1. **204 is a 2xx.** Any monitor that watches HTTP status — the plugin's own health box, an uptime
   check, an access-log error-rate alert — sees success.
2. **Stripe marks it delivered.** From the sender side the event is done; there is no retry, no
   dead-letter, nothing to notice later.
3. **The order simply never changes.** No error is thrown in the order's lifecycle; it stays in the
   state it was created in. Nobody is watching the *age* of pending orders, so days pass.

The only place the truth exists is the disagreement between two records: your `pending` order and
Stripe's `succeeded` payment. You have to join them to see it.

## Reproduction — against the plugin's real handler

No database and no live Stripe account are needed to reproduce the mechanism, because the mechanism
lives entirely in the request/response path. A small harness runs the **real** v11.0.0
`check_for_webhook()` under PHP's built-in server with WordPress stubbed to memory, and drives real
HTTP POSTs at it:

```
GOOD signature  -> HTTP 200  (validation passes, order processing runs)
WRONG signature -> HTTP 204  (validation fails, processing never runs)
```

`generate.py` then plays a small shop for 14 days: ~7 orders a day, each producing one webhook
delivery **posted through that real handler**. On days 7–8 the store has rotated its Stripe signing
secret but the plugin still holds the previous one, so every delivery in that window is signed with
the new secret and validated against the old:

```
orders = 96   http codes from the real handler = { 200: 81, 204: 15 }   stuck (204) = 15
```

Every status code in the dataset came out of the plugin's actual code. The 15 orders whose webhook
got 204 are written as `pending`; Stripe's view (`events.csv`) shows all 96 as `succeeded`.

## What the audit shows

Run on the reproduced exports:

```
callback-audit \
  --payments payments.csv --terminal succeeded,failed,canceled,refunded \
  --events events.csv \
  --inbound inbound.csv --path-filter wc_stripe \
  --app-log app.log
```

The report:

| Station | Check | Verdict |
|---|---|---|
| 1 | sent vs received per day | **ok** — counts agree |
| 2 | inbound response codes per day | **ok** — no elevated non-2xx share |
| 5 | provider terminal, local non-terminal | **SUSPECT** — 15 payments terminal at the provider, non-terminal locally (oldest 6d 23h ago) |
| 7 | age of non-terminal payments | **SUSPECT** — oldest pending is 6d 23h old; 15 older than 24h |

That is the whole point in two lines. **Stations 1 and 2 are green** — by response code the endpoint
is perfect, because 204 is a 2xx. **Stations 5 and 7 are red** — the cross-check against the
provider's view, and the simple "how old is your oldest pending order", both find the 15 stranded
payments and hand you their ids to trace.

## The tool improvement this surfaced

On the first run, the station-3 app-log check was **silent** — "no lines matched the signature-failure
pattern in 96 log lines" — even though the log contains 15 real lines:

```
ERROR Webhook validation failed (signature_mismatch)
```

The plugin writes `signature_mismatch` with an **underscore**; callback-audit's default pattern only
matched `signature mismatch` with a space. A real log wording the default didn't cover. The one-line
fix (now on `main`) widens the separator to `[_ ]`, with a regression test
pinned to the plugin's exact wording (`tests/test_woocommerce_stripe_pattern.py`). With it, the same run — no custom flags — also lights up
station 3:

```
| 3 | signature verification failures | SUSPECT | 15 signature failures, 15.6% of inbound requests |
```

All 47 tests pass. This is the useful shape of a case study: the tool caught a real bug through the
provider cross-check, and the real bug made the tool a little sharper.

## How to run this on your own shop

callback-audit reads read-only exports; it connects to nothing. Two queries and one command:

```sql
-- payments.csv
select id, created_at, updated_at, status, 'stripe' as provider
from   ...orders...  where created_at > now() - interval '30 days';
```

Export Stripe's own view of the same window from the Dashboard (Payments → export, or the events
export) as `events.csv` with `payment_id, at, status`. Then:

```
callback-audit --payments payments.csv --terminal succeeded,failed,canceled,refunded \
               --events events.csv
```

If station 5 or 7 is red, you have orders the provider considers done and you consider pending —
the exact footprint of a dropped callback. The oldest-pending age (station 7) needs only
`payments.csv`, so it is the cheapest check to run first.

## Provenance and honest limits

- Plugin **woocommerce-gateway-stripe v11.0.0** (version read from the plugin header); the quoted
  code is from `includes/class-wc-stripe-webhook-handler.php`.
- The reproduction exercises the real `check_for_webhook()` / `validate_request()` path with real
  HMAC-SHA256 verification. It does **not** stand up a database; that a failed validation leaves the
  order untouched is a direct consequence of the handler exiting (`status_header(204); exit;`)
  before any order code runs — the harness confirms processing is never reached.
- The dataset's volumes and dates are synthetic; **every HTTP status in it was produced by the real
  handler**, not written by hand.
- The 400-on-duplicate-webhooks branch is represented faithfully: the harness forces the common
  single-webhook configuration, which is the one that returns 204.
- Reproduce end to end: run the real handler under `php -S` with WordPress stubbed to memory, then drive
  webhook POSTs at it as described above. The full harness (stubs, router, generator) is short and self-contained.
