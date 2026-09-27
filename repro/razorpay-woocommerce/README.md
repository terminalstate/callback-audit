# Harness: Razorpay for WooCommerce, webhook → cron → order

Runs the plugin's own webhook handler, webhook cron and browser callback under PHP's built-in
server, with WordPress and WooCommerce stubbed and the Razorpay API played by a second local
server. Write-up: [docs/case-razorpay-woocommerce.md](../../docs/case-razorpay-woocommerce.md).

Needs PHP 8.1+ with the `curl`, `pdo_sqlite` and `json` extensions, and `curl` on the command line.

```
git clone https://github.com/razorpay/razorpay-woocommerce
git -C razorpay-woocommerce checkout d8138d762de986b533eb67b8298b2478524d0f39   # 4.8.8
./run.sh                 # about a minute; one scenario waits for the SDK's 60 s timeout
./run.sh --real-clock    # waits the plugin's real five-minute cron window instead of backdating
ONLY="API 503" ./run.sh  # one scenario
```

`PLUGIN_DIR=/path/to/plugin ./run.sh` points it at another checkout.

## What is real and what is not

| Part | |
|---|---|
| `woo-razorpay.php`, `includes/`, `razorpay-sdk/` (with its bundled Requests library) | **real**, loaded the way WordPress loads a plugin: `require`, then `plugins_loaded` |
| Webhook entry | what `wp-admin/admin-post.php` does for a visitor who is not logged in: fire `admin_post_nopriv_rzp_wc_webhook`, then end the request |
| Cron entry | fire `rzp_webhook_exec_cron`, as WP-Cron does when the event is due |
| Callback entry | construct the gateway and fire `woocommerce_api_razorpay`, as WooCommerce's `wc-api` dispatch does |
| WordPress, WooCommerce (`wp-stubs.php`) | stubbed; options, the order (stored the pre-HPOS way in `wp_posts`/`wp_postmeta`), its notes and the plugin's `wp_rzp_webhook_requests` table are in SQLite, and `$wpdb` hands the plugin's SQL to SQLite unchanged |
| Razorpay API (`fake-api.php`) | fake; the SDK is pointed at it through its own `Api::$baseUrl` and makes real HTTP requests |

`setup.php` seeds one order (#1234, INR 499.00, *Pending payment*) and the queue row that the
plugin's `createRazorpayOrderId()` inserts when it creates the Razorpay order.

After each run, `state/razorpay-logs.log` is the plugin's own log (what WooCommerce shows under
Status → Logs, source `razorpay-logs`), `state/api.log` lists the plugin's requests to the fake
API, and `state/outbound.log` the telemetry calls it tried to make (recorded, never sent).

## Files

- `run.sh`: starts both servers, runs the scenarios, prints the table
- `setup.php`: fresh state for one scenario (`capture` or `authorize` as the Payment Action)
- `send-webhook.php`: one signed `payment.authorized` delivery (`good`, `bad` or `none` signature)
- `send-callback.php`: the customer's browser coming back from checkout
- `backdate.php`: moves the queued event's timestamp back 301 s instead of waiting for the cron window
- `router.php`: the store (`php -S 127.0.0.1:8792`)
- `fake-api.php`: the Razorpay API (`php -S 127.0.0.1:8793`)
- `wp-stubs.php`, `wp/`: the WordPress and WooCommerce surface the plugin touches on these paths
