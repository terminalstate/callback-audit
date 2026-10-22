<?php
// wp eval-file check.php <wc-order-id> — the state the reproduction asserts on.
$order = wc_get_order( (int) $args[0] );
printf( "order=%d status=%s paid_date=%s payment_id=%s gc_calls=[%s]\n", $order->get_id(), $order->get_status(),
	$order->get_date_paid() ? 'set' : 'none', $order->get_meta( '_gocardless_payment_id' ) ?: '-', implode( ', ', (array) get_option( 'stand_gc_calls', array() ) ) );
