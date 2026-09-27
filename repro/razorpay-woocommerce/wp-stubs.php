<?php
/**
 * The smallest WordPress/WooCommerce surface that the Razorpay plugin touches on its webhook,
 * cron and browser-callback paths, so that the plugin's own code runs unchanged under PHP's
 * built-in server.
 *
 * Real: everything in the plugin directory (woo-razorpay.php, includes/, razorpay-sdk/ with its
 * bundled Requests library). Fake: WordPress and WooCommerce. Their state (options, orders stored
 * the pre-HPOS way in wp_posts/wp_postmeta, order notes, and the plugin's own
 * wp_rzp_webhook_requests table) lives in one SQLite file, so it survives between requests the way
 * a MySQL database would. $wpdb passes the plugin's SQL straight to SQLite.
 */

declare(strict_types=1);

define('ABSPATH', __DIR__ . '/wp/');
define('WPINC', 'wp-includes');
define('WOOCOMMERCE_VERSION', '10.1.0');
define('OBJECT', 'OBJECT');
define('ARRAY_A', 'ARRAY_A');
define('ARRAY_N', 'ARRAY_N');
define('HOUR_IN_SECONDS', 3600);
define('DAY_IN_SECONDS', 86400);

const HARNESS_HOME = 'http://127.0.0.1:8792';

$GLOBALS['harness_state'] = getenv('STATE_DIR') ?: __DIR__ . '/state';
$GLOBALS['harness_plugin'] = getenv('PLUGIN_DIR') ?: __DIR__ . '/razorpay-woocommerce';

function harness_db(): PDO
{
    static $pdo = null;
    if ($pdo === null) {
        $pdo = new PDO('sqlite:' . $GLOBALS['harness_state'] . '/wp.sqlite');
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec('PRAGMA busy_timeout = 5000');
    }
    return $pdo;
}

function harness_log(string $file, string $line): void
{
    file_put_contents($GLOBALS['harness_state'] . '/' . $file, $line . "\n", FILE_APPEND);
}

// ---- $wpdb: the plugin's SQL goes to SQLite unchanged ------------------------------------------

class Harness_WPDB
{
    public $prefix = 'wp_';
    public $posts = 'wp_posts';
    public $postmeta = 'wp_postmeta';
    public $options = 'wp_options';
    public $last_error = '';
    public $insert_id = 0;

    public function get_results($sql, $output = OBJECT)
    {
        $rows = harness_db()->query($sql)->fetchAll(PDO::FETCH_ASSOC);
        if ($output === ARRAY_A) {
            return $rows;
        }
        return array_map(static fn ($r) => (object) $r, $rows);
    }

    public function get_row($sql, $output = OBJECT)
    {
        $rows = $this->get_results($sql, $output);
        return $rows[0] ?? null;
    }

    public function get_var($sql)
    {
        $row = harness_db()->query($sql)->fetch(PDO::FETCH_NUM);
        return $row === false ? null : $row[0];
    }

    public function query($sql)
    {
        return harness_db()->exec($sql);
    }

    public function prepare($query, ...$args)
    {
        if (count($args) === 1 && is_array($args[0])) {
            $args = $args[0];
        }
        $i = 0;
        return preg_replace_callback('/%[sdf]/', static function ($m) use (&$i, $args) {
            $v = $args[$i++] ?? '';
            return $m[0] === '%s' ? harness_db()->quote((string) $v) : (string) (0 + $v);
        }, $query);
    }

    public function insert($table, $data, $format = null)
    {
        $cols = array_keys($data);
        $stmt = harness_db()->prepare(
            "INSERT INTO $table (" . implode(',', $cols) . ') VALUES (' . implode(',', array_fill(0, count($cols), '?')) . ')'
        );
        $stmt->execute(array_values($data));
        $this->insert_id = (int) harness_db()->lastInsertId();
        return 1;
    }

    /** Returns the number of rows updated, like wpdb::update(). */
    public function update($table, $data, $where, $format = null, $where_format = null)
    {
        $set = implode(',', array_map(static fn ($c) => "$c = ?", array_keys($data)));
        $cond = implode(' AND ', array_map(static fn ($c) => "$c = ?", array_keys($where)));
        $stmt = harness_db()->prepare("UPDATE $table SET $set WHERE $cond");
        $stmt->execute(array_merge(array_values($data), array_values($where)));
        return $stmt->rowCount();
    }

    public function get_charset_collate()
    {
        return '';
    }
}

$GLOBALS['wpdb'] = new Harness_WPDB();

// ---- hooks: a real registry, so admin-post.php, wp-cron.php and wc-api fire the plugin's own hooks

$GLOBALS['wp_filter'] = [];

