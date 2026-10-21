<?php
// mu-plugin: a stand-in for the Flutterwave v3 API that the plugin's own client (wp_remote_request) calls, and a block on the plugin's
// telemetry host so nothing leaves the stand. Mode (option stand_flw_mode): "outage" — verify_by_reference times out; "ok" — it answers
// the transaction as successful with the order's amount and currency. Calls are appended to the option stand_flw_calls.
add_filter( 'pre_http_request', function ( $pre, $args, $url ) {
	$host = wp_parse_url( $url, PHP_URL_HOST );
	if ( false !== strpos( (string) $host, 'f4b-flutterwave.com' ) ) {
		return new WP_Error( 'http_request_failed', 'telemetry blocked by the stand' );
	}
	if ( 'api.flutterwave.com' !== $host ) {
		return $pre;
	}
	parse_str( (string) wp_parse_url( $url, PHP_URL_QUERY ), $q );
	$mode    = get_option( 'stand_flw_mode', 'ok' );
	$calls   = get_option( 'stand_flw_calls', array() );
	$calls[] = wp_parse_url( $url, PHP_URL_PATH ) . " ($mode)";
	update_option( 'stand_flw_calls', $calls, false );
	if ( 'outage' === $mode ) {
		return new WP_Error( 'http_request_failed', 'cURL error 28: Operation timed out after 30001 milliseconds with 0 bytes received' );
	}
	$tx_ref = $q['tx_ref'] ?? '';
	$order  = wc_get_order( (int) explode( '_', $tx_ref )[1] );
	$body   = array( 'status' => 'success', 'message' => 'Transaction fetched successfully', 'data' => array(
		'id' => 5550001, 'tx_ref' => $tx_ref, 'flw_ref' => 'FLW-STAND-1', 'amount' => (float) $order->get_total(),
		'currency' => $order->get_currency(), 'charged_amount' => (float) $order->get_total(), 'status' => 'successful', 'payment_type' => 'card',
	) );
	return array( 'headers' => array(), 'body' => wp_json_encode( $body ), 'response' => array( 'code' => 200, 'message' => 'OK' ), 'cookies' => array(), 'filename' => null );
}, 10, 3 );
