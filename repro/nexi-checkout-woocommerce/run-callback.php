<?php
// wp eval-file run-callback.php — runs every pending dibs_payment_created_callback action through Action Scheduler's own runner, as
// WP-Cron would after the 120 s delay; prints each action's id and final status.
$store = ActionScheduler::store();
$ids   = $store->query_actions( array( 'hook' => 'dibs_payment_created_callback', 'status' => ActionScheduler_Store::STATUS_PENDING, 'per_page' => 10 ) );
foreach ( $ids as $id ) {
	ActionScheduler::runner()->process_action( $id, 'stand' );
	echo "action $id: " . $store->get_status( $id ) . "\n";
}
if ( ! $ids ) {
	echo "no pending action\n";
}
