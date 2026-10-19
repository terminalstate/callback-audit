<?php
// php notify.php <wc-order-id> <payu-order-id> <status> <second-key> — prints "<signature header>\n<body>": an order
// notification in PayU's format (developers.payu.com, "Notifications"), signed the way the OpenPayU SDK verifies it:
// OpenPayu-Signature: sender=checkout;signature=md5(body + second key);algorithm=MD5;content=DOCUMENT
[ , $wc, $payu, $status, $key ] = $argv;
$body = json_encode( array(
	'order' => array(
		'orderId' => $payu, 'extOrderId' => $wc . '_66f1e0a3b2c4d5.12345678', 'orderCreateDate' => '2026-10-18T10:00:00.000+02:00',
		'notifyUrl' => 'http://127.0.0.1/?wc-api=wc_gateway_payustandard', 'customerIp' => '127.0.0.1', 'merchantPosId' => '300746',
		'description' => '# ' . $wc . ' Stand', 'currencyCode' => 'PLN', 'totalAmount' => '25000', 'status' => $status,
		'products' => array( array( 'name' => 'Stand product', 'unitPrice' => '25000', 'quantity' => '1' ) ),
	),
	'localReceiptDateTime' => '2026-10-18T10:01:00.000+02:00',
	'properties' => array( array( 'name' => 'PAYMENT_ID', 'value' => '5000000001' ) ),
), JSON_UNESCAPED_SLASHES );
echo 'sender=checkout;signature=' . md5( $body . $key ) . ";algorithm=MD5;content=DOCUMENT\n" . $body;
