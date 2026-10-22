<?php
// wp eval-file seed.php — a Nigerian shop (NGN) with Paystack enabled in test mode (invented keys), stock management on,
// hold stock 60 minutes (WooCommerce default).
update_option( 'woocommerce_default_country', 'NG:LA' );
update_option( 'woocommerce_currency', 'NGN' );
update_option( 'woocommerce_manage_stock', 'yes' );
update_option( 'woocommerce_hold_stock_minutes', '60' );
update_option( 'woocommerce_paystack_settings', array( 'enabled' => 'yes', 'testmode' => 'yes',
	'test_secret_key' => 'sk_test_0000standinvented', 'test_public_key' => 'pk_test_0000standinvented',
	'payment_page' => 'redirect', 'autocomplete_order' => 'no' ) );
$product = new WC_Product_Simple();
$product->set_name( 'Stand product' );
$product->set_regular_price( '5000.00' );
$product->set_manage_stock( true );
$product->set_stock_quantity( 10 );
$product->save();
update_option( 'stand_product_id', $product->get_id() );
echo "seeded product {$product->get_id()}\n";
