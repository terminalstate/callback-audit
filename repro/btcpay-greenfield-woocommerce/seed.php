<?php
// wp eval-file seed.php <btcpay-url> — a USD shop connected to a BTCPay store (invented API key, store id and webhook
// secret; the URL is the stand's fake Greenfield API).
update_option( 'woocommerce_currency', 'USD' );
update_option( 'woocommerce_manage_stock', 'yes' );
update_option( 'btcpay_gf_url', $args[0] );
update_option( 'btcpay_gf_api_key', 'stand-api-key' );
update_option( 'btcpay_gf_store_id', 'STANDSTORE1' );
update_option( 'btcpay_gf_webhook', array( 'id' => 'stand-webhook-1', 'secret' => 'stand-webhook-secret', 'url' => home_url( '/?wc-api=btcpaygf_default' ) ) );
update_option( 'woocommerce_btcpaygf_default_settings', array( 'enabled' => 'yes' ) );
$product = new WC_Product_Simple();
$product->set_name( 'Stand product' );
$product->set_regular_price( '25.00' );
$product->set_manage_stock( true );
$product->set_stock_quantity( 10 );
$product->save();
update_option( 'stand_product_id', $product->get_id() );
echo "seeded product {$product->get_id()}\n";
