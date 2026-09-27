# Harness: Odoo, Mollie webhook → status fetch → transaction

A test-only Odoo module, `repro_mollie_webhook`, that posts Mollie webhook deliveries to Odoo's own
`/payment/mollie/webhook` route and makes the Mollie API fail in different ways. Write-up:
[docs/case-odoo-mollie-200.md](../../docs/case-odoo-mollie-200.md).

```
./run.sh                    # Odoo 19.0: clones it (~1.4 GB), creates a venv, runs the tests
ODOO_BRANCH=18.0 ./run.sh   # Odoo 18.0
```

Needs git, Python 3.10-3.12 and a PostgreSQL server where the current user may create databases.
The connection comes from the usual `PGHOST`, `PGPORT`, `PGUSER` and `PGPASSWORD` variables. For a
throwaway server: `docker run -d -p 5432:5432 -e POSTGRES_USER=odoo -e POSTGRES_PASSWORD=odoo postgres:16`,
then `PGHOST=localhost PGUSER=odoo PGPASSWORD=odoo ./run.sh`.

## What is real and what is not

| Part | |
|---|---|
| Odoo: the HTTP server, the `/payment/mollie/webhook` route, `MollieController`, `_send_api_request` (19.0) or `_mollie_make_request` (18.0) with their error handling, the transaction update, the post-processing cron | **real**, run by Odoo's own test framework (`HttpCase`) on a real PostgreSQL database |
| Mollie API | fake: `requests.request` is patched for URLs on `api.mollie.com` only, and answers the way the scenario asks (paid, connection error, timeout, 503, 429, a 502 HTML page from a gateway, 404) |
| Payment provider and transactions | created by Odoo's own test fixtures (`MollieCommon`, `PaymentHttpCommon`) |

Each delivery is posted the way Mollie sends it: the transaction reference in the query string of
the webhook URL Odoo gave Mollie, and the payment id in the body.

## The three tests

- `test_1_webhook_answer_per_api_answer`: one delivery per API answer; what the webhook answered and
  the state of the transaction afterwards.
- `test_2_nothing_fetches_the_status_again`: after an acknowledged failure, the post-processing cron
  makes no API call and the transaction stays where it was; a second delivery with the API healthy,
  which is what Mollie would send after a non-2xx answer, confirms the payment.
- `test_3_webhook_answer_if_the_error_propagated`: the same deliveries with the fetch error left to
  Odoo's HTTP layer instead of swallowed, as a possible fix would do. 19.0 only.

The tests assert what Odoo does today, so they pass on an unchanged Odoo.
