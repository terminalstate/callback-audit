<?php
// wp eval-file create-order.php — what process_payment() leaves: a pending checkout order paid with Payfast; prints "id key total".
$product = wc_get_product( (int) get_option( 'stand_product_id' ) );
$order   = wc_create_order( array( 'created_via' => 'checkout' ) );
$order->add_product( $product, 1 );
$order->set_billing_first_name( 'Test' );
$order->set_billing_last_name( 'Buyer' );
$order->set_billing_email( 'buyer@example.test' );
$order->set_currency( 'ZAR' );
$order->set_payment_method( 'payfast' );
$order->set_payment_method_title( 'Payfast' );
$order->calculate_totals();
$order->set_status( 'pending' );
$order->save();
wc_reduce_stock_levels( $order->get_id() );
echo $order->get_id() . ' ' . $order->get_order_key() . ' ' . $order->get_total();
