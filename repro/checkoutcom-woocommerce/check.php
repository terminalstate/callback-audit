<?php
$order = wc_get_order( (int) $args[0] );
$notes = array_map( fn( $n ) => $n->content, wc_get_order_notes( array( 'order_id' => $order->get_id() ) ) );
printf( "order=%d status=%s paid_date=%s cko_payment_id=%s last_note=%s\n", $order->get_id(), $order->get_status(),
	$order->get_date_paid() ? 'set' : 'none', $order->get_meta( '_cko_payment_id' ) ?: 'none', wp_json_encode( $notes[0] ?? '' ) );
