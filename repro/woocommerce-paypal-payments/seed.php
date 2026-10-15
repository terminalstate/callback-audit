<?php
// wp eval-file seed.php — a shop in the Netherlands (EUR) with PayPal Payments connected to a sandbox merchant,
// iDEAL enabled, the plugin's webhook registered, stock management on (so WooCommerce cancels unpaid orders).
// Credentials and ids are invented; the stand's must-use plugin answers every PayPal API call.
update_option( 'woocommerce_default_country', 'NL' );
update_option( 'woocommerce_currency', 'EUR' );
update_option( 'woocommerce_manage_stock', 'yes' );
update_option( 'woocommerce_hold_stock_minutes', '60' );

update_option(
	'woocommerce-ppcp-data-common',
	array(
		'use_sandbox'       => true,
		'merchant_connected' => true,
		'sandbox_merchant'  => true,
		'merchant_id'       => 'STANDMERCHANT1',
		'merchant_email'    => 'merchant@example.test',
		'merchant_country'  => 'NL',
		'client_id'         => 'stand-client-id',
		'client_secret'     => 'stand-client-secret',
		'seller_type'       => 'business',
	)
);
update_option( 'woocommerce_ppcp-gateway_settings', array( 'enabled' => 'yes' ) );
update_option( 'woocommerce_ppcp-ideal_settings', array( 'enabled' => 'yes' ) );
update_option(
	'ppcp-webhook',
	array(
		'id'          => 'WH-STAND-1',
		'url'         => rest_url( 'paypal/v1/incoming' ),
		'event_types' => array( array( 'name' => 'PAYMENT.CAPTURE.COMPLETED' ), array( 'name' => 'CHECKOUT.ORDER.APPROVED' ) ),
	)
);

$product = new WC_Product_Simple();
$product->set_name( 'Stand product' );
$product->set_regular_price( '25.00' );
$product->set_manage_stock( true );
$product->set_stock_quantity( 10 );
$product->save();
update_option( 'stand_product_id', $product->get_id() );
echo "seeded product {$product->get_id()}\n";
