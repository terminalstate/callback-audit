<?php
/**
 * Plugin Name: Stand — fake Stripe HTTP for the PMPro webhook reproduction
 * Description: Replaces only the HTTP transport of PMPro's bundled stripe-php (ApiRequestor::setHttpClient).
 *              Nothing in PMPro is patched. Mode comes from the option `stand_stripe_mode`:
 *              "outage" — GET /v1/events/{id} answers 500 api_error (a transient Stripe failure);
 *              "missing" — it answers 404 resource_missing (the event does not exist in this account);
 *              "ok"     — it answers the real event. Every call is logged to the option `stand_stripe_calls`.
 */

add_action(
	'plugins_loaded',
	function () {
		if ( ! defined( 'PMPRO_DIR' ) ) {
			return;
		}
		if ( ! class_exists( '\Stripe\Stripe' ) ) {
			require_once PMPRO_DIR . '/includes/lib/Stripe/init.php';
		}
		require_once __DIR__ . '/stand-fake-stripe/client.php';
		\Stripe\ApiRequestor::setHttpClient( new Stand_Fake_Stripe_Client() );
	},
	0
);
