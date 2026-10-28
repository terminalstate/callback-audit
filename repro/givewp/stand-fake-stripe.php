<?php
/**
 * Plugin Name: Stand: fake Stripe HTTP for the GiveWP webhook reproduction
 * Description: Replaces only the HTTP transport of GiveWP's stripe-php (ApiRequestor::setHttpClient). Nothing in
 *              GiveWP is patched. Option `stand_stripe_mode`: "outage": GET /v1/events/{id} answers 500 api_error;
 *              "ok": it answers the real event. Calls are logged to the option `stand_stripe_calls`.
 */

add_action(
	'plugins_loaded',
	function () {
		if ( ! class_exists( '\Stripe\ApiRequestor' ) ) {
			return;
		}
		require_once __DIR__ . '/stand-fake-stripe/client.php';
		\Stripe\ApiRequestor::setHttpClient( new Stand_Fake_Stripe_Client() );
	},
	0
);
