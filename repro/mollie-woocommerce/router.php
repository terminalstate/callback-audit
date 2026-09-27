<?php
/**
 * php -S router: serves the plugin's two webhook entry points with the plugin's own code.
 *
 *   POST /wp-json/mollie/v1/webhook                           -> RestApi::callback()          (default URL)
 *   POST /?wc-api=mollie_wc_gateway_ideal&order_id=..&key=..  -> MollieOrderService::onWebhookAction() (legacy)
 *
 * The request header X-Mollie-Api picks how the fake Mollie API answers the plugin's status fetch:
 *   paid | timeout | 503 | 429 | 404
 * Debug headers on the response: X-Order-Status (after the webhook), X-Handler (what ran),
 * X-Api-Calls (requests the plugin made to the Mollie API).
 */

declare(strict_types=1);

require __DIR__ . '/wp-stubs.php';

use Mollie\WooCommerce\Payment\MollieObject;
use Mollie\WooCommerce\Payment\MollieOrderService;
use Mollie\WooCommerce\Payment\MolliePayment;
use Mollie\WooCommerce\Payment\PaymentFactory;
use Mollie\WooCommerce\Payment\Request\RequestFactory;
use Mollie\WooCommerce\Payment\Webhooks\RestApi;
use Mollie\WooCommerce\Payment\Webhooks\WebhookHandler;
use Mollie\WooCommerce\Payment\Webhooks\WebhookSecret;
use Mollie\WooCommerce\SDK\Api;
use Mollie\WooCommerce\Settings\Settings;
use Mollie\WooCommerce\Settings\Webhooks\WebhookTestService;
use Mollie\WooCommerce\Shared\Data;
use Psr\Container\ContainerInterface;
use Psr\Log\AbstractLogger;

const PLUGIN_ID = 'mollie-payments-for-woocommerce';
const TX = 'tr_WDqYK6vllg';

// ---- the fake Mollie API ----------------------------------------------------------------------

$scenario = $_SERVER['HTTP_X_MOLLIE_API'] ?? 'paid';
$json = static function (int $code, array $body): array {
    return ['response' => ['code' => $code], 'body' => json_encode($body)];
};
$GLOBALS['mollie_api'] = static function (string $url, array $args) use ($scenario, $json) {
    switch ($scenario) {
        case 'paid':
            return $json(200, [
                'resource' => 'payment',
                'id' => TX,
                'mode' => 'live',
                'status' => 'paid',
                'method' => 'ideal',
                'paidAt' => '2026-09-26T21:14:02+00:00',
                'amount' => ['value' => '49.00', 'currency' => 'EUR'],
                'metadata' => ['order_id' => '1234'],
            ]);
        case 'timeout':
            return new WP_Error('http_request_failed', 'cURL error 28: Operation timed out after 10001 milliseconds with 0 bytes received');
        case '503':
            return $json(503, ['status' => 503, 'title' => 'Service Unavailable', 'detail' => 'The service is temporarily unavailable']);
        case '429':
            return $json(429, ['status' => 429, 'title' => 'Too Many Requests', 'detail' => 'You have exceeded the rate limit']);
        case '404':
            return $json(404, ['status' => 404, 'title' => 'Not Found', 'detail' => 'No payment exists with token ' . TX . '.']);
    }
    throw new RuntimeException("unknown scenario $scenario");
};

// ---- one pending order that the webhook is about ----------------------------------------------

$order = new WC_Order(1234, TX);
$GLOBALS['orders'] = [TX => $order];

// ---- the plugin's object graph; only the settings values and the final handler are replaced ----

$logger = new class extends AbstractLogger {
    public function log($level, $message, array $context = []): void
    {
        error_log("[$level] $message");
    }
};
$settings = new class extends Settings {
    public function __construct()
    {
    }

    public function isTestModeEnabled()
    {
        return false;
    }

    public function getApiKey(?bool $overrideTestMode = null)
    {
        return 'live_' . str_repeat('A', 30);
    }
};
$data = new class extends Data {
    public function __construct()
    {
    }

    public function getActiveMolliePaymentMode($orderId)
    {
        return 'live';
    }
};
$handled = 'none';
// The one replaced piece: the handler that marks a paid order as paid. Everything that decides
// whether it is reached (and what the webhook answers) is the plugin's own code.
$webhookHandler = new class ($handled) extends WebhookHandler {
    private $handled;

    public function __construct(&$handled)
    {
        $this->handled = &$handled;
    }

    public function onWebhookPaid(WC_Order $order, $payment, string $paymentMethodTitle, MollieObject $mollieObject): void
    {
        $this->handled = 'onWebhookPaid';
        $order->status = 'processing';
    }
};
$requestFactory = (new ReflectionClass(RequestFactory::class))->newInstanceWithoutConstructor();
$webhookSecret = (new ReflectionClass(WebhookSecret::class))->newInstanceWithoutConstructor();
$api = new Api('8.1.10', PLUGIN_ID);

$paymentFactory = new PaymentFactory(
    static function () {
        throw new LogicException('this demo only uses tr_ payments');
    },
    static function () use ($api, $settings, $data, $logger, $requestFactory) {
        return new MolliePayment(null, PLUGIN_ID, $api, $settings, $data, $logger, $requestFactory);
    }
);
$container = new class ($webhookSecret) implements ContainerInterface {
    private $secret;

    public function __construct($secret)
    {
        $this->secret = $secret;
    }

    public function get(string $id)
    {
        if ($id === WebhookSecret::class) {
            return $this->secret;
        }
        if ($id === 'payment_gateway.getPaymentMethod') {
            return static function ($gatewayId) {
                return null;
            };
        }
        throw new RuntimeException("not in the demo container: $id");
    }

    public function has(string $id)
    {
        return in_array($id, [WebhookSecret::class, 'payment_gateway.getPaymentMethod'], true);
    }
};
// The legacy endpoint reads the POSTed id with filter_input(), which works under php -S.
$orderService = new MollieOrderService(
    new Mollie\WooCommerce\SDK\HttpResponse(),
    $logger,
    $paymentFactory,
    $data,
    PLUGIN_ID,
    $container,
    $webhookHandler
);
$restApi = new RestApi(
    $orderService,
    $logger,
    (new ReflectionClass(WebhookTestService::class))->newInstanceWithoutConstructor(),
    $webhookSecret
);

// ---- dispatch ---------------------------------------------------------------------------------

$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($path === '/wp-json/mollie/v1/webhook') {
    // WordPress's REST server sends the WP_REST_Response status as the HTTP status.
    $response = $restApi->callback(new WP_REST_Request($_POST + $_GET));
    http_response_code($response->get_status());
} elseif (($_GET['wc-api'] ?? '') !== '') {
    $orderService->onWebhookAction();   // sets the status itself through HttpResponse
} else {
    http_response_code(404);
}
header('X-Order-Status: ' . $order->status);
header('X-Handler: ' . $handled);
header('X-Api-Calls: ' . count($GLOBALS['http_log']));