function add_filter($hook, $cb, $priority = 10, $accepted_args = 1)
{
    $GLOBALS['wp_filter'][$hook][$priority][] = [$cb, $accepted_args];
    return true;
}

function add_action($hook, $cb, $priority = 10, $accepted_args = 1)
{
    return add_filter($hook, $cb, $priority, $accepted_args);
}

function has_action($hook, $cb = false)
{
    return !empty($GLOBALS['wp_filter'][$hook]);
}

function has_filter($hook, $cb = false)
{
    return has_action($hook, $cb);
}

function remove_action($hook, $cb, $priority = 10)
{
    return true;
}

function remove_filter($hook, $cb, $priority = 10)
{
    return true;
}

function apply_filters($hook, $value, ...$args)
{
    if (empty($GLOBALS['wp_filter'][$hook])) {
        return $value;
    }
    ksort($GLOBALS['wp_filter'][$hook]);
    foreach ($GLOBALS['wp_filter'][$hook] as $callbacks) {
        foreach ($callbacks as [$cb, $n]) {
            $value = call_user_func_array($cb, array_slice(array_merge([$value], $args), 0, max(1, $n)));
        }
    }
    return $value;
}

function do_action($hook, ...$args)
{
    $GLOBALS['wp_actions'][$hook] = ($GLOBALS['wp_actions'][$hook] ?? 0) + 1;
    if (empty($GLOBALS['wp_filter'][$hook])) {
        return;
    }
    ksort($GLOBALS['wp_filter'][$hook]);
    foreach ($GLOBALS['wp_filter'][$hook] as $callbacks) {
        foreach ($callbacks as [$cb, $n]) {
            call_user_func_array($cb, array_slice($args, 0, $n));
        }
    }
}

/** Like WordPress: the array's elements reach the callbacks by reference. */
function do_action_ref_array($hook, $args)
{
    $GLOBALS['wp_actions'][$hook] = ($GLOBALS['wp_actions'][$hook] ?? 0) + 1;
    if (empty($GLOBALS['wp_filter'][$hook])) {
        return;
    }
    ksort($GLOBALS['wp_filter'][$hook]);
    foreach ($GLOBALS['wp_filter'][$hook] as $callbacks) {
        foreach ($callbacks as [$cb, $n]) {
            call_user_func_array($cb, $args);
        }
    }
}

function did_action($hook)
{
    return $GLOBALS['wp_actions'][$hook] ?? 0;
}

function register_activation_hook($file, $cb)
{
}

function register_deactivation_hook($file, $cb)
{
}

function register_uninstall_hook($file, $cb)
{
}

// ---- options, transients, meta -----------------------------------------------------------------

function get_option($name, $default = false)
{
    $stmt = harness_db()->prepare('SELECT option_value FROM wp_options WHERE option_name = ?');
    $stmt->execute([$name]);
    $v = $stmt->fetchColumn();
    return $v === false ? $default : unserialize($v);
}

function update_option($name, $value, $autoload = null)
{
    harness_db()->prepare('INSERT OR REPLACE INTO wp_options (option_name, option_value) VALUES (?, ?)')
        ->execute([$name, serialize($value)]);
    return true;
}

function add_option($name, $value = '', $deprecated = '', $autoload = 'yes')
{
    if (get_option($name, null) !== null) {
        return false;
    }
    return update_option($name, $value);
}

function delete_option($name)
{
    harness_db()->prepare('DELETE FROM wp_options WHERE option_name = ?')->execute([$name]);
    return true;
}

$GLOBALS['harness_transients'] = [];

function get_transient($k)
{
    return $GLOBALS['harness_transients'][$k] ?? false;
}

function set_transient($k, $v, $ttl = 0)
{
    $GLOBALS['harness_transients'][$k] = $v;
    return true;
}

function delete_transient($k)
{
    unset($GLOBALS['harness_transients'][$k]);
    return true;
}

function get_post_meta($id, $key = '', $single = false)
{
    $stmt = harness_db()->prepare('SELECT meta_value FROM wp_postmeta WHERE post_id = ? AND meta_key = ?');
    $stmt->execute([(int) $id, $key]);
    $v = $stmt->fetchColumn();
    return $v === false ? ($single ? '' : []) : $v;
}

function update_post_meta($id, $key, $value)
{
    harness_db()->prepare('DELETE FROM wp_postmeta WHERE post_id = ? AND meta_key = ?')->execute([(int) $id, $key]);
    harness_db()->prepare('INSERT INTO wp_postmeta (post_id, meta_key, meta_value) VALUES (?, ?, ?)')
        ->execute([(int) $id, $key, (string) $value]);
    return true;
}

// ---- misc WordPress functions the plugin calls while loading or on these paths -----------------

function __($s, $d = null)
{
    return $s;
}

