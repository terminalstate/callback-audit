<?php
/**
 * php -S 127.0.0.1:8793 fake-api.php — plays api.razorpay.com for the plugin's SDK.
 *
 * The file state/api-scenario says how to answer GET /v1/payments/{id}:
 *   captured | authorized        200 with the payment in that status
 *   503                          503 Service Unavailable
 *   429                          429 with the body a store's log shows for Razorpay's rate limit
 *                                ("BadRequestError: Too many requests", razorpay-woocommerce#571)
 *   timeout                      no answer for 61 s; the SDK gives up after 60 s (razorpay-sdk/src/Request.php L53)
 * Every request is appended to state/api.log.
 */

declare(strict_types=1);

$state = getenv('STATE_DIR') ?: __DIR__ . '/state';
$scenario = trim((string) @file_get_contents("$state/api-scenario")) ?: 'captured';
$method = $_SERVER['REQUEST_METHOD'];
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
file_put_contents("$state/api.log", gmdate('c') . " $method $path -> $scenario\n", FILE_APPEND);

header('Content-Type: application/json');

function payment(string $id, string $status): array
{
    return [
        'id' => $id,
        'entity' => 'payment',
        'amount' => 49900,
        'currency' => 'INR',
        'status' => $status,
        'order_id' => 'order_RZPHARNESS01',
        'invoice_id' => null,
        'method' => 'upi',
        'captured' => $status === 'captured',
        'notes' => ['woocommerce_order_id' => '1234', 'woocommerce_order_number' => '1234'],
        'created_at' => time() - 400,
    ];
}

if (preg_match('#^/v1/payments/(pay_[A-Za-z0-9]+)$#', $path, $m) && $method === 'GET') {
    switch ($scenario) {
        case 'captured':
        case 'authorized':
            echo json_encode(payment($m[1], $scenario));
            exit;
        case '503':
            http_response_code(503);
            echo json_encode(['error' => ['code' => 'SERVER_ERROR', 'description' => 'Service unavailable']]);
            exit;
        case '429':
            http_response_code(429);
            echo json_encode(['error' => ['code' => 'BAD_REQUEST_ERROR', 'description' => 'Too many requests']]);
            exit;
        case 'timeout':
            sleep(61);
            echo json_encode(payment($m[1], 'captured'));
            exit;
    }
}

http_response_code(404);
echo json_encode(['error' => ['code' => 'BAD_REQUEST_ERROR', 'description' => 'The requested URL was not found on the server.']]);
