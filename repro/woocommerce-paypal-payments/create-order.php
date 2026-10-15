<?php
// wp eval-file create-order.php <paypal-order-id> — the state an iDEAL checkout leaves behind: the WooCommerce order is
// `pending`, created via checkout, paid with ppcp-ideal, linked to the PayPal order; stock is held.
$paypal_order_id = $args[0] ?? 'PPSTAND1';
$product         = wc_get_product( (int) get_option( 'stand_product_id' ) );
$order           = wc_create_order( array( 'created_via' => 'checkout' ) );
$order->add_product( $product, 1 );
$order->set_billing_country( 'NL' );
$order->set_billing_email( 'buyer@example.test' );
$order->set_currency( 'EUR' );
$order->set_payment_method( 'ppcp-ideal' );
$order->set_payment_method_title( 'iDEAL' );
$order->calculate_totals();
$order->update_meta_data( '_ppcp_paypal_order_id', $paypal_order_id );
$order->update_meta_data( '_ppcp_paypal_intent', 'CAPTURE' );
$order->set_status( 'pending' );
$order->save();
wc_reduce_stock_levels( $order->get_id() );
update_option( 'stand_wc_order_id', (string) $order->get_id() );
echo $order->get_id();
