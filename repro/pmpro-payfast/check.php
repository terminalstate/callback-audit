<?php
// wp eval-file check.php <order-code> — the state the reproduction asserts on: the checkout order, the buyer's membership,
// every order of that buyer, whether PMPro offers the admin a "Recheck Payment" for the order, and the e-mails sent and validation
// calls made by the last ITN (recorded by the stand mu-plugin; run.sh clears both before each ITN).
$order = new MemberOrder( $args[0] );
$level = pmpro_getMembershipLevelForUser( $order->user_id, true );
$all   = array();
foreach ( MemberOrder::get_orders( array( 'user_id' => $order->user_id ) ) as $o ) {
	$all[] = $o->status . ( $o->payment_transaction_id && $o->payment_transaction_id !== $o->code ? '(' . $o->payment_transaction_id . ')' : '' );
}
printf( "order=%s status=%s level=%s orders=[%s] recheck_button=%s mails=%d validate_calls=%d\n", $order->code, $order->status,
	empty( $level ) ? 'none' : $level->id, implode( ',', array_reverse( $all ) ),
	'token' !== $order->status ? '-' : ( pmpro_can_check_token_order_for_completion( $order->id ) ? 'yes' : 'no' ),
	count( (array) get_option( 'stand_mails', array() ) ), count( (array) get_option( 'stand_payfast_calls', array() ) ) );
