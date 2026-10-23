<?php
// wp eval-file check.php <paypal-order-id> — the state the reproduction asserts on: the PMPro checkout order that holds this
// PayPal order id, the buyer's membership, the capture status at (fake) PayPal, whether PMPro offers the admin a "Recheck
// Payment" for the order, and the PayPal calls and e-mails made by the last step (run.sh clears both before each step).
global $wpdb;
$id    = $wpdb->get_var( $wpdb->prepare( "SELECT pmpro_membership_order_id FROM {$wpdb->pmpro_membership_ordermeta} WHERE meta_key = 'paypal_order_id' AND meta_value = %s", $args[0] ) );
$order = new MemberOrder( (int) $id );
$level = pmpro_getMembershipLevelForUser( $order->user_id, true );
$pp    = ( (array) get_option( 'stand_paypal_orders', array() ) )[ $args[0] ] ?? array();
$calls = array_map( function ( $c ) { return preg_replace( '#/v2/checkout/orders/[^/ ]+#', '/orders/{id}', str_replace( '/v1/notifications/', '', $c ) ); },
	(array) get_option( 'stand_paypal_calls', array() ) );
printf( "order=%d status=%s level=%s txn=%s paypal_capture=%s recheck_button=%s mails=%d calls=[%s]\n", $order->id, $order->status,
	empty( $level ) ? 'none' : $level->id, $order->payment_transaction_id ?: '-', $pp['capture']['status'] ?? '-',
	'token' !== $order->status ? '-' : ( pmpro_can_check_token_order_for_completion( $order->id ) ? 'yes' : 'no' ),
	count( (array) get_option( 'stand_mails', array() ) ), implode( ', ', $calls ) );
