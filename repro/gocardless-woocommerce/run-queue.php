<?php
// wp eval-file run-queue.php — runs every pending webhook action through Action Scheduler's own runner (as WP-Cron would a second
// later); prints each action's id and final status.
$store = ActionScheduler::store();
$ids   = $store->query_actions( array( 'hook' => 'woocommerce_gocardless_process_webhook_payload_async', 'status' => ActionScheduler_Store::STATUS_PENDING, 'per_page' => 10 ) );
foreach ( $ids as $id ) {
	ActionScheduler::runner()->process_action( $id, 'stand' );
	echo "action $id: " . $store->get_status( $id ) . "\n";
}
if ( ! $ids ) {
	echo "no pending action\n";
}
