<?php
// wp eval-file seed.php: a one-time Stripe Payment Element donation that is still "processing" (pi_test_1).
use Give\DonationForms\Models\DonationForm;
use Give\Donations\Models\Donation;
use Give\Donations\ValueObjects\DonationStatus;
use Give\Donations\ValueObjects\DonationType;
use Give\PaymentGateways\Gateways\Stripe\StripePaymentElementGateway\StripePaymentElementGateway;

give_update_option( '_give_stripe_get_all_accounts', array(
	'account_1' => array(
		'type'                 => 'manual',
		'live_secret_key'      => 'sk_live_stand',
		'live_publishable_key' => 'pk_live_stand',
		'test_secret_key'      => 'sk_test_stand',
		'test_publishable_key' => 'pk_test_stand',
	),
) );
give_update_option( '_give_stripe_default_account', 'account_1' );
give_update_option( 'test_mode', 'enabled' );
// The site takes Stripe donations on v3 forms: the Payment Element gateway is enabled (this is what loads the listener).
give_update_option( 'gateways_v3', array( 'stripe_payment_element' => '1' ) );
give_update_option( 'gateways', array( 'stripe_payment_element' => '1', 'manual' => '1' ) );
update_option( 'stand_stripe_mode', 'ok' );
delete_option( 'stand_stripe_calls' );

$form = DonationForm::factory()->create();
$donation = Donation::factory()->create( array(
	'formId' => $form->id,
	'type'   => DonationType::SINGLE(),
	'status' => DonationStatus::PROCESSING(),
) );
$donation->gatewayId            = StripePaymentElementGateway::id();
$donation->gatewayTransactionId = 'pi_test_1';
$donation->save();
update_option( 'stand_donation_id', $donation->id );
echo 'seeded form ' . $form->id . ', donation ' . $donation->id . "\n";
