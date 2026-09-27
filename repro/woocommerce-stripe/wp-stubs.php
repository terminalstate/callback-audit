<?php
namespace Automattic\WooCommerce\Enums {
    class OrderStatus {
        const PENDING='pending'; const PROCESSING='processing'; const COMPLETED='completed';
        const ON_HOLD='on-hold'; const CANCELLED='cancelled'; const REFUNDED='refunded';
        const FAILED='failed'; const TRASH='trash';
    }
}
namespace {
    // Minimal WordPress/WooCommerce stubs: just enough to run the REAL
    // WC_Stripe_Webhook_Handler::check_for_webhook() + validate_request() path.
    // No database, no WP core. In-memory options only.
    define('ABSPATH', __DIR__ . '/work/');
    define('MINUTE_IN_SECONDS', 60);
    define('HOUR_IN_SECONDS', 3600);
    define('DAY_IN_SECONDS', 86400);
    define('WEEK_IN_SECONDS', 604800);

    $GLOBALS['__opts'] = [];
    function get_option($k, $d = false){ return $GLOBALS['__opts'][$k] ?? $d; }
    function update_option($k, $v, $a = null){ $GLOBALS['__opts'][$k] = $v; return true; }
    function delete_option($k){ unset($GLOBALS['__opts'][$k]); return true; }
    function add_action(){ return true; }
    function add_filter(){ return true; }
    function do_action(){ return true; }
    function apply_filters($tag, $value){ return $value; }
    function __($t, $d = null){ return $t; }
    function esc_html__($t, $d = null){ return $t; }
    function status_header($code){ http_response_code($code); $GLOBALS['__status'] = $code; }

    if (!defined('STORE_WEBHOOK_SECRET')) define('STORE_WEBHOOK_SECRET', getenv('STORE_WEBHOOK_SECRET') ?: 'whsec_store_configured_secret');

    class WC_Stripe_Payment_Gateway {}  // lightweight parent; real one is WooCommerce core
    class WC_Stripe_Action_Scheduler_Service {}
    class WC_Stripe_Mode { public static function is_test(){ return true; } }
    class WC_Stripe_Helper {
        public static function get_stripe_settings(){ return ['test_webhook_secret' => STORE_WEBHOOK_SECRET]; }
        public static function get_settings($a = null, $b = null){ return ''; }
    }
    class WC_Stripe_Logger {
        public static function log($m, $c = []){ self::w('LOG', $m); }
        public static function error($m, $c = []){ self::w('ERROR', $m); }
        public static function debug($m, $c = []){ self::w('DEBUG', $m); }
        public static function info($m, $c = []){ self::w('INFO', $m); }
        private static function w($lvl, $m){
            $line = gmdate('Y-m-d\TH:i:s\Z')." $lvl ".(is_string($m)?$m:json_encode($m))."\n";
            @file_put_contents(getenv('APP_LOG') ?: __DIR__ . '/work/app.log', $line, FILE_APPEND);
        }
    }
    class WC_Stripe_Agentic_Commerce_Integration { const WEBHOOK_SECRET_OPTION = 'wc_stripe_agentic_webhook_secret'; }
}
