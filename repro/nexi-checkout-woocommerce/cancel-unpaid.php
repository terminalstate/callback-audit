<?php
// wp eval-file cancel-unpaid.php <wc-order-id> — moves the order's last-modified time back past the hold-stock window
// (as if 61 minutes had passed) and runs WooCommerce's own scheduled cleanup, wc_cancel_unpaid_orders().
global $wpdb;
$id   = (int) $args[0];
$past = gmdate( 'Y-m-d H:i:s', time() - 61 * MINUTE_IN_SECONDS );
if ( class_exists( '\Automattic\WooCommerce\Utilities\OrderUtil' ) && \Automattic\WooCommerce\Utilities\OrderUtil::custom_orders_table_usage_is_enabled() ) {
	$wpdb->update( $wpdb->prefix . 'wc_orders', array( 'date_updated_gmt' => $past ), array( 'id' => $id ) );
}
$wpdb->update( $wpdb->posts, array( 'post_modified_gmt' => $past, 'post_modified' => $past ), array( 'ID' => $id ) );
wp_cache_flush();
wc_cancel_unpaid_orders();
