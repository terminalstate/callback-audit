<?php
/**
 * Fresh store state for one scenario:
 *   php setup.php <capture|authorize>
 *
 * One WooCommerce order (#1234, INR 499.00, Pending payment, paid with Razorpay) and what the plugin
 * itself stores when it creates the Razorpay order for it in createRazorpayOrderId():
 *   - the order meta razorpay_order_id1234 = order_RZPHARNESS01          (woo-razorpay.php L1456-1467)
 *   - a row in wp_rzp_webhook_requests with rzp_webhook_data '[]' and
 *     rzp_update_order_cron_status 0                                     (woo-razorpay.php L1480-1492)
 * Plugin settings: key id/secret (fake), the chosen Payment Action, debug log on (the default).
 * The webhook secret sits in the 'webhook_secret' option, where autoEnableWebhook() keeps it.
 */

declare(strict_types=1);

$state = getenv('STATE_DIR') ?: __DIR__ . '/state';
$action = $argv[1] ?? 'capture';
if (!in_array($action, ['capture', 'authorize'], true)) {
    fwrite(STDERR, "usage: php setup.php <capture|authorize>\n");
    exit(2);
}

@mkdir($state, 0777, true);
foreach (['wp.sqlite', 'razorpay-logs.log', 'outbound.log', 'api.log', 'api-scenario', 'php-errors.log'] as $f) {
    @unlink("$state/$f");
}

$db = new PDO("sqlite:$state/wp.sqlite");
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$db->exec(<<<'SQL'
CREATE TABLE wp_options (option_name TEXT PRIMARY KEY, option_value TEXT);
CREATE TABLE wp_posts (ID INTEGER PRIMARY KEY, post_type TEXT, post_status TEXT);
CREATE TABLE wp_postmeta (meta_id INTEGER PRIMARY KEY AUTOINCREMENT, post_id INTEGER, meta_key TEXT, meta_value TEXT);
CREATE TABLE wp_harness_notes (id INTEGER PRIMARY KEY AUTOINCREMENT, order_id INTEGER, note TEXT);
-- The plugin's table, same columns as its CREATE TABLE (woo-razorpay.php L3459-3467), in SQLite syntax.
CREATE TABLE wp_rzp_webhook_requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    integration varchar(25) NOT NULL,
    order_id int(11) NOT NULL,
    rzp_order_id varchar(25) NOT NULL,
    rzp_webhook_data text,
    rzp_webhook_notified_at int(11),
    rzp_update_order_cron_status int(11) DEFAULT 0
);
SQL);

$opt = $db->prepare('INSERT INTO wp_options (option_name, option_value) VALUES (?, ?)');
$opt->execute(['woocommerce_razorpay_settings', serialize([
    'enabled' => 'yes',
    'title' => 'UPI, Cards, NetBanking',
    'description' => 'Pay securely via Razorpay.',
    'key_id' => 'rzp_test_HARNESS00000001',
    'key_secret' => 'harness_key_secret_0001',
    'payment_action' => $action,
    'order_success_message' => 'Thank you for shopping with us.',
    'enable_1cc_debug_mode' => 'yes',
])]);
$opt->execute(['webhook_secret', serialize('harness_webhook_secret_0001')]);
$opt->execute(['rzp_webhook_setup', serialize('yes')]);     // table already exists (created above)
$opt->execute(['webhook_enable_flag', serialize(time())]);  // webhook auto-setup ran recently

$db->exec("INSERT INTO wp_posts (ID, post_type, post_status) VALUES (1234, 'shop_order', 'wc-pending')");
$meta = $db->prepare('INSERT INTO wp_postmeta (post_id, meta_key, meta_value) VALUES (1234, ?, ?)');
foreach ([
    '_order_key' => 'wc_order_HARNESS1234',
    '_order_total' => '499.00',
    '_order_currency' => 'INR',
    '_payment_method' => 'razorpay',
    '_created_via' => 'checkout',
    'razorpay_order_id1234' => 'order_RZPHARNESS01',
] as $k => $v) {
    $meta->execute([$k, $v]);
}
$db->exec("INSERT INTO wp_harness_notes (order_id, note) VALUES (1234, 'Razorpay OrderId: order_RZPHARNESS01')");
$db->exec("INSERT INTO wp_rzp_webhook_requests (integration, order_id, rzp_order_id, rzp_webhook_data, rzp_update_order_cron_status)
           VALUES ('woocommerce', 1234, 'order_RZPHARNESS01', '[]', 0)");

echo "state ready: order 1234 pending, payment_action=$action\n";
