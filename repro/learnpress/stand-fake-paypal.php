<?php
/**
 * Stand only: answers LearnPress's PayPal REST calls (sandbox host) locally. Everything else goes out unchanged.
 * Option stand_paypal_mode: outage (verify-webhook-signature times out) | ok (SUCCESS) | fail (FAILURE).
 */
add_filter(
	'pre_http_request',
	function ( $pre, $args, $url ) {
		$host = wp_parse_url( $url, PHP_URL_HOST );
		if ( 'api-m.sandbox.paypal.com' !== $host && 'api.sandbox.paypal.com' !== $host ) {
			return $pre;
		}
		$path  = wp_parse_url( $url, PHP_URL_PATH );
		$calls = get_option( 'stand_paypal_calls', array() );
		$calls[] = $path;
		update_option( 'stand_paypal_calls', $calls, false );
		$json = function ( $body ) {
			return array(
				'headers'  => array( 'content-type' => 'application/json' ),
				'body'     => wp_json_encode( $body ),
				'response' => array( 'code' => 200, 'message' => 'OK' ),
				'cookies'  => array(),
				'filename' => null,
			);
		};
		if ( str_ends_with( $path, '/v1/oauth2/token' ) ) {
			return $json( array( 'access_token' => 'A21-stand', 'token_type' => 'Bearer', 'expires_in' => 32400 ) );
		}
		if ( str_ends_with( $path, '/v1/notifications/verify-webhook-signature' ) ) {
			$mode = get_option( 'stand_paypal_mode', 'outage' );
			if ( 'outage' === $mode ) {
				return new WP_Error( 'http_request_failed', 'cURL error 28: Operation timed out after 60001 milliseconds with 0 bytes received' );
			}
			return $json( array( 'verification_status' => 'ok' === $mode ? 'SUCCESS' : 'FAILURE' ) );
		}
		return new WP_Error( 'stand', 'unexpected PayPal call in stand: ' . $path );
	},
	10,
	3
);
