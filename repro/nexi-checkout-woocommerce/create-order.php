<?php
// wp eval-file create-order.php <payment-id> — what the redirect checkout leaves before the buyer pays in the Swish app: a pending
// checkout order paid with Nexi Checkout (Swish), stock reduced, and the Nexi payment id in _dibs_payment_id. Prints "id number amount".
$product = wc_get_product( (int) get_option( 'stand_product_id' ) );
$order   = wc_create_order( array( 'created_via' => 'checkout' ) );
$order->add_product( $product, 1 );
$order->set_billing_email( 'buyer@example.test' );
$order->set_currency( 'SEK' );
$order->set_payment_method( 'nets_easy_swish' );
$order->set_payment_method_title( 'Swish' );
$order->calculate_totals();
$order->update_meta_data( '_dibs_payment_id', $args[0] );
$order->update_meta_data( '_dibs_checkout_flow', 'redirect' );
$order->save();
wc_reduce_stock_levels( $order->get_id() );
$amount = (int) round( $order->get_total() * 100 );
update_option( 'stand_nexi_amount', $amount );
update_option( 'stand_nexi_reference', $order->get_order_number() );
echo $order->get_id() . ' ' . $order->get_order_number() . ' ' . $amount . "\n";
