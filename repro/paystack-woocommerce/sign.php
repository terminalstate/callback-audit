<?php
// php sign.php <reference> <amount-kobo> <secret> — prints the x-paystack-signature header value, then the body, as Paystack signs it:
// HMAC-SHA512 of the raw body with the secret key.
[ , $ref, $amount, $secret ] = $argv;
$body = json_encode( array( 'event' => 'charge.success', 'data' => array( 'reference' => $ref, 'amount' => (int) $amount,
	'currency' => 'NGN', 'status' => 'success', 'channel' => 'bank_transfer' ) ) );
echo hash_hmac( 'sha512', $body, $secret ), "\n", $body;
