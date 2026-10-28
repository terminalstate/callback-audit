<?php
// wp eval-file check.php: prints the state the reproduction asserts on.
$donation = \Give\Donations\Models\Donation::find( (int) get_option( 'stand_donation_id' ) );
printf( "donation=%s status=%s gateway=%s stripe_calls=%s\n",
	$donation ? $donation->id : 'missing',
	$donation ? $donation->status->getValue() : '-',
	$donation ? $donation->gatewayId : '-',
	wp_json_encode( get_option( 'stand_stripe_calls', array() ) ) );
