<?php
// Router for `php -S`: a stand-in BTCPay Server Greenfield API. The plugin's own HTTP client (greenfield-php CurlClient)
// really connects to it. Mode from the file named by STAND_MODE_FILE: "outage" — GET invoice answers 503 (BTCPay
// restarting / overloaded); "ok" — it answers the invoice as Settled. Every request is appended to STAND_LOG_FILE.
$mode = trim( (string) @file_get_contents( getenv( 'STAND_MODE_FILE' ) ) ) ?: 'ok';
$path = parse_url( $_SERVER['REQUEST_URI'], PHP_URL_PATH );
if ( 'GET' === $_SERVER['REQUEST_METHOD'] && preg_match( '#^/api/v1/stores/([^/]+)/invoices/([^/]+)$#', $path, $m ) ) {
	if ( 'outage' === $mode ) {
		$code = 503;
		$body = array( 'code' => 'service-unavailable', 'message' => 'Service Unavailable' );
	} else {
		$code = 200;
		$body = array(
			'id' => $m[2], 'storeId' => $m[1], 'amount' => '25.00', 'currency' => 'USD', 'type' => 'Standard',
			'checkoutLink' => 'http://127.0.0.1/i/' . $m[2], 'status' => 'Settled', 'additionalStatus' => 'None',
			'createdTime' => 1791800000, 'expirationTime' => 1791800900, 'monitoringExpiration' => 1791886400,
			'archived' => false, 'metadata' => array( 'orderId' => 'stand' ), 'checkout' => array( 'speedPolicy' => 'MediumSpeed' ),
		);
	}
} else {
	$code = 404;
	$body = array( 'code' => 'not-found', 'message' => 'not faked by the stand' );
}
http_response_code( $code );
header( 'Content-Type: application/json' );
echo json_encode( $body );
file_put_contents( getenv( 'STAND_LOG_FILE' ), $_SERVER['REQUEST_METHOD'] . " $path ($mode) -> $code\n", FILE_APPEND );
