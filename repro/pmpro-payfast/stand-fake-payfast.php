<?php
/**
 * Plugin Name: Stand — fake Payfast ITN validation for the PMPro Payfast reproduction
 * Description: Answers only the add-on's server-to-server ITN validation POST (https://sandbox.payfast.co.za/eng/query/validate)
 *              through WordPress HTTP (pre_http_request). Nothing in PMPro or the add-on is changed; Payfast is never contacted.
 *              Option `stand_payfast_mode`:
 *                valid   — 200 "VALID" (Payfast confirms the ITN)
 *                invalid — 200 "INVALID" (Payfast says the data is not genuine)
 *                timeout — the request fails as WordPress reports a cURL timeout (WP_Error)
 *                503     — 503 with an HTML error page (Payfast or its edge unavailable)
 *                403     — 403 with an HTML page (as in woocommerce-gateway-payfast #320, Aug–Sep 2025)
 *              Every validation call is appended to the option `stand_payfast_calls`. Outgoing mail is recorded, not sent.
 */
add_filter(
	'pre_http_request',
	function ( $pre, $args, $url ) {
		if ( false === strpos( $url, 'payfast.co.za/eng/query/validate' ) ) {
			return $pre;
		}
		$mode    = get_option( 'stand_payfast_mode', 'valid' );
		$calls   = (array) get_option( 'stand_payfast_calls', array() );
		$calls[] = wp_parse_url( $url, PHP_URL_HOST ) . ' ' . $mode;
		update_option( 'stand_payfast_calls', $calls, false );
		$page = function ( $code, $msg ) {
			return array( 'headers' => array( 'content-type' => 'text/html' ), 'body' => "<html><body><h1>$code $msg</h1></body></html>",
				'response' => array( 'code' => $code, 'message' => $msg ), 'cookies' => array(), 'filename' => null );
		};
		switch ( $mode ) {
			case 'timeout':
				return new WP_Error( 'http_request_failed', 'cURL error 28: Operation timed out after 15001 milliseconds with 0 bytes received' );
			case '503':
				return $page( 503, 'Service Unavailable' );
			case '403':
				return $page( 403, 'Forbidden' );
			case 'invalid':
				return array( 'headers' => array(), 'body' => 'INVALID', 'response' => array( 'code' => 200, 'message' => 'OK' ), 'cookies' => array(), 'filename' => null );
		}
		return array( 'headers' => array(), 'body' => 'VALID', 'response' => array( 'code' => 200, 'message' => 'OK' ), 'cookies' => array(), 'filename' => null );
	},
	10,
	3
);
// The stand has no mail server: record each message's subject instead of sending it.
add_filter( 'pre_wp_mail', function ( $return, $atts ) {
	$mails   = (array) get_option( 'stand_mails', array() );
	$mails[] = $atts['subject'];
	update_option( 'stand_mails', $mails, false );
	return true;
}, 10, 2 );
