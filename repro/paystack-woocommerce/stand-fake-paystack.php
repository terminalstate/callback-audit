<?php
// Stand only: answers the plugin's calls to api.paystack.co (nothing else is touched — not the signature check, not WooCommerce).
// Mode for GET /transaction/verify/<ref> comes from the option stand_paystack_verify: success | 503 | 429 | wp_error.
// Every call is counted in the option stand_paystack_calls.
add_filter( 'pre_http_request', function ( $pre, $args, $url ) {
	if ( 0 !== strpos( $url, 'https://api.paystack.co/' ) ) {
		return $pre;
	}
	update_option( 'stand_paystack_calls', (int) get_option( 'stand_paystack_calls', 0 ) + 1, false );
	if ( ! preg_match( '#/transaction/verify/(.+)$#', $url, $m ) ) {
		return new WP_Error( 'stand', 'unexpected Paystack call ' . $url );
	}
	$ref  = rawurldecode( $m[1] );
	$mode = get_option( 'stand_paystack_verify', 'success' );
	if ( 'wp_error' === $mode ) {
		return new WP_Error( 'http_request_failed', 'cURL error 28: Operation timed out after 60001 milliseconds with 0 bytes received' );
	}
	if ( '503' === $mode || '429' === $mode ) {
		$msg = '503' === $mode ? 'Service unavailable' : 'Too many requests';
		return array( 'headers' => array(), 'body' => wp_json_encode( array( 'status' => false, 'message' => $msg ) ),
			'response' => array( 'code' => (int) $mode, 'message' => $msg ), 'cookies' => array(), 'filename' => null );
	}
	$body = array( 'status' => true, 'message' => 'Verification successful', 'data' => array(
		'status' => 'success', 'reference' => $ref, 'amount' => (int) get_option( 'stand_paystack_amount' ), 'currency' => 'NGN',
		'channel' => 'bank_transfer', 'authorization' => array( 'reusable' => false, 'channel' => 'bank_transfer' ),
		'customer' => array( 'email' => 'buyer@example.test' ) ) );
	return array( 'headers' => array(), 'body' => wp_json_encode( $body ), 'response' => array( 'code' => 200, 'message' => 'OK' ),
		'cookies' => array(), 'filename' => null );
}, 10, 3 );
add_filter( 'pre_wp_mail', '__return_true' ); // the stand has no mail server
