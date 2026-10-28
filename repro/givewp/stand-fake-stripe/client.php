<?php
/**
 * Fake transport for stripe-php 7.x: answers the requests the scenario needs, never touches the network.
 */
class Stand_Fake_Stripe_Client implements \Stripe\HttpClient\ClientInterface {

	public function request( $method, $absUrl, $headers, $params, $hasFile ) {
		$path  = (string) parse_url( $absUrl, PHP_URL_PATH );
		$mode  = get_option( 'stand_stripe_mode', 'ok' );
		$calls = get_option( 'stand_stripe_calls', array() );
		$calls[] = strtoupper( $method ) . ' ' . $path . ' (' . $mode . ')';
		update_option( 'stand_stripe_calls', $calls, false );

		if ( '/v1/events/evt_test_1' === $path ) {
			if ( 'outage' === $mode ) {
				return array( '{"error":{"type":"api_error","message":"Stand: temporary Stripe failure"}}', 500, array( 'request-id' => 'req_stand_1' ) );
			}
			$event = array(
				'id'       => 'evt_test_1',
				'object'   => 'event',
				'type'     => 'payment_intent.succeeded',
				'livemode' => false,
				'created'  => time() - 60,
				'data'     => array(
					'object' => array(
						'id'       => 'pi_test_1',
						'object'   => 'payment_intent',
						'status'   => 'succeeded',
						'amount'   => 2000,
						'currency' => 'usd',
					),
				),
			);
			return array( wp_json_encode( $event ), 200, array( 'request-id' => 'req_stand_2' ) );
		}

		return array( '{"error":{"type":"invalid_request_error","message":"Stand: unexpected request ' . $method . ' ' . $path . '"}}', 404, array( 'request-id' => 'req_stand_x' ) );
	}
}
