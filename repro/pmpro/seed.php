<?php
// wp eval-file seed.php — a member with an active Stripe subscription (level 1, sub_test_1).
global $wpdb;
update_option( 'pmpro_gateway', 'stripe' );
update_option( 'pmpro_gateway_environment', 'sandbox' );
update_option( 'pmpro_stripe_secretkey', 'sk_test_stand' );
update_option( 'pmpro_stripe_publishablekey', 'pk_test_stand' );
update_option( 'stand_stripe_mode', 'ok' );
delete_option( 'stand_stripe_calls' );

$wpdb->query( "DELETE FROM {$wpdb->pmpro_membership_levels} WHERE id = 1" );
$wpdb->insert( $wpdb->pmpro_membership_levels, array( 'id' => 1, 'name' => 'Monthly', 'initial_payment' => 10, 'billing_amount' => 10, 'cycle_number' => 1, 'cycle_period' => 'Month', 'allow_signups' => 1 ) );

$user_id = username_exists( 'member' ) ?: wp_create_user( 'member', wp_generate_password(), 'member@example.test' );
pmpro_changeMembershipLevel( 1, $user_id );

$sub = PMPro_Subscription::create( array(
	'user_id'                     => $user_id,
	'membership_level_id'         => 1,
	'gateway'                     => 'stripe',
	'gateway_environment'         => 'sandbox',
	'subscription_transaction_id' => 'sub_test_1',
	'status'                      => 'active',
	'billing_amount'              => 10,
	'cycle_number'                => 1,
	'cycle_period'                => 'Month',
) );
echo 'seeded user ' . $user_id . ', subscription ' . ( $sub ? $sub->get_id() : 'FAILED' ) . "\n";
