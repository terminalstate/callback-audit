<?php
// wp eval-file create-order.php — a pending checkout order paid with Flutterwave; prints "<order id> <tx_ref>" (tx_ref as the plugin builds it).
$product = wc_get_product( (int) get_option( 'stand_product_id' ) );
$order   = wc_create_order( array( 'created_via' => 'checkout' ) );
$order->add_product( $product, 1 );
$order->set_billing_email( 'buyer@example.test' );
$order->set_currency( 'NGN' );
$order->set_payment_method( 'rave' );
$order->calculate_totals();
$order->set_status( 'pending' );
$order->save();
wc_reduce_stock_levels( $order->get_id() );
echo $order->get_id() . ' WOOC_' . $order->get_id() . '_' . time();
