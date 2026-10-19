<?php
// wp eval-file create-order.php <payu-order-id> — what process_payment() leaves after PayU created the order: a checkout order
// paid with PayU, transaction id = the PayU order id, status = global_default_on_hold_status. Prints the WooCommerce order id.
$product = wc_get_product( (int) get_option( 'stand_product_id' ) );
$order   = wc_create_order( array( 'created_via' => 'checkout' ) );
$order->add_product( $product, 1 );
$order->set_billing_email( 'buyer@example.test' );
$order->set_currency( 'PLN' );
$order->set_payment_method( 'payustandard' );
$order->set_payment_method_title( 'PayU' );
$order->calculate_totals();
$order->set_transaction_id( $args[0] );
$order->save();
wc_reduce_stock_levels( $order->get_id() );
$order->update_status( get_option( 'payu_settings_option_name' )['global_default_on_hold_status'], 'Awaiting PayU payment.' );
echo $order->get_id();
