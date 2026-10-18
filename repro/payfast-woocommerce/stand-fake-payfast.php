<?php
/**
 * Plugin Name: Stand — fake Payfast ITN validation for the Payfast for WooCommerce reproduction
 * Description: Answers only the plugin's server-to-server ITN validation POST (…/eng/query/validate) through WordPress
 *              HTTP (pre_http_request); nothing in the plugin or WooCommerce is changed and Payfast is never contacted.
 *              Option `stand_payfast_mode`: "outage" — the validation request fails (cURL timeout, as WordPress reports it);
 *              "ok" — Payfast answers "VALID". Every call is logged to the option `stand_payfast_calls`.
 */
add_filter(
	'pre_http_request',
	function ( $pre, $args, $url ) {
		if ( false === strpos( $url, 'payfast.co.za/eng/query/validate' ) ) {
			return $pre;
		}
		$mode    = get_option( 'stand_payfast_mode', 'ok' );
		$calls   = (array) get_option( 'stand_payfast_calls', array() );
		$calls[] = 'POST ' . wp_parse_url( $url, PHP_URL_HOST ) . '/eng/query/validate (' . $mode . ')';
		update_option( 'stand_payfast_calls', $calls, false );
		if ( 'outage' === $mode ) {
			return new WP_Error( 'http_request_failed', 'cURL error 28: Operation timed out after 30001 milliseconds with 0 bytes received' );
		}
		return array( 'headers' => array(), 'body' => 'VALID', 'response' => array( 'code' => 200, 'message' => 'OK' ), 'cookies' => array(), 'filename' => null );
	},
	10,
	3
);
add_filter( 'pre_wp_mail', '__return_true' ); // the stand has no mail server
