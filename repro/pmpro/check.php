<?php
// wp eval-file check.php — prints the state the reproduction asserts on.
$user  = get_user_by( 'login', 'member' );
$sub   = PMPro_Subscription::get_subscription_from_subscription_transaction_id( 'sub_test_1', 'stripe', 'sandbox' );
$level = pmpro_getMembershipLevelForUser( $user->ID );
printf( "subscription=%s level=%s level_enddate=%s stripe_calls=%s\n",
	$sub ? $sub->get_status() : 'missing',
	$level ? $level->id : 'none',
	( $level && ! empty( $level->enddate ) ) ? date( 'Y-m-d', $level->enddate ) : 'never',
	wp_json_encode( get_option( 'stand_stripe_calls', array() ) ) );
