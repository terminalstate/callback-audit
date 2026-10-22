<?php
// Stand only: answers the plugin's calls to the GoCardless API (api-sandbox / api.gocardless.com); nothing else is touched.
// GET billing_requests/BR… follows the option stand_gc_br: "fail_then_ok" (first call times out, later calls answer fulfilled),
// "ok". GET payments/PM… answers a confirmed Pay by Bank payment for the order total. Calls are appended to stand_gc_calls.
add_filter( 'pre_http_request', function ( $pre, $args, $url ) {
	if ( ! preg_match( '#^https://api(-sandbox)?\.gocardless\.com/(.*?)(\?.*)?$#', $url, $m ) ) {
		return $pre;
	}
	$method  = strtoupper( $args['method'] ?? 'GET' );
	$calls   = (array) get_option( 'stand_gc_calls', array() );
	$calls[] = $method . ' ' . $m[2];
	update_option( 'stand_gc_calls', $calls, false );
	$json = function ( $code, $body ) {
		return array( 'headers' => array(), 'body' => wp_json_encode( $body ), 'response' => array( 'code' => $code, 'message' => 'OK' ),
			'cookies' => array(), 'filename' => null );
	};
	$order_id = (int) get_option( 'stand_gc_order_id' );
	$amount   = (int) get_option( 'stand_gc_amount' );
	if ( 'GET' === $method && preg_match( '#^billing_requests/(BR\w+)$#', $m[2], $p ) ) {
		$gets = count( array_filter( $calls, fn( $c ) => 0 === strpos( $c, 'GET billing_requests/' ) ) );
		if ( 'fail_then_ok' === get_option( 'stand_gc_br', 'ok' ) && 1 === $gets ) {
			return new WP_Error( 'http_request_failed', 'cURL error 28: Operation timed out after 30001 milliseconds with 0 bytes received' );
		}
		return $json( 200, array( 'billing_requests' => array( 'id' => $p[1], 'status' => 'fulfilled',
			'metadata' => array( 'order_id' => (string) $order_id ),
			'links' => array( 'payment_request' => 'PRQ' . $order_id, 'payment_request_payment' => 'PM' . $order_id, 'customer' => 'CU' . $order_id ) ) ) );
	}
	if ( 'GET' === $method && preg_match( '#^payments/(PM\w+)$#', $m[2], $p ) ) {
		return $json( 200, array( 'payments' => array( 'id' => $p[1], 'status' => 'confirmed', 'amount' => $amount, 'currency' => 'GBP',
			'charge_date' => gmdate( 'Y-m-d' ), 'scheme' => 'faster_payments', 'metadata' => array( 'order_id' => (string) $order_id ),
			'links' => array( 'creditor' => 'CR1' ) ) ) );
	}
	return $json( 200, array() );
}, 10, 3 );
add_filter( 'pre_wp_mail', '__return_true' ); // the stand has no mail server
