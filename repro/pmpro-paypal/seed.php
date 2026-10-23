<?php
// wp eval-file seed.php — a membership site on Paid Memberships Pro with the PayPal (REST) add-on as the only gateway, sandbox,
// invented client id/secret and a stored webhook id (so the add-on verifies every webhook with PayPal, the live code path), and
// one level with a single payment of $10. PMPro's pages (checkout, confirmation, account, levels, ...) are generated.
global $wpdb;
update_option( 'pmpro_gateway', 'paypal' );
update_option( 'pmpro_gateway_environment', 'sandbox' );
update_option( 'pmpro_paypal_client_id_sandbox', 'stand-client-id' );
update_option( 'pmpro_paypal_client_secret_sandbox', 'stand-client-secret' );
update_option( 'pmpro_paypal_webhook_id_sandbox', 'WH-STAND-0001' );
update_option( 'pmpro_currency', 'USD' );

$group = pmpro_create_level_group( 'Stand levels', false );
$wpdb->insert( $wpdb->pmpro_membership_levels, array( 'name' => 'Gold (one payment)', 'description' => '', 'confirmation' => '',
	'initial_payment' => 10, 'billing_amount' => 0, 'cycle_number' => 0, 'cycle_period' => '', 'billing_limit' => 0, 'trial_amount' => 0,
	'trial_limit' => 0, 'allow_signups' => 1, 'expiration_number' => 0, 'expiration_period' => '' ) );
pmpro_add_level_to_group( $wpdb->insert_id, $group );
update_option( 'stand_level', $wpdb->insert_id );
pmpro_generatePages( array( 'account' => 'Membership Account', 'billing' => 'Membership Billing', 'cancel' => 'Membership Cancel',
	'checkout' => 'Membership Checkout', 'confirmation' => 'Membership Confirmation', 'invoice' => 'Membership Invoice',
	'levels' => 'Membership Levels' ) );
echo 'seeded level ' . get_option( 'stand_level' ) . ' checkout_page=' . get_option( 'pmpro_checkout_page_id' ) . "\n";
