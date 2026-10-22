<?php
// wp eval-file check.php <wc-order-id> — the state the reproduction asserts on.
$order = wc_get_order( (int) $args[0] );
$notes = wc_get_order_notes( array( 'order_id' => $order->get_id(), 'type' => 'internal' ) );
printf( "order=%d status=%s paid_date=%s transaction_id=%s notes=%d paystack_calls=%d\n", $order->get_id(), $order->get_status(),
	$order->get_date_paid() ? 'set' : 'none', $order->get_transaction_id() ?: '-', count( $notes ), (int) get_option( 'stand_paystack_calls', 0 ) );
