<?php
// wp eval-file seed.php — a South African membership site (ZAR) on Paid Memberships Pro with the Payfast add-on as the only
// gateway, sandbox, invented merchant credentials and a passphrase (the add-on says one is required). Two levels in one group:
// a one-time level and a monthly subscription. PMPro's pages (checkout, confirmation, account, levels, ...) are generated.
global $wpdb;
update_option( 'pmpro_gateway', 'payfast' );
update_option( 'pmpro_gateway_environment', 'sandbox' );
update_option( 'pmpro_payfast_merchant_id', '10000100' );
update_option( 'pmpro_payfast_merchant_key', 'standmerchantkey' );
update_option( 'pmpro_payfast_passphrase', 'stand-passphrase' );
update_option( 'pmpro_payfast_debug', getenv( 'STAND_PF_DEBUG' ) ? '1' : '0' ); // only used when DNS is unavailable, see run.sh
update_option( 'pmpro_currency', 'ZAR' );
update_option( 'timezone_string', 'Africa/Johannesburg' );

$group = pmpro_create_level_group( 'Stand levels', false );
$levels = array(
	'one_time' => array( 'name' => 'Gold (one payment)', 'initial_payment' => 100, 'billing_amount' => 0, 'cycle_number' => 0, 'cycle_period' => '' ),
	'monthly'  => array( 'name' => 'Monthly', 'initial_payment' => 100, 'billing_amount' => 100, 'cycle_number' => 1, 'cycle_period' => 'Month' ),
);
foreach ( $levels as $key => $l ) {
	$wpdb->insert( $wpdb->pmpro_membership_levels, $l + array( 'description' => '', 'confirmation' => '', 'billing_limit' => 0,
		'trial_amount' => 0, 'trial_limit' => 0, 'allow_signups' => 1, 'expiration_number' => 0, 'expiration_period' => '' ) );
	pmpro_add_level_to_group( $wpdb->insert_id, $group );
	update_option( 'stand_level_' . $key, $wpdb->insert_id );
}
pmpro_generatePages( array( 'account' => 'Membership Account', 'billing' => 'Membership Billing', 'cancel' => 'Membership Cancel',
	'checkout' => 'Membership Checkout', 'confirmation' => 'Membership Confirmation', 'invoice' => 'Membership Invoice',
	'levels' => 'Membership Levels' ) );
echo 'seeded levels one_time=' . get_option( 'stand_level_one_time' ) . ' monthly=' . get_option( 'stand_level_monthly' )
	. ' checkout_page=' . get_option( 'pmpro_checkout_page_id' ) . "\n";