function _e($s, $d = null)
{
    echo $s;
}

function esc_html($s)
{
    return (string) $s;
}

function esc_attr($s)
{
    return (string) $s;
}

function esc_url($s)
{
    return (string) $s;
}

function esc_html__($s, $d = null)
{
    return $s;
}

function esc_attr__($s, $d = null)
{
    return $s;
}

function sanitize_text_field($s)
{
    return trim(strip_tags((string) $s));
}

function wp_unslash($s)
{
    return $s;
}

function wp_json_encode($data, $options = 0, $depth = 512)
{
    return json_encode($data, $options, $depth);
}

function absint($v)
{
    return abs((int) $v);
}

function is_admin()
{
    return defined('WP_ADMIN') && WP_ADMIN;
}

function is_user_logged_in()
{
    return false;
}

function current_user_can($cap, ...$args)
{
    return false;
}

function is_plugin_active($plugin)
{
    return $plugin === 'woocommerce/woocommerce.php';
}

function admin_url($path = '')
{
    return HARNESS_HOME . '/wp-admin/' . ltrim($path, '/');
}

function home_url($path = '')
{
    return HARNESS_HOME . '/' . ltrim($path, '/');
}

function site_url($path = '')
{
    return home_url($path);
}

function get_site_url()
{
    return HARNESS_HOME;
}

function plugin_dir_path($file)
{
    return rtrim(dirname($file), '/') . '/';
}

function plugin_dir_url($file)
{
    return HARNESS_HOME . '/wp-content/plugins/woo-razorpay/';
}

function plugins_url($path = '', $plugin = '')
{
    return HARNESS_HOME . '/wp-content/plugins/woo-razorpay/' . ltrim($path, '/');
}

function plugin_basename($file)
{
    return 'woo-razorpay/woo-razorpay.php';
}

function get_bloginfo($show = '')
{
    return $show === 'version' ? '6.8.2' : 'Harness Store';
}

function wp_next_scheduled($hook, $args = [])
{
    return time() + 60;   // treat the plugin's cron events as already scheduled
}

function wp_schedule_event($ts, $recurrence, $hook, $args = [])
{
    return true;
}

function wp_clear_scheduled_hook($hook, $args = [])
{
    return 0;
}

function wp_redirect($location, $status = 302)
{
    header('Location: ' . $location, true, $status);
    return true;
}

function wp_safe_redirect($location, $status = 302)
{
    return wp_redirect($location, $status);
}

function is_wp_error($thing)
{
    return false;
}

/** Outbound HTTP through WordPress (the plugin's telemetry): recorded, never sent. */
function wp_remote_post($url, $args = [])
{
    harness_log('outbound.log', 'POST ' . $url . ' ' . substr((string) ($args['body'] ?? ''), 0, 300));
    return ['response' => ['code' => 200], 'body' => '{}'];
}

function wp_remote_get($url, $args = [])
{
    harness_log('outbound.log', 'GET ' . $url);
    return ['response' => ['code' => 200], 'body' => '{}'];
}

function wp_remote_retrieve_body($r)
{
    return $r['body'] ?? '';
}

function wp_remote_retrieve_response_code($r)
{
    return $r['response']['code'] ?? '';
}

function get_plugin_data($file, $markup = true, $translate = true)
{
    return ['Version' => '4.8.8', 'Name' => 'Razorpay for WooCommerce'];
}

function wp_enqueue_script(...$a)
{
}

function wp_register_script(...$a)
{
}

function wp_enqueue_style(...$a)
{
}

function wp_localize_script(...$a)
{
}

// ---- WooCommerce -------------------------------------------------------------------------------

function wc_get_base_location()
{
    return ['country' => 'IN', 'state' => 'KA'];
}

function get_woocommerce_currency()
{
    return 'INR';
}

function wc_add_notice($message, $notice_type = 'success', $data = [])
{
}

function wc_get_checkout_url()
{
    return HARNESS_HOME . '/checkout/';
}

function wc_get_cart_url()
{
    return HARNESS_HOME . '/cart/';
}

/** WooCommerce's logger; the plugin logs under source "razorpay-logs". */
function wc_get_logger()
{
    return new class {
        public function log($level, $message, $context = [])
        {
            harness_log('razorpay-logs.log', gmdate('c') . ' ' . strtoupper($level) . ' ' . $message);
        }

        public function __call($level, $args)
        {
            $this->log($level, $args[0] ?? '', $args[1] ?? []);
        }
    };
}

class WC_Settings_API
{
    public $id = '';
    public $settings = [];
    public $form_fields = [];

    public function get_option_key()
    {
        return 'woocommerce_' . $this->id . '_settings';
    }

    public function get_form_fields()
    {
        return $this->form_fields;
    }

