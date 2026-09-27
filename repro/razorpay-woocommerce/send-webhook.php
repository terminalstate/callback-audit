<?php
/**
 * POST one payment.authorized webhook for order 1234 to the store, like Razorpay does:
 *   php send-webhook.php <good|bad|none>
 * good: X-Razorpay-Signature = HMAC-SHA256 of the raw body with the secret the store holds;
 * bad:  the same, with the secret changed by one character; none: no signature header.
 * Prints the HTTP status the store answered.
 */

declare(strict_types=1);

$mode = $argv[1] ?? 'good';
$body = json_encode([
    'entity' => 'event',
    'account_id' => 'acc_HARNESS0000001',
    'event' => 'payment.authorized',
    'contains' => ['payment'],
    'payload' => ['payment' => ['entity' => [
        'id' => 'pay_RZPHARNESS01',
        'entity' => 'payment',
        'amount' => 49900,
        'currency' => 'INR',
        'status' => 'authorized',
        'order_id' => 'order_RZPHARNESS01',
        'invoice_id' => null,
        'method' => 'upi',
        'captured' => false,
        'notes' => ['woocommerce_order_id' => '1234', 'woocommerce_order_number' => '1234'],
        'created_at' => time(),
    ]]],
    'created_at' => time(),
], JSON_UNESCAPED_SLASHES);

$secret = 'harness_webhook_secret_0001';
$headers = ['Content-Type: application/json'];
if ($mode === 'good') {
    $headers[] = 'X-Razorpay-Signature: ' . hash_hmac('sha256', $body, $secret);
} elseif ($mode === 'bad') {
    $headers[] = 'X-Razorpay-Signature: ' . hash_hmac('sha256', $body, $secret . 'x');
}

$ch = curl_init('http://127.0.0.1:8792/wp-admin/admin-post.php?action=rzp_wc_webhook');
curl_setopt_array($ch, [
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => $body,
    CURLOPT_HTTPHEADER => $headers,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT => 120,
]);
$out = curl_exec($ch);
$code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
echo $code, ($out !== '' && $out !== false ? ' body=' . substr((string) $out, 0, 200) : ''), "\n";
