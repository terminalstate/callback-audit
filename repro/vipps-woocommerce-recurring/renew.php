<?php
// wp eval-file renew.php <mode> — what WooCommerce Subscriptions does on the renewal date: a renewal order paid with Vipps
// MobilePay Recurring (agreement agr_STAND1), then the gateway's scheduled_subscription_payment() hook. Prints the order and the
// Vipps side; then, if Vipps holds a charge for this order, delivers its recurring.charge-captured.v1 webhook to the plugin's handler.
update_option( 'stand_vipps_mode', $args[0] );
delete_option( 'stand_vipps_calls' );
$before  = array_keys( get_option( 'stand_vipps_charges', array() ) );
$order   = wc_create_order( array( 'created_via' => 'subscription' ) );
$product = new WC_Product_Simple();
$product->set_name( 'Stand plan' );
$product->set_regular_price( '199.00' );
$product->save();
$order->add_product( $product, 1 );
$order->set_currency( 'NOK' );
$order->set_payment_method( 'vipps_recurring' );
$order->calculate_totals();
$order->update_meta_data( '_agreement_id', 'agr_STAND1' );
$order->set_status( 'pending' );
$order->save();
$gateway = WC_Gateway_Vipps_Recurring::get_instance();
$gateway->scheduled_subscription_payment( 199.00, $order );
$order   = wc_get_order( $order->get_id() );
$charges = get_option( 'stand_vipps_charges', array() );
$new     = array_diff( array_keys( $charges ), $before );
printf( "order=%d status=%s charge_id_stored=%s last_note=%s\n", $order->get_id(), $order->get_status(),
	$order->get_meta( '_charge_id' ) ?: 'none', wp_json_encode( wc_get_order_notes( array( 'order_id' => $order->get_id(), 'limit' => 1 ) )[0]->content ?? '' ) );
foreach ( $new as $id ) {
	printf( "vipps: %s status=%s due=%s amount=%d\n", $id, $charges[ $id ]['status'], $charges[ $id ]['due'], $charges[ $id ]['amount'] );
}
printf( "calls: %s\n", implode( '; ', get_option( 'stand_vipps_calls', array() ) ) );
foreach ( $new as $id ) {
	if ( 'DUE' !== $charges[ $id ]['status'] ) {
		continue;
	}
	// The due date comes; Vipps charges the customer and sends the webhook.
	$charges[ $id ]['status'] = 'CHARGED';
	update_option( 'stand_vipps_charges', $charges, false );
	update_option( 'stand_vipps_mode', 'ok' );
	$gateway->handle_webhook_callback( array( 'eventType' => 'recurring.charge-captured.v1', 'chargeId' => $id, 'agreementId' => 'agr_STAND1', 'amount' => 19900 ) );
	$order = wc_get_order( $order->get_id() );
	printf( "after Vipps charged %s and sent recurring.charge-captured.v1: order status=%s paid_date=%s\n", $id, $order->get_status(), $order->get_date_paid() ? 'set' : 'none' );
}
