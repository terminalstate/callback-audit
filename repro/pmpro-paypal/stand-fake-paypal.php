<?php
/**
 * Plugin Name: Stand — fake PayPal REST API for the PMPro PayPal reproduction
 * Description: Answers the add-on's calls to https://api-m.sandbox.paypal.com through WordPress HTTP (pre_http_request). Nothing in
 *              PMPro or the add-on is changed; PayPal is never contacted. Orders live in the option `stand_paypal_orders`.
 *              POST /v1/oauth2/token                        → 200 access token
 *              POST /v2/checkout/orders                     → 201 order CREATED with an approve link (ORDER-STAND-<n>)
 *              GET  /v2/checkout/orders/{id}                → 200 order: APPROVED (the buyer approved it) until captured, then
 *                                                             COMPLETED with its capture, as PayPal reports it
 *              POST /v2/checkout/orders/{id}/capture        → 201 order COMPLETED; captures[0].status from the option
 *                                                             `stand_paypal_capture`: COMPLETED | PENDING | DECLINED (PayPal: "A
 *                                                             completed order can indicate … a payment was declined")
 *              POST /v1/notifications/webhooks              → 201 (webhook registration on settings save; body kept)
 *              POST /v1/notifications/verify-webhook-signature → 200 {"verification_status":"SUCCESS"} — PayPal verifies the
 *                                                             webhook by this postback; the request body is kept for the check
 *              Every call is appended to the option `stand_paypal_calls`. Outgoing mail is recorded, not sent.
 */
add_filter(
	'pre_http_request',
	function ( $pre, $args, $url ) {
		if ( 0 !== strpos( $url, 'https://api-m.sandbox.paypal.com/' ) ) {
			return $pre;
		}
		$method = strtoupper( $args['method'] ?? 'GET' );
		$path   = (string) wp_parse_url( $url, PHP_URL_PATH );
		$calls   = (array) get_option( 'stand_paypal_calls', array() );
		$calls[] = $method . ' ' . $path;
		update_option( 'stand_paypal_calls', $calls, false );
		$orders = (array) get_option( 'stand_paypal_orders', array() );
		$json   = function ( $code, $body ) {
			return array( 'headers' => array( 'content-type' => 'application/json' ), 'body' => wp_json_encode( $body ),
				'response' => array( 'code' => $code, 'message' => 'OK' ), 'cookies' => array(), 'filename' => null );
		};
		$view = function ( $id, $o ) {
			$order = array( 'id' => $id, 'intent' => 'CAPTURE', 'status' => $o['status'],
				'purchase_units' => array( array( 'reference_id' => 'default', 'amount' => $o['amount'] ) ) );
			if ( ! empty( $o['capture'] ) ) {
				$order['purchase_units'][0]['payments'] = array( 'captures' => array( $o['capture'] ) );
			}
			return $order;
		};

		if ( 'POST' === $method && '/v1/oauth2/token' === $path ) {
			return $json( 200, array( 'access_token' => 'A21-stand-token', 'token_type' => 'Bearer', 'expires_in' => 32400 ) );
		}
		if ( 'POST' === $method && '/v1/notifications/webhooks' === $path ) {
			update_option( 'stand_paypal_registered', (string) $args['body'], false );
			return $json( 201, array( 'id' => 'WH-REGISTERED-STAND' ) );
		}
		if ( 'POST' === $method && '/v1/notifications/verify-webhook-signature' === $path ) {
			update_option( 'stand_paypal_last_verify', (string) $args['body'], false );
			return $json( 200, array( 'verification_status' => 'SUCCESS' ) );
		}
		if ( 'POST' === $method && '/v2/checkout/orders' === $path ) {
			$req = json_decode( $args['body'], true );
			$id  = 'ORDER-STAND-' . ( count( $orders ) + 1 );
			$orders[ $id ] = array( 'status' => 'APPROVED', 'amount' => $req['purchase_units'][0]['amount'], 'capture' => null );
			update_option( 'stand_paypal_orders', $orders, false );
			return $json( 201, array( 'id' => $id, 'status' => 'CREATED', 'links' => array(
				array( 'href' => $url . '/' . $id, 'rel' => 'self', 'method' => 'GET' ),
				array( 'href' => 'https://www.sandbox.paypal.com/checkoutnow?token=' . $id, 'rel' => 'approve', 'method' => 'GET' ),
				array( 'href' => $url . '/' . $id . '/capture', 'rel' => 'capture', 'method' => 'POST' ) ) ) );
		}
		if ( preg_match( '#^/v2/checkout/orders/([^/]+)(/capture)?$#', $path, $m ) && isset( $orders[ rawurldecode( $m[1] ) ] ) ) {
			$id = rawurldecode( $m[1] );
			if ( 'GET' === $method && empty( $m[2] ) ) {
				return $json( 200, $view( $id, $orders[ $id ] ) );
			}
			if ( 'POST' === $method && ! empty( $m[2] ) ) {
				if ( 'COMPLETED' === $orders[ $id ]['status'] ) {
					return $json( 422, array( 'name' => 'UNPROCESSABLE_ENTITY', 'details' => array( array( 'issue' => 'ORDER_ALREADY_CAPTURED' ) ) ) );
				}
				$status  = get_option( 'stand_paypal_capture', 'COMPLETED' );
				$capture = array( 'id' => 'CAP-' . substr( md5( $id ), 0, 12 ), 'status' => $status, 'amount' => $orders[ $id ]['amount'],
					'final_capture' => true, 'create_time' => gmdate( 'Y-m-d\TH:i:s\Z' ) );
				if ( 'PENDING' === $status ) {
					$capture['status_details'] = array( 'reason' => get_option( 'stand_paypal_pending_reason', 'PENDING_REVIEW' ) );
				}
				$orders[ $id ]['status']  = 'COMPLETED';
				$orders[ $id ]['capture'] = $capture;
				update_option( 'stand_paypal_orders', $orders, false );
				return $json( 201, $view( $id, $orders[ $id ] ) );
			}
		}
		return new WP_Error( 'stand', 'unexpected PayPal call ' . $method . ' ' . $url );
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
