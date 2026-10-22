<?php
// php itn.php <payfast-redirect-url> <pf_payment_id> <passphrase> [custom_str1]
// Builds the ITN body (application/x-www-form-urlencoded) that Payfast posts to the notify_url after the buyer pays the payment
// the site redirected to: the fields from the redirect, in the order Payfast sends them, payment_status COMPLETE, signed as
// Payfast documents — md5 of the posted fields in order, urlencoded, followed by &passphrase=. For a subscription Payfast adds
// `token` and `billing_date`. The optional 4th argument replaces custom_str1 (used for a renewal ITN a month later).
[ , $url, $pf_id, $passphrase ] = $argv;
parse_str( (string) parse_url( $url, PHP_URL_QUERY ), $r );
$amount = number_format( (float) $r['amount'], 2, '.', '' );
$fields = array(
	'm_payment_id'     => $r['m_payment_id'],
	'pf_payment_id'    => $pf_id,
	'payment_status'   => 'COMPLETE',
	'item_name'        => $r['item_name'],
	'item_description' => '',
	'amount_gross'     => $amount,
	'amount_fee'       => '-2.30',
	'amount_net'       => number_format( (float) $amount - 2.30, 2, '.', '' ),
	'custom_str1'      => $argv[4] ?? ( $r['custom_str1'] ?? '' ),
	'custom_str2'      => '', 'custom_str3' => '', 'custom_str4' => '', 'custom_str5' => '',
	'custom_int1'      => $r['custom_int1'] ?? '', 'custom_int2' => '', 'custom_int3' => '', 'custom_int4' => '', 'custom_int5' => '',
	'name_first'       => $r['name_first'] ?? '',
	'name_last'        => $r['name_last'] ?? '',
	'email_address'    => $r['email_address'],
	'merchant_id'      => $r['merchant_id'],
);
if ( ! empty( $r['subscription_type'] ) ) {
	$h                      = md5( $r['m_payment_id'] );
	$fields['token']        = substr( $h, 0, 8 ) . '-' . substr( $h, 8, 4 ) . '-' . substr( $h, 12, 4 ) . '-' . substr( $h, 16, 4 ) . '-' . substr( $h, 20, 12 );
	$fields['billing_date'] = $r['billing_date'];
}
$s = '';
foreach ( $fields as $k => $v ) {
	$s .= $k . '=' . urlencode( $v ) . '&';
}
$fields['signature'] = md5( $s . 'passphrase=' . urlencode( $passphrase ) );
echo http_build_query( $fields );
