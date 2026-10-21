<?php
// wp eval-file check.php <wc-order-id>
$order = wc_get_order( (int) $args[0] );
printf( "order=%d status=%s paid_date=%s processed_ids=%s\n", $order->get_id(), $order->get_status(), $order->get_date_paid() ? 'set' : 'none',
	wp_json_encode( $order->get_meta( '_flw_processed_webhook_ids', true ) ?: array() ) );
