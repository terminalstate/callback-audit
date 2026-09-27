<?php
// php -S router: routes a real Stripe webhook POST into the REAL webhook handler.
// Point PLUGIN_DIR at a checkout of woocommerce-gateway-stripe (tested at v11.0.0):
//   PLUGIN_DIR=/path/to/woocommerce-gateway-stripe/includes
require __DIR__ . '/wp-stubs.php';
$dir = getenv('PLUGIN_DIR') ?: (__DIR__ . '/woocommerce-gateway-stripe/includes');
require $dir . '/class-wc-stripe-webhook-state.php';
require $dir . '/class-wc-stripe-webhook-handler.php';

// Test double: keeps the REAL check_for_webhook()/validate_request(); only
// (a) forces the single-webhook config (the common one, whose failure path is 204),
// (b) records whether the validation gate opened, instead of running order processing.
class TestHandler extends WC_Stripe_Webhook_Handler {
    public function has_duplicate_webhooks_setup() { return false; }
    public function process_webhook($request_body) {
        header('X-Reached-Processing: 1');
        $GLOBALS['__reached'] = true;
    }
}
if (($_GET['wc-api'] ?? '') !== 'wc_stripe') { http_response_code(404); echo "not the webhook route\n"; return; }
$h = new TestHandler();
$h->check_for_webhook();  // exits on every real branch
