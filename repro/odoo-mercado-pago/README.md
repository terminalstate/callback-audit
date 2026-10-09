# Harness: Odoo, Mercado Pago webhook → payment fetch → transaction

A test-only Odoo module, `repro_mercado_pago_webhook`, that posts Mercado Pago notifications to Odoo's own
`/payment/mercado_pago/webhook/<reference>` route and makes the Mercado Pago API fail in different ways.
It is the Mercado Pago counterpart of the [Mollie harness](../odoo-mollie/): the same pattern, which Odoo
fixed for Mollie in [odoo/odoo#290812](https://github.com/odoo/odoo/pull/290812).

```
./run.sh        # Odoo 19.0: clones it (~1.4 GB), creates a venv, runs the tests
```

Needs git, Python 3.10-3.12 and a PostgreSQL server where the current user may create databases.
The connection comes from the usual `PGHOST`, `PGPORT`, `PGUSER` and `PGPASSWORD` variables. For a
throwaway server: `docker run -d -p 5432:5432 -e POSTGRES_USER=odoo -e POSTGRES_PASSWORD=odoo postgres:16`,
then `PGHOST=localhost PGUSER=odoo PGPASSWORD=odoo ./run.sh`.

## What is real and what is not

| Part | |
|---|---|
| Odoo: the HTTP server, the `/payment/mercado_pago/webhook/<reference>` route, `MercadoPagoPaymentController`, `_send_api_request` with its error handling, the OAuth token refresh through Odoo's proxy, the transaction update, the post-processing cron | **real**, run by Odoo's own test framework (`HttpCase`) on a real PostgreSQL database |
| Mercado Pago API and Odoo's Mercado Pago proxy | fake: `requests.request` is patched for URLs on `api.mercadopago.com` and `mercadopago.api.odoo.com` only, and answers the way the scenario asks (approved, connection error, timeout, 500, 503, 429, a 502 HTML page from a gateway, 404) |
| Payment provider and transactions | created by Odoo's own test fixtures (`MercadoPagoCommon`, `PaymentHttpCommon`) |

Each notification is posted the way Mercado Pago sends it: the transaction reference in the path of the
webhook URL Odoo gave Mercado Pago, `{"action": "payment.updated", "data": {"id": …}}` in the JSON body.
The transaction is already pending, as for an OXXO, Pix or boleto payment that the customer settles later.

## The four tests

- `test_1_webhook_answer_per_api_answer`: one notification per API answer; what the webhook answered and
  the state of the transaction afterwards.
- `test_2_expired_token_and_proxy_down`: the access token has expired, so it is refreshed through Odoo's
  proxy inside the same call, and the proxy can't be reached.
- `test_3_nothing_fetches_the_payment_again`: after an acknowledged failure, the post-processing cron
  makes no API call and the transaction stays where it was; a second notification with the API healthy,
  which is what Mercado Pago would send after a non-2xx answer, confirms the payment.
- `test_4_webhook_answer_if_the_error_propagated`: the same notifications with the fetch error left to
  Odoo's HTTP layer instead of swallowed, as a possible fix would do.

The tests assert what Odoo does today, so they pass on an unchanged Odoo.

## Result on 19.0 (f141381, 2026-10-09)

| Mercado Pago API answer | Webhook answered | Transaction afterwards | With the error propagated |
|---|---|---|---|
| 200, payment `approved` | 200 | done | 200, done |
| connection error | **200** | pending | 422 |
| timeout | **200** | pending | 422 |
| 500 | **200** | pending | 422 |
| 503 | **200** | pending | 422 |
| 429 | **200** | pending | 422 |
| 502, HTML page from a gateway | **200** | pending | 422 |
| 404 | **200** | pending | 422 |
| expired token, proxy connection error | **200** | pending | |
| expired token, proxy 503 | **200** | pending | |

Mercado Pago sends a notification again only when it doesn't get a 200 or 201
([payment notifications](https://www.mercadopago.com.mx/developers/en/docs/checkout-pro/payment-notifications)),
so an acknowledged failure is never retried. 17.0, 18.0, saas-19.x and master have the same code (not run).
