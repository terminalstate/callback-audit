<?php
// wp eval-file create-order.php — what a Pay by Bank checkout leaves when the bank's answer is still "fulfilling" at the buyer's return,
// or the buyer never returns: a pending checkout order paid with GoCardless, stock reduced, the billing request stored by the gateway's own
// update_order_resource() (meta _gocardless_billing_request + _gocardless_billing_request_id), no payment yet. Prints "id BR-id".
$product = wc_get_product( (int) get_option( 'stand_product_id' ) );
$order   = wc_create_order( array( 'created_via' => 'checkout' ) );
$order->add_product( $product, 1 );
$order->set_billing_email( 'buyer@example.test' );
$order->set_currency( 'GBP' );
$order->set_payment_method( 'gocardless' );
$order->set_payment_method_title( 'Pay by Bank' );
$order->calculate_totals();
$order->save();
wc_reduce_stock_levels( $order->get_id() );
$br      = 'BR' . $order->get_id() . 'STAND';
$gateway = WC()->payment_gateways()->payment_gateways()['gocardless'];
$gateway->update_order_resource( $order, 'billing_request', array( 'id' => $br, 'status' => 'fulfilling',
	'metadata' => array( 'order_id' => (string) $order->get_id() ) ) );
update_option( 'stand_gc_order_id', $order->get_id() );
update_option( 'stand_gc_amount', (int) round( $order->get_total() * 100 ) );
echo $order->get_id() . ' ' . $br . "\n";
