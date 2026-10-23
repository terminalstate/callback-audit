<?php
// php event.php <event_type> <resource_id> [resource_status] — prints a PayPal webhook event body as PayPal posts it
// (Webhooks v1 event envelope). CHECKOUT.ORDER.APPROVED carries the order (resource_type checkout-order); PAYMENT.CAPTURE.*
// carries the capture (resource_type capture). The add-on verifies the body with PayPal's verify-webhook-signature postback.
[ , $type, $id ] = $argv;
$status = $argv[3] ?? ( 'CHECKOUT.ORDER.APPROVED' === $type ? 'APPROVED' : 'DECLINED' );
$is_order = 0 === strpos( $type, 'CHECKOUT.ORDER.' );
$event = array(
	'id'               => 'WH-STAND-' . strtoupper( substr( md5( $type . $id . microtime() ), 0, 17 ) ),
	'event_version'    => '1.0',
	'create_time'      => gmdate( 'Y-m-d\TH:i:s.000\Z' ),
	'resource_type'    => $is_order ? 'checkout-order' : 'capture',
	'resource_version' => '2.0',
	'event_type'       => $type,
	'summary'          => $is_order ? 'An order has been approved by buyer' : 'Payment capture status changed',
	'resource'         => array( 'id' => $id, 'status' => $status ),
);
if ( $is_order ) {
	$event['resource']['intent'] = 'CAPTURE';
}
echo json_encode( $event, JSON_UNESCAPED_SLASHES );
