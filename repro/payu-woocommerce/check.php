<?php
// wp eval-file check.php <wc-order-id> — the state the reproduction asserts on.
$order = wc_get_order( (int) $args[0] );
printf( "order=%d status=%s paid_date=%s payu_statuses=%s\n", $order->get_id(), $order->get_status(),
	$order->get_date_paid() ? 'set' : 'none',
	implode( ',', array_map( fn( $m ) => $m->value, $order->get_meta( '_payu_order_status', false ) ) ) );
