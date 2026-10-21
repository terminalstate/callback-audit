<?php
// wp eval-file seed.php — a Nigerian shop (NGN) with Flutterwave enabled (invented keys) and a webhook secret hash; stock management on.
update_option( 'woocommerce_currency', 'NGN' );
update_option( 'woocommerce_default_country', 'NG' );
update_option( 'woocommerce_manage_stock', 'yes' );
update_option( 'woocommerce_hold_stock_minutes', '60' );
update_option( 'woocommerce_rave_settings', array(
	'enabled' => 'yes', 'go_live' => 'no', 'test_public_key' => 'FLWPUBK_TEST-stand-X', 'test_secret_key' => 'FLWSECK_TEST-stand-X',
	'live_public_key' => 'FLWPUBK-stand-X', 'live_secret_key' => 'FLWSECK-stand-X', 'secret_hash' => str_repeat( 'ab12', 16 ), 'logging_option' => 'no',
) );
$product = new WC_Product_Simple();
$product->set_name( 'Stand product' );
$product->set_regular_price( '2500.00' );
$product->set_manage_stock( true );
$product->set_stock_quantity( 10 );
$product->save();
update_option( 'stand_product_id', $product->get_id() );
echo "seeded product {$product->get_id()}\n";
