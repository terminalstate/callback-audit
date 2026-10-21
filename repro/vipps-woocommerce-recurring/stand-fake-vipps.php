<?php
// mu-plugin: a stand-in for the Vipps MobilePay Recurring API (api.vipps.no). The plugin's own client (wp_remote_request) calls it.
// Charges live in the option stand_vipps_charges; every call is appended to stand_vipps_calls. Mode (option stand_vipps_mode):
//   ok          — create and fetch charges normally
//   create_lost — the charge is created at Vipps (status DUE), but the response never arrives (cURL timeout, as with WordPress' 5 s default)
//   get_fails   — create answers normally, the GET of the new charge times out
add_filter( 'pre_http_request', function ( $pre, $args, $url ) {
	$host = wp_parse_url( $url, PHP_URL_HOST );
	if ( ! in_array( $host, array( 'api.vipps.no', 'apitest.vipps.no' ), true ) ) {
		return $pre;
	}
	$path    = wp_parse_url( $url, PHP_URL_PATH );
	$method  = $args['method'] ?? 'GET';
	$mode    = get_option( 'stand_vipps_mode', 'ok' );
	$charges = get_option( 'stand_vipps_charges', array() );
	$log     = function ( $what ) use ( $method, $path ) {
		$calls   = get_option( 'stand_vipps_calls', array() );
		$calls[] = "$method $path -> $what";
		update_option( 'stand_vipps_calls', $calls, false );
	};
	$json    = function ( $code, $body ) {
		return array( 'headers' => array(), 'body' => wp_json_encode( $body ), 'response' => array( 'code' => $code, 'message' => '' ), 'cookies' => array(), 'filename' => null );
	};
	$timeout = new WP_Error( 'http_request_failed', 'cURL error 28: Operation timed out after 5001 milliseconds with 0 bytes received' );

	if ( 'POST' === $method && '/accessToken/get' === $path ) {
		$log( 200 );
		return $json( 200, array( 'access_token' => 'stand-token', 'expires_in' => '3600', 'expires_on' => (string) ( time() + 3600 ), 'not_before' => (string) time(), 'token_type' => 'Bearer' ) );
	}
	if ( preg_match( '#^/recurring/v3/agreements/([^/]+)$#', $path, $m ) && 'GET' === $method ) {
		$log( 200 );
		return $json( 200, array( 'id' => $m[1], 'status' => 'ACTIVE', 'productName' => 'Stand plan',
			'pricing' => array( 'type' => 'LEGACY', 'amount' => 19900, 'currency' => 'NOK' ),
			'interval' => array( 'unit' => 'MONTH', 'count' => 1 ) ) );
	}
	if ( preg_match( '#^/recurring/v3/agreements/([^/]+)/charges$#', $path, $m ) && 'POST' === $method ) {
		$body = json_decode( $args['body'], true );
		$id   = 'chr-stand-' . ( count( $charges ) + 1 );
		$charges[ $id ] = array( 'id' => $id, 'agreementId' => $m[1], 'status' => 'DUE', 'due' => $body['due'], 'amount' => $body['amount'],
			'amountRefunded' => 0, 'description' => $body['description'], 'type' => 'RECURRING', 'transactionType' => 'DIRECT_CAPTURE',
			'idempotencyKey' => $args['headers']['Idempotency-Key'] ?? '' );
		update_option( 'stand_vipps_charges', $charges, false );
		if ( 'create_lost' === $mode ) {
			$log( "created $id (DUE), response lost: timeout" );
			return $timeout;
		}
		$log( "201 $id" );
		return $json( 201, array( 'chargeId' => $id ) );
	}
	if ( preg_match( '#^/recurring/v3/agreements/([^/]+)/charges/([^/]+)$#', $path, $m ) ) {
		if ( 'DELETE' === $method ) {
			$charges[ $m[2] ]['status'] = 'CANCELLED';
			update_option( 'stand_vipps_charges', $charges, false );
			$log( '204 cancelled' );
			return $json( 204, array() );
		}
		if ( 'get_fails' === $mode ) {
			$log( 'timeout' );
			return $timeout;
		}
		$log( 200 );
		return $json( 200, $charges[ $m[2] ] );
	}
	$log( '404 not faked' );
	return $json( 404, array( 'title' => 'not faked by the stand' ) );
}, 10, 3 );
