<?php
// wp eval-file create-order.php [payment-id] — the state WC_Gateway_Checkout_Com_Cards::process_payment() leaves when the
// payment needs 3-D Secure: create_payment() returns only ['3d' => url] and process_payment() adds the "3d Redirect waiting"
// note and redirects; `_cko_payment_id` is written only later, by callback_handler(), if the browser comes back.
// With a payment id argument the order is in the state after that return (the control case).
$product = wc_get_product( (int) get_option( 'stand_product_id' ) );
$order   = wc_create_order( array( 'created_via' => 'checkout' ) );
$order->add_product( $product, 1 );
$order->set_billing_email( 'buyer@example.test' );
$order->set_currency( 'EUR' );
$order->set_payment_method( 'wc_checkout_com_cards' );
$order->set_payment_method_title( 'Credit Card' );
$order->calculate_totals();
$order->set_status( 'pending' );
$order->save();
wc_reduce_stock_levels( $order->get_id() );
$order->add_order_note( 'Checkout.com 3d Redirect waiting. URL : https://3ds2-sandbox.ckotech.co/interceptor/3ds_stand' );
if ( ! empty( $args[0] ) ) {
	$order->update_meta_data( '_cko_payment_id', $args[0] );
	$order->save();
}
echo $order->get_id();
