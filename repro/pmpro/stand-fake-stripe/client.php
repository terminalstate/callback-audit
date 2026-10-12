<?php
/**
 * Fake transport for stripe-php: answers the few requests the scenario needs, never touches the network.
 */
class Stand_Fake_Stripe_Client implements \Stripe\HttpClient\ClientInterface {

	public function request( $method, $absUrl, $headers, $params, $hasFile, $apiMode = 'v1', $maxNetworkRetries = null ) {
		$path  = (string) parse_url( $absUrl, PHP_URL_PATH );
		$mode  = get_option( 'stand_stripe_mode', 'ok' );
		$calls = get_option( 'stand_stripe_calls', array() );
		$calls[] = strtoupper( $method ) . ' ' . $path . ' (' . $mode . ')';
		update_option( 'stand_stripe_calls', $calls, false );

		$now = time();

		if ( '/v1/events/evt_test_1' === $path ) {
			if ( 'outage' === $mode ) {
				return array( '{"error":{"type":"api_error","message":"Stand: temporary Stripe failure"}}', 500, array( 'request-id' => 'req_stand_1' ) );
			}
			if ( 'missing' === $mode ) {
				return array( '{"error":{"type":"invalid_request_error","code":"resource_missing","message":"No such event: \'evt_test_1\'"}}', 404, array( 'request-id' => 'req_stand_4' ) );
			}
			$event = array(
				'id'       => 'evt_test_1',
				'object'   => 'event',
				'type'     => 'customer.subscription.deleted',
				'livemode' => false,
				'created'  => $now - 60,
				'data'     => array(
					'object' => array(
						'id'       => 'sub_test_1',
						'object'   => 'subscription',
						'status'   => 'canceled',
						'customer' => 'cus_test_1',
					),
				),
			);
			return array( wp_json_encode( $event ), 200, array( 'request-id' => 'req_stand_2' ) );
		}

		if ( '/v1/subscriptions/sub_test_1' === $path ) {
			$subscription = array(
				'id'         => 'sub_test_1',
				'object'     => 'subscription',
				'status'     => 'active',
				'customer'   => 'cus_test_1',
				'start_date' => $now - 86400,
				'items'      => array(
					'object' => 'list',
					'data'   => array(
						array(
							'id'                   => 'si_test_1',
							'object'               => 'subscription_item',
							'current_period_start' => $now - 86400,
							'current_period_end'   => $now + 29 * 86400,
							'price'                => array(
								'id'          => 'price_test_1',
								'object'      => 'price',
								'unit_amount' => 1000,
								'currency'    => 'usd',
								'recurring'   => array( 'interval' => 'month', 'interval_count' => 1 ),
							),
						),
					),
				),
			);
			return array( wp_json_encode( $subscription ), 200, array( 'request-id' => 'req_stand_3' ) );
		}

		return array( '{"error":{"type":"invalid_request_error","message":"Stand: unexpected request ' . $method . ' ' . $path . '"}}', 404, array( 'request-id' => 'req_stand_x' ) );
	}
}
