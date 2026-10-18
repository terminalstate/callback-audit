<?php
// wp eval-file seed.php — a South African shop (ZAR) with Payfast in sandbox mode (invented merchant id, key and passphrase;
// sandbox mode makes the plugin skip the source-IP check and use the sandbox validate URL), stock management on.
update_option( 'woocommerce_default_country', 'ZA' );
update_option( 'woocommerce_currency', 'ZAR' );
update_option( 'woocommerce_manage_stock', 'yes' );
update_option( 'woocommerce_hold_stock_minutes', '60' );
update_option( 'woocommerce_payfast_settings', array(
	'enabled' => 'yes', 'testmode' => 'yes', 'merchant_id' => '10000100', 'merchant_key' => 'standmerchantkey',
	'pass_phrase' => 'stand-passphrase', 'send_debug_email' => 'no', 'enable_logging' => 'yes',
) );
$product = new WC_Product_Simple();
$product->set_name( 'Stand product' );
$product->set_regular_price( '250.00' );
$product->set_manage_stock( true );
$product->set_stock_quantity( 10 );
$product->save();
update_option( 'stand_product_id', $product->get_id() );
echo "seeded product {$product->get_id()}\n";
