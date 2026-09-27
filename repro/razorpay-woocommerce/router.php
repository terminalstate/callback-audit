<?php
/**
 * php -S 127.0.0.1:8792 router.php — the store.
 *
 * Every request loads the plugin the way WordPress does (require woo-razorpay.php, then fire
 * plugins_loaded), then does what the corresponding WordPress entry point does:
 *
 *   POST /wp-admin/admin-post.php?action=rzp_wc_webhook   the webhook URL the plugin registers with
 *        Razorpay (init_form_fields(), woo-razorpay.php L493). As in admin-post.php for a visitor who
 *        is not logged in: 400 if nothing is hooked to admin_post_nopriv_<action>, otherwise fire the
 *        action and end. Whatever status the handler leaves is what Razorpay gets.
 *   GET  /wp-cron.php?hook=rzp_webhook_exec_cron          what WP-Cron does when the event is due.
 *   POST /?wc-api=razorpay&order_key=...                   the browser callback after checkout: as in
 *        WooCommerce's wc-api dispatch, the gateway is constructed and woocommerce_api_razorpay fired.
 *   GET  /_harness/state                                   the order, its notes and the queue row, as JSON.
 */

declare(strict_types=1);

require __DIR__ . '/wp-stubs.php';

function harness_load_plugin(): void
{
    // The fake Razorpay API. Api::$baseUrl is the SDK's own switch for this (razorpay-sdk/src/Api.php).
    require_once $GLOBALS['harness_plugin'] . '/razorpay-sdk/Razorpay.php';
    (new ReflectionClass(Razorpay\Api\Api::class))->setStaticPropertyValue('baseUrl', 'http://127.0.0.1:8793');

    require_once $GLOBALS['harness_plugin'] . '/woo-razorpay.php';
    do_action('plugins_loaded');
}

$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

if ($path === '/wp-admin/admin-post.php') {
    define('WP_ADMIN', true);
    harness_load_plugin();
    do_action('admin_init');
    $action = sanitize_text_field($_REQUEST['action'] ?? '');
    if (!has_action("admin_post_nopriv_{$action}")) {
        http_response_code(400);
        exit;
    }
    do_action("admin_post_nopriv_{$action}");
    exit;
}

if ($path === '/wp-cron.php') {
    harness_load_plugin();
    do_action($_GET['hook'] ?? '');
    exit;
}

if (($_GET['wc-api'] ?? '') !== '') {
    harness_load_plugin();
    $gateway = new WC_Razorpay();   // hooks=true: registers woocommerce_api_razorpay
    do_action('woocommerce_api_' . strtolower(sanitize_text_field($_GET['wc-api'])));
    exit;
}

if ($path === '/_harness/state') {
    $db = harness_db();
    header('Content-Type: application/json');
    echo json_encode([
        'order_status' => (new WC_Order(1234))->get_status(),
        'transaction_id' => get_post_meta(1234, '_transaction_id', true),
        'notes' => $db->query('SELECT note FROM wp_harness_notes WHERE order_id = 1234 ORDER BY id')->fetchAll(PDO::FETCH_COLUMN),
        'queue' => $db->query('SELECT order_id, rzp_order_id, rzp_webhook_data, rzp_webhook_notified_at, rzp_update_order_cron_status FROM wp_rzp_webhook_requests')->fetchAll(PDO::FETCH_ASSOC),
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}

http_response_code(404);
