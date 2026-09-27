<?php
/**
 * The customer's browser coming back from Razorpay Checkout for order 1234: what checkout.js posts
 * to the store's callback URL after a successful payment. razorpay_signature is
 * HMAC-SHA256("order_id|payment_id") with the API key secret, as Razorpay computes it.
 * Prints the HTTP status and the redirect.
 */

declare(strict_types=1);

$orderId = 'order_RZPHARNESS01';
$paymentId = 'pay_RZPHARNESS01';
$post = http_build_query([
    'razorpay_payment_id' => $paymentId,
    'razorpay_order_id' => $orderId,
    'razorpay_signature' => hash_hmac('sha256', "$orderId|$paymentId", 'harness_key_secret_0001'),
]);

$ch = curl_init('http://127.0.0.1:8792/?wc-api=razorpay&order_key=wc_order_HARNESS1234');
curl_setopt_array($ch, [
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => $post,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_HEADER => true,
    CURLOPT_TIMEOUT => 120,
]);
$out = (string) curl_exec($ch);
$code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
preg_match('/^Location: (.*)$/mi', $out, $m);
echo $code, isset($m[1]) ? ' -> ' . trim($m[1]) : '', "\n";