    public function init_settings()
    {
        $this->settings = get_option($this->get_option_key(), null);
        if (!is_array($this->settings)) {
            $this->settings = [];
            foreach ($this->get_form_fields() as $k => $f) {
                $this->settings[$k] = $f['default'] ?? '';
            }
        }
    }

    public function get_option($key, $empty_value = null)
    {
        if (empty($this->settings)) {
            $this->init_settings();
        }
        if (!isset($this->settings[$key])) {
            $fields = $this->get_form_fields();
            $this->settings[$key] = isset($fields[$key]) ? ($fields[$key]['default'] ?? '') : '';
        }
        if ($empty_value !== null && $this->settings[$key] === '') {
            $this->settings[$key] = $empty_value;
        }
        return $this->settings[$key];
    }

    public function update_option($key, $value = '')
    {
        if (empty($this->settings)) {
            $this->init_settings();
        }
        $this->settings[$key] = $value;
        return update_option($this->get_option_key(), $this->settings);
    }

    public function process_admin_options()
    {
        return true;
    }
}

class WC_Payment_Gateway extends WC_Settings_API
{
    public $title = '';
    public $description = '';
    public $enabled = 'yes';

    public function get_return_url($order = null)
    {
        return HARNESS_HOME . '/checkout/order-received/' . ($order ? $order->get_id() : '') . '/';
    }
}

/** An order stored the pre-HPOS way: status in wp_posts, everything else in wp_postmeta. */
class WC_Order
{
    private $id;

    public function __construct($id)
    {
        $this->id = (int) $id;
    }

    public function get_id()
    {
        return $this->id;
    }

    public function get_order_number()
    {
        return (string) $this->id;
    }

    public function get_status()
    {
        $stmt = harness_db()->prepare('SELECT post_status FROM wp_posts WHERE ID = ?');
        $stmt->execute([$this->id]);
        return preg_replace('/^wc-/', '', (string) $stmt->fetchColumn());
    }

    public function has_status($status)
    {
        return in_array($this->get_status(), (array) $status, true);
    }

    public function get_total()
    {
        return (float) get_post_meta($this->id, '_order_total', true);
    }

    public function get_discount_total()
    {
        return 0.0;
    }

    public function get_currency()
    {
        return 'INR';
    }

    public function get_payment_method()
    {
        return get_post_meta($this->id, '_payment_method', true);
    }

    public function get_created_via()
    {
        return get_post_meta($this->id, '_created_via', true);
    }

    public function get_order_key()
    {
        return get_post_meta($this->id, '_order_key', true);
    }

    public function get_transaction_id()
    {
        return get_post_meta($this->id, '_transaction_id', true);
    }

    public function get_meta($key = '', $single = true)
    {
        return get_post_meta($this->id, $key, true);
    }

    public function update_meta_data($key, $value)
    {
        update_post_meta($this->id, $key, $value);
    }

    public function save()
    {
        return $this->id;
    }

    /** Same rule as WooCommerce: pending and failed orders with a total above zero need payment. */
    public function needs_payment()
    {
        return $this->has_status(['pending', 'failed']) && $this->get_total() > 0;
    }

    public function add_order_note($note, $is_customer_note = 0, $added_by_user = false)
    {
        harness_db()->prepare('INSERT INTO wp_harness_notes (order_id, note) VALUES (?, ?)')
            ->execute([$this->id, strip_tags(str_replace('<br/>', ' ', (string) $note))]);
        return 1;
    }

    public function set_status($new_status, $note = '', $manual = false)
    {
        $new_status = preg_replace('/^wc-/', '', $new_status);
        harness_db()->prepare('UPDATE wp_posts SET post_status = ? WHERE ID = ?')->execute(['wc-' . $new_status, $this->id]);
    }

    public function update_status($new_status, $note = '', $manual = false)
    {
        $old = $this->get_status();
        $this->set_status($new_status);
        $this->add_order_note(trim($note . ' Order status changed from ' . $old . ' to ' . preg_replace('/^wc-/', '', $new_status) . '.'));
        return true;
    }

    /** What matters here from WC_Order::payment_complete(): same status rule, transaction id, Processing. */
    public function payment_complete($transaction_id = '')
    {
        if (!$this->has_status(['on-hold', 'pending', 'failed', 'cancelled'])) {
            return true;
        }
        if ($transaction_id) {
            update_post_meta($this->id, '_transaction_id', $transaction_id);
        }
        $this->update_status('processing');
        return true;
    }
}

function wc_get_order($id = false)
{
    $stmt = harness_db()->prepare("SELECT ID FROM wp_posts WHERE ID = ? AND post_type = 'shop_order'");
    $stmt->execute([(int) $id]);
    return $stmt->fetchColumn() === false ? false : new WC_Order($id);
}
