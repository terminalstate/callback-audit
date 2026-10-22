<?php
// wp eval-file check.php <wc-order-id> — the state the reproduction asserts on.
$order = wc_get_order( (int) $args[0] );
$pending = as_get_scheduled_actions( array( 'hook' => 'dibs_payment_created_callback', 'status' => ActionScheduler_Store::STATUS_PENDING ), 'ids' );
$notes = array_map( fn( $n ) => $n->content, wc_get_order_notes( array( 'order_id' => $order->get_id() ) ) );
$err   = count( array_filter( $notes, fn( $c ) => false !== strpos( $c, 'Error when confirming order' ) ) );
printf( "order=%d status=%s paid_date=%s _dibs_date_paid=%s charge_id=%s error_notes=%d pending_callbacks=%d nexi_calls=[%s]\n", $order->get_id(), $order->get_status(),
	$order->get_date_paid() ? 'set' : 'none', $order->get_meta( '_dibs_date_paid' ) ? 'set' : 'none', $order->get_meta( '_dibs_charge_id' ) ?: '-', $err,
	count( $pending ), implode( ', ', (array) get_option( 'stand_nexi_calls', array() ) ) );
