# Paid in Mollie, pending in WooCommerce: a failed status check that is acknowledged anyway

*A second worked case for [callback-audit](https://github.com/terminalstate/callback-audit), done the
same way as the [Stripe one](case-woocommerce-stripe-204.md): take a current bug in a
widely-installed payment plugin and reproduce it against the plugin's own code. Everything here is
public: no store data and no Mollie account.*

## TL;DR

A Mollie webhook carries nothing but a payment id; the store has to ask the Mollie API for the
status. In **Mollie Payments for WooCommerce 8.1.10** (100,000+ active installs on WordPress.org),
the default webhook URL answers **200 OK even when that request failed**: a timeout, a 5xx or 429
from the API, a DNS or TLS problem on the store's server. Mollie retries a webhook for 26 hours,
but only until it gets a 200, so this delivery is never retried. The customer has paid, and the
order stays in *Pending payment*.

The same plugin answers **400** in the same situation on its older WC-API webhook URL, and **500**
in another branch of the same REST callback. So the 200 here looks like an oversight rather than a
design choice.

## What Mollie expects

[Mollie's webhook documentation](https://docs.mollie.com/reference/webhooks) says:

- the webhook is a POST with a single `id` parameter; the store uses that id to fetch the payment
  status and acts on it;
- Mollie calls the webhook up to 10 times, at increasing intervals, until it gets a `200 OK`. It
  gives up after the 10th attempt, about 26 hours later;
- for an id the store doesn't know, Mollie recommends answering 200 anyway, so as not to leak
  information.

A 200 therefore means "done". It is right for an id the store doesn't know. It is wrong for a
payment the store knows but couldn't check.

## The code path

Links are to [`4d75849`](https://github.com/mollie/WooCommerce/tree/4d75849d6c72e8206a7cb5126585aebf57224b03)
on `dev/develop` (plugin version 8.1.10).

1. **The REST route is the default webhook URL.** The WC-API URL is used only when the REST URL is
   invalid or a filter turns it off
   ([`UrlMiddleware.php#L109-L113`](https://github.com/mollie/WooCommerce/blob/4d75849d6c72e8206a7cb5126585aebf57224b03/src/Payment/Request/Middleware/UrlMiddleware.php#L109-L113)).
2. **The REST callback ignores the result of processing**
   ([`RestApi.php#L184-L186`](https://github.com/mollie/WooCommerce/blob/4d75849d6c72e8206a7cb5126585aebf57224b03/src/Payment/Webhooks/RestApi.php#L184-L186)):

   ```php
   $this->mollieOrderService->doPaymentForOrder($orders[0]);

   return new \WP_REST_Response(null, 200);
   ```
3. **`doPaymentForOrder()` returns `false` when the payment could not be loaded**
   ([`MollieOrderService.php#L264-L267`](https://github.com/mollie/WooCommerce/blob/4d75849d6c72e8206a7cb5126585aebf57224b03/src/Payment/MollieOrderService.php#L264-L267)).
4. **Every API error turns into "not loaded"**
   ([`MolliePayment.php#L42-L58`](https://github.com/mollie/WooCommerce/blob/4d75849d6c72e8206a7cb5126585aebf57224b03/src/Payment/MolliePayment.php#L42-L58)).
   The HTTP adapter throws an `ApiException` on a transport error (timeout, DNS, TLS) and on any
   HTTP status of 400 or higher
   ([`WordPressHttpAdapter.php#L44`](https://github.com/mollie/WooCommerce/blob/4d75849d6c72e8206a7cb5126585aebf57224b03/src/SDK/WordPressHttpAdapter.php#L44),
   [`#L88`](https://github.com/mollie/WooCommerce/blob/4d75849d6c72e8206a7cb5126585aebf57224b03/src/SDK/WordPressHttpAdapter.php#L88);
   the request timeout is 10 seconds, [`#L15`](https://github.com/mollie/WooCommerce/blob/4d75849d6c72e8206a7cb5126585aebf57224b03/src/SDK/WordPressHttpAdapter.php#L15)).
   `getPaymentObject()` catches all of them, writes a debug line, and returns `null`.

For comparison, the same failure is not acknowledged elsewhere in the plugin:

- the WC-API webhook answers **400** when `doPaymentForOrder()` returns `false`
  ([`MollieOrderService.php#L137-L138`](https://github.com/mollie/WooCommerce/blob/4d75849d6c72e8206a7cb5126585aebf57224b03/src/Payment/MollieOrderService.php#L137-L138));
- in the REST callback's own fallback branch, where no order is found locally, an `ApiException`
  is answered with **500**
  ([`RestApi.php#L172-L174`](https://github.com/mollie/WooCommerce/blob/4d75849d6c72e8206a7cb5126585aebf57224b03/src/Payment/Webhooks/RestApi.php#L172-L174)).

## Reproduction, against the plugin's own code

A small harness runs both webhook entry points under PHP's built-in server:

- **Real:** the plugin's code from `RestApi::callback()` and `MollieOrderService::onWebhookAction()`
  down through `PaymentFactory`, `MolliePayment`, the plugin's `Api` helper and `WordPressHttpAdapter`,
  plus the Mollie API client at the locked version (mollie-api-php v2.79.1).
- **Stubbed:** WordPress and WooCommerce, in memory. There is one pending order for `tr_WDqYK6vllg`.
  `wp_remote_request()` plays the Mollie API and gives the answer the scenario asks for.
- **Replaced:** only the final handler that marks a paid order as paid, by a recorder.

Each row is one webhook POST (`id=tr_WDqYK6vllg`); the status is what the endpoint answered:

| Mollie API answer to the status request | REST webhook (default) | WC-API webhook (legacy) | Order afterwards |
|---|---|---|---|
| 200, payment `paid` | 200, paid handler ran | 200, paid handler ran | processing |
| timeout (`cURL error 28`) | **200** | 400 | pending |
| 503 Service Unavailable | **200** | 400 | pending |
| 429 Too Many Requests | **200** | 400 | pending |
| 404 Not Found | 200 | 400 | pending |

In every failed case the plugin made exactly one request to the Mollie API. It did not apply a
status, and the REST endpoint still told Mollie the webhook was handled.

## What happens to the order next

- **With stock management on**, WooCommerce cancels unpaid orders after the hold-stock time (60
  minutes by default). Before it does, the plugin asks Mollie once more
  ([`GatewayModule.php#L216-L232`](https://github.com/mollie/WooCommerce/blob/4d75849d6c72e8206a7cb5126585aebf57224b03/src/Gateway/GatewayModule.php#L216-L232)).
  If that request works, the order is repaired an hour late. If it fails too, WooCommerce cancels
  an order that was paid.
- **Without stock management**, which is common for digital goods and services, WooCommerce never
  runs that job, and nothing asks Mollie again. The order stays pending until someone notices.

## How it looks from the store

The plugin's log (WooCommerce → Status → Logs) is on by default. A lost webhook leaves two debug
lines:

```
getPaymentObject: Could not load payment tr_WDqYK6vllg (live): [...] cURL error 28: Operation timed out after 10001 milliseconds with 0 bytes received (Mollie\Api\Exceptions\ApiException)
Mollie\WooCommerce\Payment\MollieOrderService::doPaymentForOrder: payment tr_WDqYK6vllg not found.
```

The second line is misleading: the payment exists; the request for it failed.

The symptom has been reported before. In [mollie/WooCommerce#792](https://github.com/mollie/WooCommerce/issues/792)
(2023, plugin 7.3.9) a store found the same "Could not load payment" line in its log, with
`cURL error 6: Could not resolve host: api.mollie.com`, and paid orders left waiting for payment.
It was closed as an isolated problem. The issue doesn't show which webhook URL that version used.

## What would fix it

Answer **non-200 when the status could not be fetched**: a transport error, a 5xx, a 429. Mollie's
own retry schedule, 10 attempts over 26 hours, then covers exactly the failures that go away by
themselves: timeouts, rate limits and short outages. Keep answering 200 for ids that Mollie doesn't
know, as the documentation recommends.

`doPaymentForOrder()` also returns `false` for other reasons, for example a status that has no
handler. So the callback needs to know *why* the payment wasn't loaded. One way is to keep the
`ApiException` (and its code: 0 for transport errors, the HTTP status otherwise) visible to the
callback instead of turning it into `null`.

## Finding the orders with callback-audit

The loss is visible only when you compare two records: an order still *pending* in WooCommerce and
a payment *paid* in Mollie. That comparison is what callback-audit does, at station 5 ("provider
terminal, local non-terminal") and station 7 (age of non-terminal orders). There is no Mollie
adapter yet; the generic `--events` format (`payment_id, at, status`) works with a Mollie payments
export in which each payment is mapped to its order number.
