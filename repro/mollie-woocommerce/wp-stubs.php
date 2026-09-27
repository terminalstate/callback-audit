<?php
/**
 * The smallest WordPress/WooCommerce surface the Mollie webhook path touches, so that the
 * plugin's own code (REST callback -> order service -> payment object -> SDK -> HTTP adapter)
 * runs unchanged in the CLI. Only the edges are fake: the order store, the gateway lookup,
 * options, and wp_remote_request(), whose answer each scenario decides.
 */

declare(strict_types=1);

define('ABSPATH', __DIR__ . '/');

$pluginDir = getenv('PLUGIN_DIR') ?: __DIR__ . '/mollie-woocommerce';
$depsDir = __DIR__ . '/deps';

spl_autoload_register(static function (string $class) use ($pluginDir, $depsDir): void {
    $map = [
        'Mollie\\WooCommerce\\' => "$pluginDir/src/",
        'Mollie\\Api\\' => "$depsDir/mollie-api-php/src/",
        'Psr\\Log\\' => "$depsDir/log/Psr/Log/",
        'Psr\\Container\\' => "$depsDir/container/src/",
        'Composer\\CaBundle\\' => "$depsDir/ca-bundle/src/",
    ];
    foreach ($map as $prefix => $dir) {
        if (strncmp($class, $prefix, strlen($prefix)) === 0) {
            $file = $dir . str_replace('\\', '/', substr($class, strlen($prefix))) . '.php';
            if (is_file($file)) {
                require $file;
            }
            return;
        }
    }
});

// ---- scenario control ------------------------------------------------------------------------

$GLOBALS['mollie_api'] = null;   // callable(string $url, array $args): array|WP_Error
$GLOBALS['http_log'] = [];
$GLOBALS['orders'] = [];         // transaction id => WC_Order

// ---- WordPress --------------------------------------------------------------------------------

class WP_Error
{
    private $code;
    private $message;

    public function __construct($code = '', $message = '')
    {
        $this->code = $code;
        $this->message = $message;
    }

    public function get_error_code()
    {
        return $this->code;
    }

    public function get_error_message()
    {
        return $this->message;
    }
}

class WP_REST_Request
{
    private $params;

    public function __construct(array $params)
    {
        $this->params = $params;
    }

    public function get_param($key)
    {
        return $this->params[$key] ?? null;
    }
}

class WP_REST_Response
{
    public $data;
    public $status;

    public function __construct($data = null, $status = 200)
    {
        $this->data = $data;
        $this->status = $status;
    }

    public function get_status()
    {
        return $this->status;
    }
}

function is_wp_error($thing): bool
{
    return $thing instanceof WP_Error;
}

function wp_remote_request($url, $args)
{
    $GLOBALS['http_log'][] = $args['method'] . ' ' . $url;
    return ($GLOBALS['mollie_api'])($url, $args);
}

function wp_remote_retrieve_response_code($response)
{
    return $response['response']['code'] ?? '';
}

function wp_remote_retrieve_body($response)
{
    return $response['body'] ?? '';
}

function esc_html($s)
{
    return (string) $s;
}

function esc_html__($s, $domain = null)
{
    return (string) $s;
}

function __($s, $domain = null)
{
    return (string) $s;
}

function apply_filters($tag, $value, ...$args)
{
    return $value;
}

function has_filter($tag, $callback = false)
{
    return false;
}

function add_filter(...$args)
{
    return true;
}

function do_action($tag, ...$args): void
{
}

function get_option($name, $default = false)
{
    return $default;
}

function sanitize_text_field($s)
{
    return trim((string) $s);
}

function wp_unslash($s)
{
    return $s;
}

// ---- WooCommerce ------------------------------------------------------------------------------

class WC_Payment_Gateway
{
    public $id = 'mollie_wc_gateway_ideal';
    public $method_title = 'iDEAL';
}

class WC_Order
{
    public $status = 'pending';
    public $notes = [];
    private $id;
    private $transactionId;
    private $meta = [];

    public function __construct(int $id, string $transactionId)
    {
        $this->id = $id;
        $this->transactionId = $transactionId;
    }

    public function get_id()
    {
        return $this->id;
    }

    public function get_transaction_id()
    {
        return $this->transactionId;
    }

    public function get_meta($key = '', $single = true)
    {
        return $this->meta[$key] ?? '';
    }

    public function needs_payment()
    {
        return in_array($this->status, ['pending', 'failed'], true);
    }

    public function has_status($status)
    {
        return in_array($this->status, (array) $status, true);
    }

    public function get_status()
    {
        return $this->status;
    }

    public function add_order_note($note)
    {
        $this->notes[] = $note;
    }

    public function key_is_valid($key)
    {
        return $key === 'wc_order_demo';
    }
}

function wc_get_orders($args)
{
    $id = $args['transaction_id'] ?? ($args['meta_value'] ?? null);
    return isset($GLOBALS['orders'][$id]) ? [$GLOBALS['orders'][$id]] : [];
}

function wc_get_order($id)
{
    foreach ($GLOBALS['orders'] as $order) {
        if ($order->get_id() === (int) $id) {
            return $order;
        }
    }
    return false;
}

function wc_get_payment_gateway_by_order($order)
{
    return new WC_Payment_Gateway();
}

function wc_get_base_location()
{
    return ['country' => 'NL', 'state' => ''];
}

// The plugin's own helpers (mollieWooCommerceIsMollieGateway and friends), unchanged.
require $pluginDir . '/inc/utils.php';
