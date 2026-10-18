<?php
// php itn.php <order-id> <order-key> <amount> <passphrase> — prints an ITN body (application/x-www-form-urlencoded) as Payfast
// sends it, signed as Payfast documents: md5 of the posted fields in order, urlencoded, followed by the passphrase.
list( , $id, $key, $amount, $passphrase ) = $argv;
$fields = array(
	'm_payment_id' => $id, 'pf_payment_id' => '2300' . $id, 'payment_status' => 'COMPLETE', 'item_name' => 'Stand - ' . $id,
	'item_description' => '', 'amount_gross' => number_format( (float) $amount, 2, '.', '' ), 'amount_fee' => '-5.75',
	'amount_net' => number_format( (float) $amount - 5.75, 2, '.', '' ), 'custom_str1' => $key, 'custom_str2' => '',
	'custom_str3' => $id, 'custom_str4' => '', 'custom_str5' => '', 'custom_int1' => '', 'custom_int2' => '', 'custom_int3' => '',
	'custom_int4' => '', 'custom_int5' => '', 'name_first' => 'Test', 'name_last' => 'Buyer', 'email_address' => 'buyer@example.test',
	'merchant_id' => '10000100',
);
$s = '';
foreach ( $fields as $k => $v ) { $s .= $k . '=' . urlencode( $v ) . '&'; }
$fields['signature'] = md5( $s . 'passphrase=' . urlencode( $passphrase ) );
echo http_build_query( $fields );
