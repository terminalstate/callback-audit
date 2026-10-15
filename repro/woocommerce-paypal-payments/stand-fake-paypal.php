<?php
/**
 * Plugin Name: Stand — fake PayPal REST API for the PayPal Payments webhook reproduction
 * Description: Answers WordPress HTTP requests to the PayPal sandbox/live REST hosts (pre_http_request); nothing in
 *              WooCommerce or PayPal Payments is patched and PayPal is never contacted. The webhook signature is
 *              still verified by the plugin's own code path (POST /v1/notifications/verify-webhook-signature,
 *              answered SUCCESS here, as PayPal does for a genuine delivery).
 *              Option `stand_paypal_mode`:
 *                "outage" — GET /v2/checkout/orders/{id} answers 503 SERVICE_UNAVAILABLE (a transient PayPal failure);
 *                "ok"     — it answers the COMPLETED order with its capture.
 *              Every call is logged to the option `stand_paypal_calls`.
 */

add_filter(
	'pre_http_request',
	function ( $pre, $args, $url ) {
		$host = (string) wp_parse_url( $url, PHP_URL_HOST );
		if ( ! in_array( $host, array( 'api-m.sandbox.paypal.com', 'api-m.paypal.com', 'api.sandbox.paypal.com', 'api.paypal.com' ), true ) ) {
			return $pre;
		}
		$method = strtoupper( $args['method'] ?? 'GET' );
		$path   = (string) wp_parse_url( $url, PHP_URL_PATH );
		$mode   = get_option( 'stand_paypal_mode', 'ok' );
		$reply  = function ( int $code, array $body ) {
			return array(
				'headers'  => new \WpOrg\Requests\Utility\CaseInsensitiveDictionary( array( 'content-type' => 'application/json', 'paypal-debug-id' => 'stand' ) ),
				'body'     => wp_json_encode( $body ),
				'response' => array( 'code' => $code, 'message' => get_status_header_desc( $code ) ),
				'cookies'  => array(),
				'filename' => null,
			);
		};

		if ( '/v1/oauth2/token' === $path ) {
			$out = $reply( 200, array( 'access_token' => 'A21-stand', 'token_type' => 'Bearer', 'expires_in' => 32400, 'app_id' => 'APP-STAND', 'nonce' => 'stand' ) );
		} elseif ( '/v1/notifications/verify-webhook-signature' === $path ) {
			$out = $reply( 200, array( 'verification_status' => 'SUCCESS' ) );
		} elseif ( 'GET' === $method && preg_match( '#^/v2/checkout/orders/([A-Z0-9]+)$#', $path, $m ) ) {
			if ( 'outage' === $mode ) {
				$out = $reply( 503, array( 'name' => 'SERVICE_UNAVAILABLE', 'message' => 'Service Unavailable.', 'debug_id' => 'stand' ) );
			} else {
				$out = $reply( 200, stand_paypal_completed_order( $m[1] ) );
			}
		} else {
			$out = $reply( 404, array( 'name' => 'RESOURCE_NOT_FOUND', 'message' => 'not faked by the stand' ) );
		}

		$calls   = (array) get_option( 'stand_paypal_calls', array() );
		$calls[] = $method . ' ' . $path . ( 0 === strpos( $path, '/v2/' ) ? " ($mode)" : '' ) . ' -> ' . $out['response']['code'];
		update_option( 'stand_paypal_calls', $calls, false );
		return $out;
	},
	10,
	3
);

function stand_paypal_completed_order( string $id ): array {
	$order_id = (string) get_option( 'stand_wc_order_id' );
	return array(
		'id'             => $id,
		'intent'         => 'CAPTURE',
		'status'         => 'COMPLETED',
		'payment_source' => array( 'ideal' => array( 'name' => 'Test Buyer', 'country_code' => 'NL' ) ),
		'purchase_units' => array(
			array(
				'reference_id' => 'default',
				'custom_id'    => $order_id,
				'amount'       => array( 'currency_code' => 'EUR', 'value' => '25.00' ),
				'payments'     => array(
					'captures' => array(
						array(
							'id'                          => 'CAPSTAND1',
							'status'                      => 'COMPLETED',
							'amount'                      => array( 'currency_code' => 'EUR', 'value' => '25.00' ),
							'final_capture'               => true,
							'custom_id'                   => $order_id,
							'seller_protection'           => array( 'status' => 'NOT_ELIGIBLE' ),
							'seller_receivable_breakdown' => array(
								'gross_amount' => array( 'currency_code' => 'EUR', 'value' => '25.00' ),
								'paypal_fee'   => array( 'currency_code' => 'EUR', 'value' => '0.95' ),
								'net_amount'   => array( 'currency_code' => 'EUR', 'value' => '24.05' ),
							),
							'create_time'                 => '2026-10-12T10:00:00Z',
							'update_time'                 => '2026-10-12T10:00:01Z',
						),
					),
				),
			),
		),
		'create_time'    => '2026-10-12T09:59:00Z',
		'update_time'    => '2026-10-12T10:00:01Z',
	);
}

// The stand has no mail server; pretend mail was sent so order notes stay readable.
add_filter( 'pre_wp_mail', '__return_true' );
