<?php
// wp eval-file create-order.php — what checkout leaves before the buyer pays: a pending checkout order paid with Paystack, stock
// reduced, and the reference the plugin generates and stores in _paystack_txn_ref (order id + "_" + time). Prints "id ref".
$product = wc_get_product( (int) get_option( 'stand_product_id' ) );
$order   = wc_create_order( array( 'created_via' => 'checkout' ) );
$order->add_product( $product, 1 );
$order->set_billing_email( 'buyer@example.test' );
$order->set_currency( 'NGN' );
$order->set_payment_method( 'paystack' );
$order->set_payment_method_title( 'Paystack' );
$order->calculate_totals();
$ref = $order->get_id() . '_' . time();
$order->update_meta_data( '_paystack_txn_ref', $ref );
$order->save();
wc_reduce_stock_levels( $order->get_id() );
update_option( 'stand_paystack_amount', (int) round( $order->get_total() * 100 ) );
echo $order->get_id() . ' ' . $ref . "\n";
