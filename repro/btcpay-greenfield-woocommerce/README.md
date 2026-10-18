# Harness: BTCPay for WooCommerce V2, InvoiceSettled is answered 200 when the invoice cannot be re-fetched

A real WordPress site with WooCommerce and the BTCPay Greenfield plugin (from git, at a pinned commit), an order that is
`on-hold` after `InvoiceProcessing`, and a signed `InvoiceSettled` webhook posted to `?wc-api=btcpaygf_default` while the
plugin's request to re-fetch the invoice from BTCPay Server fails.

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]          # master on 2026-10-18
BTCPAY_COMMIT=<sha> bash run.sh                                                  # another commit
```

Needs PHP 8 with mysqli and curl, Composer, [WP-CLI](https://wp-cli.org/), git, curl and an empty MySQL or MariaDB database
(`DB_NAME`, default `btcpay_stand`).

## What is real and what is not

| Part | |
|---|---|
| WordPress, WooCommerce, the plugin's webhook handler (signature check, order lookup, `InvoiceSettled` handling) and its Greenfield API client | **real** |
| The webhook | a POST built by `run.sh` and signed with the webhook secret (`BTCPay-Sig: sha256=<HMAC of the body>`) |
| BTCPay Server | fake: `fake-btcpay.php` on a second local port answers `GET /api/v1/stores/{store}/invoices/{id}` with 503 (`outage`) or the invoice as `Settled` (`ok`) |

## The finding

Since the plugin re-fetches the invoice before completing the order
([#79](https://github.com/btcpayserver/woocommerce-greenfield-plugin/pull/79)), a failed request lands in a `catch` that adds the
note "…could not be verified. The order was not marked as paid. Please retry the webhook or check the invoice manually." and
`break`s, so the webhook request ends with HTTP 200. BTCPay Server redelivers only failed deliveries ("If true, BTCPay Server
will retry to redeliver any failed delivery after 10 seconds, 1 minutes and up to 6 times after 10 minutes",
`automaticRedelivery`, default `true`), so the delivery counts as successful and the paid order stays `on-hold` (or `pending`
for Lightning, where WooCommerce may later cancel it).

## Result

| Invoice request | `master` 2026-10-18 | answering 503 in that `catch` |
|---|---|---|
| fails (503) | 200, order `on-hold`, note "could not be verified" | 503; BTCPay's redelivery with the API back → `processing` |
| succeeds | 200, order `processing` | the same |

The right column was checked with a temporary local change (`wp_die( …, '', array( 'response' => 503 ) )` instead of
`break`); it is not part of `run.sh`.

Run on 2026-10-18 (WordPress 7.1.3, WooCommerce 11.2.1, plugin `master` at 9d00861 — 2.8.5 plus the fixes of 2026-10-15, PHP
8.4, MariaDB 11.4):

```
== settled, API unavailable: HTTP 200 body=-1
   order=11 status=on-hold paid_date=none last_note="InvoiceSettled webhook received, but BTCPay invoice STANDINV1 could not be verified. The order was not marked as paid. Please retry the webhook or check the invoice manually."
   BTCPay API calls: GET /api/v1/stores/STANDSTORE1/invoices/STANDINV1 (outage) -> 503;
== control: HTTP 200
   order=12 status=processing paid_date=set last_note="Invoice payment settled."

REPRODUCED: the plugin could not verify the settled invoice, added a note asking to 'retry the webhook', and answered
HTTP 200 — so BTCPay counts the delivery as successful and does not redeliver it. The paid order stays on-hold.
Control: the same delivery with the API reachable completes the order.
```
