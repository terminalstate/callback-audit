<?php
// wp eval-file seed.php — a EUR shop with the Checkout.com cards gateway in classic mode (the mode the gateway falls back to
// when the setting was never saved), NAS account, sandbox, 3-D Secure on. Keys are invented; Checkout.com is never called.
update_option( 'woocommerce_currency', 'EUR' );
update_option( 'woocommerce_manage_stock', 'yes' );
update_option( 'woocommerce_hold_stock_minutes', '60' );
update_option( 'woocommerce_wc_checkout_com_cards_settings', array(
	'enabled'              => 'yes',
	'ckocom_checkout_mode' => 'classic',
	'ckocom_account_type'  => 'NAS',
	'ckocom_environment'   => 'sandbox',
	'ckocom_pk'            => 'pk_sbox_standpublickey000000000',
	'ckocom_sk'            => 'sk_sbox_standsecretkey000000000',
	'ckocom_card_threed'   => '1',
	'ckocom_card_autocap'  => '1',
) );
$product = new WC_Product_Simple();
$product->set_name( 'Stand product' );
$product->set_regular_price( '25.00' );
$product->set_manage_stock( true );
$product->set_stock_quantity( 10 );
$product->save();
update_option( 'stand_product_id', $product->get_id() );
echo "seeded product {$product->get_id()}\n";
