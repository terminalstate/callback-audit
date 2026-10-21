<?php
// mu-plugin: WooCommerce Subscriptions core (GPL, github.com/Automattic/woocommerce-subscriptions-core) instead of the paid
// WooCommerce Subscriptions. The Vipps loader (recurring/maybe_load.php) only checks that a class named WC_Subscriptions_Plugin exists.
class WC_Subscriptions_Plugin {}
require_once getenv( 'STAND_WCS_CORE' ) . '/includes/class-wc-subscriptions-core-plugin.php';
new WC_Subscriptions_Core_Plugin();
// The retry store belongs to the paid plugin; the Vipps gateway only counts earlier retries when it builds the charge's order id.
// No retries here.
if ( ! class_exists( 'WCS_Retry_Manager' ) ) {
	class WCS_Retry_Manager {
		public static function store() {
			return new class() {
				public function get_retries( $args = array(), $return = 'objects' ) {
					return array();
				}
			};
		}
	}
}
