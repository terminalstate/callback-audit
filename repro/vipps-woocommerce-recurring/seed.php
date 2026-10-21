<?php
// wp eval-file seed.php — a Norwegian shop (NOK) with Vipps MobilePay Recurring Payments configured (invented keys and MSN).
update_option( 'woocommerce_currency', 'NOK' );
update_option( 'woocommerce_default_country', 'NO' );
update_option( 'woocommerce_vipps_recurring_settings', array(
	'enabled' => 'yes', 'test_mode' => 'no', 'client_id' => 'stand-client', 'secret_key' => 'stand-secret',
	'subscription_key' => 'stand-subscription-key', 'merchant_serial_number' => '123456',
) );
echo "seeded\n";
