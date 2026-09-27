# Paid in Mollie, draft in Odoo: the webhook acknowledges a status check that failed

*A fourth worked case for [callback-audit](https://github.com/terminalstate/callback-audit), and the
first in Python. It is the same bug as in the [Mollie for WooCommerce case](case-mollie-woocommerce-200.md),
this time in Odoo, the open-source ERP with a web shop, whose Mollie integration is part of Odoo
Community. It is reproduced in a real Odoo with Odoo's own test framework. Everything here is public:
no store data and no Mollie account.*

## TL;DR

A Mollie webhook carries nothing but a payment id; the receiver has to ask the Mollie API for the
status. In **Odoo 18.0 and 19.0** the Mollie webhook answers **200 even when that request failed**:
a connection error, an error status such as 503 or 429 from the API (in 18.0, as long as the error
body is Mollie's usual JSON), and in 19.0 also a timeout. Mollie retries a webhook for 26 hours, but
only until it gets a 200, so this delivery is never retried. The payment transaction stays in
*draft* and its sales order stays a quotation. Apart from the customer's own return to the shop,
nothing in Odoo asks Mollie again.

The 200 is deliberate. In 17.0 and 18.0 the code catches the error with the comment "acknowledge the
notification to avoid getting spammed"; 19.0 logs it and answers the same. That is right for a
notification that can never be processed, such as a reference Odoo doesn't know, and wrong for a
status check that failed this time and would work on the next attempt. The same logic is in 17.0,
the saas-19 releases and master.

## What Mollie expects

[Mollie's webhook documentation](https://docs.mollie.com/reference/webhooks) says:

- the webhook is a POST with a single `id` parameter; the status is not in it, and the receiver
  fetches it from the API;
- Mollie calls the webhook up to 10 times, at increasing intervals, until it gets a `200 OK`, and
  gives up after the 10th call, about 26 hours later;
- a webhook call times out after 15 seconds;
- for an id the receiver doesn't know, Mollie recommends answering 200 anyway, so as not to leak
  information.

A 200 therefore means "done". It is right for an id Odoo doesn't know. It is wrong for a payment
Odoo knows but couldn't check.

## The code path

Links are to [`4e7b84d`](https://github.com/odoo/odoo/tree/4e7b84db9455086754164db5e404987c34d48eb7)
on `19.0` and [`bdb5a9a`](https://github.com/odoo/odoo/tree/bdb5a9a8f81563a87081ec17ef99bf0fbb8d4e98)
on `18.0`.

**19.0.** The webhook route calls `_verify_and_process()` and returns an empty string, which is a 200
([`payment_mollie/controllers/main.py#L41-L52`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/addons/payment_mollie/controllers/main.py#L41-L52)).
`_verify_and_process()` finds the transaction by the reference Odoo put in the webhook URL, fetches
the payment, and on a `ValidationError` writes one log line and stops
([`#L54-L72`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/addons/payment_mollie/controllers/main.py#L54-L72)):

```python
try:
    verified_data = tx_sudo._send_api_request(
        'GET', f'/payments/{tx_sudo.provider_reference}'
    )
except ValidationError:
    _logger.error("Unable to process the payment data")
else:
    tx_sudo._process('mollie', verified_data)
```

`_send_api_request()` is the shared helper of all payment providers. It raises `ValidationError` on a
connection error, a timeout, and any HTTP status of 400 or higher, whatever the body
([`payment/models/payment_provider.py#L756-L814`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/addons/payment/models/payment_provider.py#L756-L814)).
Its docstring asks callers to catch that error "whenever possible"
([`#L761-L763`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/addons/payment/models/payment_provider.py#L761-L763)),
and the Mollie controller does, on the webhook route as well as on the customer's return route.

**18.0.** The webhook route wraps the whole processing in `try`/`except ValidationError` and returns
an empty string either way
([`payment_mollie/controllers/main.py#L39-L53`](https://github.com/odoo/odoo/blob/bdb5a9a8f81563a87081ec17ef99bf0fbb8d4e98/addons/payment_mollie/controllers/main.py#L39-L53)).
Processing fetches the payment through `_mollie_make_request()`
([`models/payment_transaction.py#L102-L116`](https://github.com/odoo/odoo/blob/bdb5a9a8f81563a87081ec17ef99bf0fbb8d4e98/addons/payment_mollie/models/payment_transaction.py#L102-L116)),
which raises `ValidationError` on connection errors and timeouts, and on HTTP errors
([`models/payment_provider.py#L40-L84`](https://github.com/odoo/odoo/blob/bdb5a9a8f81563a87081ec17ef99bf0fbb8d4e98/addons/payment_mollie/models/payment_provider.py#L40-L84)).
For an HTTP error it reads the `detail` field of the JSON body. An error page that isn't JSON, such
as one from a gateway in front of the API, escapes as a `JSONDecodeError`; Odoo then answers 500 and
Mollie retries. Errors from Mollie's API itself come as JSON.

**Timeouts.** Mollie gives up on a webhook call after 15 seconds. In 19.0 the request to Mollie has a
10-second timeout, for connecting and for each wait on the answer; it is not a total deadline. A hung
API usually runs into it within Mollie's 15 seconds, and then the timeout is acknowledged with a 200
as well. In 18.0 the timeout is 60 seconds, so Mollie usually gives up first, counts a failed call and
retries: there a slow API is survived by accident. Fast failures are acknowledged in both: a refused
connection, a failed DNS lookup or TLS handshake, an error status.

**Without the `except`.** Odoo's HTTP layer answers an uncaught `ValidationError` with **422** in
19.0 ([`odoo/http.py#L2529-L2533`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/odoo/http.py#L2529-L2533)) and with **400** in 18.0
([`odoo/http.py#L2320-L2324`](https://github.com/odoo/odoo/blob/bdb5a9a8f81563a87081ec17ef99bf0fbb8d4e98/odoo/http.py#L2320-L2324)). Either way Mollie would retry.

**Other providers.** The Stripe webhook in 19.0 catches and acknowledges the same way
([`payment_stripe/controllers/main.py#L153-L155`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/addons/payment_stripe/controllers/main.py#L153-L155)),
but its API calls are only for saved cards and refunds, while every Mollie webhook depends on one.

## Reproduction, in a real Odoo

The harness is in this repository: [`repro/odoo-mollie/`](../repro/odoo-mollie/). It is a test-only
Odoo module, run by Odoo's own test framework on a real PostgreSQL database.

- **Real:** Odoo's HTTP server, the `/payment/mollie/webhook` route, the controller, the request
  helper with its error handling, the transaction update, the post-processing cron. The provider
  and the transactions come from Odoo's own test fixtures.
- **Fake:** the Mollie API. `requests.request` is replaced for URLs on api.mollie.com only, and
  answers the way the scenario asks.

Each delivery is posted the way Mollie sends it: the transaction reference in the query string of the
webhook URL Odoo gave Mollie, the payment id in the body:

| Mollie API answer to the status request | Webhook answered, 19.0 | Webhook answered, 18.0 | Transaction afterwards |
|---|---|---|---|
| 200, payment `paid` | 200 | 200 | done |
| connection error | **200** | **200** | draft |
| timeout | **200** | **200** | draft |
| 503, Mollie's JSON error | **200** | **200** | draft |
| 429, Mollie's JSON error | **200** | **200** | draft |
| 502, HTML page from a gateway | **200** | 500 | draft |
| 404, Mollie's JSON error | 200 | 200 | draft |

The fake raises the timeout at once. A real one takes the full timeout: in 19.0 that is usually
within Mollie's 15 seconds, in 18.0 usually after them.

Two more results, from the same run:

- **Nothing asks again.** After an acknowledged 503, the post-processing cron makes no API call and
  the transaction stays in draft. A second delivery with the API answering normally, which is what
  Mollie would have sent after a non-2xx answer, marks it done.
- **Without the `except` (19.0).** With the fetch error left to Odoo's HTTP layer, the six failing
  rows answer 422, so Mollie would retry them, and a reference Odoo doesn't know still gets a 200.

The only trace is in the server log: `Unable to process the payment data` in 19.0; in 18.0
`Unable to reach endpoint at https://api.mollie.com/v2/payments/…` or `Invalid API request at …`,
followed by `unable to handle the notification data; skipping to acknowledge`.

## What happens to the order

These points are read from the code, not reproduced:

- The sales order is confirmed only when its transaction is authorized or done
  ([`sale/models/payment_transaction.py#L40-L106`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/addons/sale/models/payment_transaction.py#L40-L106)).
  A draft transaction leaves it a quotation: no confirmation, no invoice, no delivery.
- The post-processing cron picks up recent transactions, drafts included, only to post-process
  them; it never calls the provider
  ([`payment/models/payment_transaction.py#L1082-L1110`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/addons/payment/models/payment_transaction.py#L1082-L1110)).
- If the customer comes back to the shop, the return route makes the same request
  ([`payment_mollie/controllers/main.py#L19-L39`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/addons/payment_mollie/controllers/main.py#L19-L39)),
  and if it works, the payment is recorded. The webhook matters when the customer doesn't come back,
  and for methods whose money arrives after the customer has left, such as bank transfer: there it
  is the only thing that reports the payment.
- If the website sends abandoned-cart emails (a website setting, off by default), that quotation
  becomes an abandoned cart once it is older than the abandoned delay (10 hours by default), and
  the customer who paid gets a cart-recovery email
  ([`website_sale/models/sale_order.py#L78-L90`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/addons/website_sale/models/sale_order.py#L78-L90),
  [`#L775-L815`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/addons/website_sale/models/sale_order.py#L775-L815),
  [`models/website.py#L921-L945`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/addons/website_sale/models/website.py#L921-L945)).

## What would fix it

On the webhook route, let a failed status request answer non-2xx, and keep the 200 for references
Odoo doesn't know. In 19.0 that means calling `_send_api_request()` from the webhook without the
`except`, as the harness's third test does. Odoo then answers 422, and Mollie's own schedule, 10
attempts over 26 hours, covers the failures that go away by themselves: timeouts, rate limits, short
outages. A permanent error such as a 404 would be retried too, which costs ten requests. The return
route can keep catching the error, because the customer should land on the status page either way.
In 18.0 the same change is to stop the webhook's `except` from swallowing errors of the API request
(Odoo then answers 400).

## Finding the transactions with callback-audit

The loss shows only when you compare two records: a transaction still in draft or pending in Odoo,
and a payment paid in Mollie. The join key exists: Odoo sends the transaction reference to Mollie as
the payment's description
([`payment_mollie/models/payment_transaction.py#L66-L67`](https://github.com/odoo/odoo/blob/4e7b84db9455086754164db5e404987c34d48eb7/addons/payment_mollie/models/payment_transaction.py#L66-L67)).

From Odoo, export the payment transactions (reference, creation date, status) as `id, created_at,
status`, with the status as Odoo names it internally: the list shows *Confirmed* for `done` and
*Canceled* for `cancel`. From Mollie, export the payments (description, date, status) as
`payment_id, at, status`. Then:

```
callback-audit --payments odoo-transactions.csv --terminal done,cancel,error --success done \
               --events mollie-payments.csv --provider-terminal paid,canceled,expired,failed \
               --provider-success paid
```

On a transaction left in draft after its payment was paid, station 5 reports it:

```
SUSPECT: provider terminal, local non-terminal
provider status -> local status: paid -> local draft: 1
examples: S00042-1
```
