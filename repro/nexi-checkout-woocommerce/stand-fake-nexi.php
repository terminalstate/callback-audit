<?php
// Stand only: answers the plugin's calls to the Nexi Checkout API (test.api.dibspayment.eu / api.dibspayment.eu); nothing else is touched.
// GET /v1/payments/<id> follows the option stand_nexi_get: "fail_then_ok" (first call times out, later calls answer "charged"),
// "ok" (always charged), "503". Every call is appended to the option stand_nexi_calls as "METHOD path".
add_filter( 'pre_http_request', function ( $pre, $args, $url ) {
	if ( ! preg_match( '#^https://(test\.)?api\.dibspayment\.eu/v1/(.*)$#', $url, $m ) ) {
		return $pre;
	}
	$method = strtoupper( $args['method'] ?? 'GET' );
	$calls  = (array) get_option( 'stand_nexi_calls', array() );
	$calls[] = $method . ' ' . $m[2];
	update_option( 'stand_nexi_calls', $calls, false );
	$json = function ( $code, $body ) {
		return array( 'headers' => array(), 'body' => wp_json_encode( $body ), 'response' => array( 'code' => $code, 'message' => 200 === $code ? 'OK' : 'Error' ),
			'cookies' => array(), 'filename' => null );
	};
	if ( 'GET' === $method && preg_match( '#^payments/([0-9a-f]{32})$#', $m[2], $p ) ) {
		$mode = get_option( 'stand_nexi_get', 'ok' );
		$gets = count( array_filter( $calls, fn( $c ) => 0 === strpos( $c, 'GET payments/' ) ) );
		if ( '503' === $mode ) {
			return $json( 503, array( 'message' => 'Service unavailable' ) );
		}
		if ( 'fail_then_ok' === $mode && 1 === $gets ) {
			return new WP_Error( 'http_request_failed', 'cURL error 28: Operation timed out after 10001 milliseconds with 0 bytes received' );
		}
		$amount = (int) get_option( 'stand_nexi_amount' );
		return $json( 200, array( 'payment' => array( 'paymentId' => $p[1],
			'summary' => array( 'reservedAmount' => $amount, 'chargedAmount' => $amount ),
			'paymentDetails' => array( 'paymentType' => 'A2A', 'paymentMethod' => 'Swish' ),
			'orderDetails' => array( 'amount' => $amount, 'currency' => 'SEK', 'reference' => (string) get_option( 'stand_nexi_reference' ) ),
			'charges' => array( array( 'chargeId' => 'c-1', 'amount' => $amount ) ) ) ) );
	}
	return $json( 200, array() ); // cancels, charges, refunds, reference updates: recorded above, answered as accepted
}, 10, 3 );
add_filter( 'pre_wp_mail', '__return_true' ); // the stand has no mail server
