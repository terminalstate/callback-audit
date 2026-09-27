# Harness: Mollie Payments for WooCommerce, webhook → status fetch → order

Runs both webhook entry points of the plugin with its own code under PHP's built-in server, with
WordPress and WooCommerce stubbed and `wp_remote_request()` playing the Mollie API. Write-up:
[docs/case-mollie-woocommerce-200.md](../../docs/case-mollie-woocommerce-200.md).

Needs PHP 8.1+ and git.

```
./run.sh   # first run clones the plugin at 4d75849 (8.1.10) and its PHP dependencies into ./deps
```

`PLUGIN_DIR=/path/to/plugin ./run.sh` points it at another checkout.

## What is real and what is not

| Part | |
|---|---|
| `RestApi::callback()` (REST webhook, the default URL) and `MollieOrderService::onWebhookAction()` (WC-API webhook) down through `PaymentFactory`, `MolliePayment`, the plugin's `Api` helper and `WordPressHttpAdapter` | **real** |
| mollie-api-php v2.79.1 and its dependencies, at the versions in the plugin's `composer.lock` | **real**, cloned from GitHub |
| `WebhookHandler::onWebhookPaid()` | replaced by a recorder that marks the order paid, so a row shows whether it was reached |
| WordPress and WooCommerce (`wp-stubs.php`) | stubbed, in memory: one pending order for payment `tr_WDqYK6vllg` |
| Mollie API | fake: `wp_remote_request()` answers the way the `X-Mollie-Api` request header asks (`paid`, `timeout`, `503`, `429`, `404`) |

The router adds three debug headers to each response: `X-Order-Status` (after the webhook),
`X-Handler` (what ran) and `X-Api-Calls` (requests the plugin made to the Mollie API).

## Files

- `run.sh`: clones what is missing, starts the server, sends one webhook per API answer to each entry point, prints the table
- `router.php`: the store (`php -S`), both webhook entry points and the fake API
- `wp-stubs.php`: the WordPress and WooCommerce surface the plugin touches on this path
