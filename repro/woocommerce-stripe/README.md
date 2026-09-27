# Harness: WooCommerce Stripe Gateway, signature failure → 204 → pending order

Runs the plugin's real `check_for_webhook()` / `validate_request()` under PHP's built-in server with
WordPress stubbed to memory, drives real webhook POSTs through it, and turns the real answers into
exports for callback-audit. Write-up: [docs/case-woocommerce-stripe-204.md](../../docs/case-woocommerce-stripe-204.md).

Needs PHP 8+ (with curl), Python 3.10+ and git.

```bash
# 1. The plugin at the version the case is about
git clone --depth 1 --branch 11.0.0 https://github.com/woocommerce/woocommerce-gateway-stripe

# 2. 96 webhook POSTs through the real handler; the dataset is written from the real answers
python3 generate.py      # orders=96  http_codes={200: 81, 204: 15, 'other': 0}  stuck(204)=15

# 3. The audit
pip install git+https://github.com/terminalstate/callback-audit
cd dataset
callback-audit --payments payments.csv --terminal succeeded,failed,canceled,refunded \
               --events events.csv --inbound inbound.csv --path-filter wc_stripe --app-log app.log \
               --now "$(cat NOW.txt)"
```

`PLUGIN_DIR=/path/to/woocommerce-gateway-stripe/includes` points it at another checkout.

## Files

- `wp-stubs.php`: minimal in-memory WordPress and WooCommerce stubs (options, logger,
  `status_header`, `ABSPATH`). No database and no WordPress core.
- `router.php`: loads the real `class-wc-stripe-webhook-state.php` and
  `class-wc-stripe-webhook-handler.php`, and runs the real `check_for_webhook()`. It subclasses the
  handler only to force the single-webhook configuration (the common one, whose failure answer is
  204) and to record whether the validation gate opened.
- `generate.py`: plays a small shop for 14 days, posts every webhook through that server, and writes
  `dataset/` from the real response codes. Deterministic (`random.seed(7)`).
- `client.php`: a two-request smoke test with the server running
  (`STORE_WEBHOOK_SECRET=whsec_store_configured_secret php -S 127.0.0.1:8099 router.php`):
  the right secret gets 200, a rotated one 204.

The signing timestamp on each POST is the real clock, because the handler enforces a five-minute
window; the scenario's dates live only in the exported rows.
