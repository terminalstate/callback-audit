<?php
// wp eval-file seed.php — a UK shop (GBP) with GoCardless in sandbox mode (invented token and webhook secret), Pay by Bank
// (instant_bank_pay) on, stock management on, hold stock 60 minutes (WooCommerce default).
update_option( 'woocommerce_default_country', 'GB' );
update_option( 'woocommerce_currency', 'GBP' );
update_option( 'woocommerce_manage_stock', 'yes' );
update_option( 'woocommerce_hold_stock_minutes', '60' );
$s = get_option( 'woocommerce_gocardless_settings', array() );
update_option( 'woocommerce_gocardless_settings', array_merge( is_array( $s ) ? $s : array(), array( 'enabled' => 'yes', 'testmode' => 'yes',
	'access_token' => 'sandbox_stand_invented_token', 'webhook_secret' => 'stand-webhook-secret-invented', 'instant_bank_pay' => 'yes' ) ) );
$product = new WC_Product_Simple();
$product->set_name( 'Stand product' );
$product->set_regular_price( '25.00' );
$product->set_manage_stock( true );
$product->set_stock_quantity( 10 );
$product->save();
update_option( 'stand_product_id', $product->get_id() );
echo "seeded product {$product->get_id()}\n";
