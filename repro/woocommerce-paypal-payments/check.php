<?php
// wp eval-file check.php <wc-order-id> — prints the state the reproduction asserts on.
$order = wc_get_order( (int) ( $args[0] ?? get_option( 'stand_wc_order_id' ) ) );
$notes = array_map( fn( $n ) => $n->content, wc_get_order_notes( array( 'order_id' => $order->get_id() ) ) );
printf( "order=%d status=%s paid_date=%s fees_meta=%s notes=%s\n",
	$order->get_id(),
	$order->get_status(),
	$order->get_date_paid() ? 'set' : 'none',
	$order->get_meta( '_ppcp_paypal_fees' ) ? 'set' : 'none',
	wp_json_encode( array_reverse( $notes ) ) );
