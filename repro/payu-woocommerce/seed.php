<?php
// wp eval-file seed.php <order-status-after-checkout> — a Polish shop (PLN) with PayU "standard" enabled on the global POS
// settings (invented POS id, keys); the status process_payment() gives a new order is the plugin's own setting
// global_default_on_hold_status ("on-hold" by default, "pending" is the other choice). Stock management on.
update_option( 'woocommerce_default_country', 'PL' );
update_option( 'woocommerce_currency', 'PLN' );
update_option( 'woocommerce_manage_stock', 'yes' );
update_option( 'woocommerce_hold_stock_minutes', '60' );
$settings = array_merge( payu_get_default_settings(), array(
	'global_pos_id' => '300746', 'global_md5' => 'stand-second-key-md5', 'global_client_id' => '300746',
	'global_client_secret' => 'stand-client-secret', 'global_default_on_hold_status' => $args[0],
) );
update_option( 'payu_settings_option_name', $settings );
update_option( 'woocommerce_payustandard_settings', array( 'enabled' => 'yes', 'use_global' => 'yes', 'sandbox' => 'no' ) );
$product = new WC_Product_Simple();
$product->set_name( 'Stand product' );
$product->set_regular_price( '250.00' );
$product->set_manage_stock( true );
$product->set_stock_quantity( 10 );
$product->save();
update_option( 'stand_product_id', $product->get_id() );
echo "seeded product {$product->get_id()}\n";
