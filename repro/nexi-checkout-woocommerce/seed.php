<?php
// wp eval-file seed.php — a Swedish shop (SEK) with Nexi Checkout in test mode (invented key), the Swish payment method enabled,
// order management on, stock management on, hold stock 60 minutes (WooCommerce default).
update_option( 'woocommerce_default_country', 'SE' );
update_option( 'woocommerce_currency', 'SEK' );
update_option( 'woocommerce_manage_stock', 'yes' );
update_option( 'woocommerce_hold_stock_minutes', '60' );
$s = get_option( 'woocommerce_dibs_easy_settings', array() );
update_option( 'woocommerce_dibs_easy_settings', array_merge( is_array( $s ) ? $s : array(), array( 'enabled' => 'yes', 'test_mode' => 'yes',
	'dibs_test_key' => 'test-secret-key-stand-invented', 'dibs_test_checkout_key' => 'test-checkout-key-stand-invented',
	'checkout_flow' => 'redirect', 'dibs_manage_orders' => 'yes', 'enable_payment_method_swish' => 'yes', 'debug_mode' => 'no', 'email_text' => '' ) ) );
$product = new WC_Product_Simple();
$product->set_name( 'Stand product' );
$product->set_regular_price( '100.00' );
$product->set_manage_stock( true );
$product->set_stock_quantity( 10 );
$product->save();
update_option( 'stand_product_id', $product->get_id() );
echo "seeded product {$product->get_id()}\n";
