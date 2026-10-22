<?php
// php sign.php <resource_type> <action> <link-key> <link-id> <order-id> <secret> — prints the Webhook-Signature header (HMAC-SHA256 of the
// body with the webhook secret, as GoCardless signs it), then the body: one event, like GoCardless sends.
[ , $type, $action, $link_key, $link_id, $order_id, $secret ] = $argv;
$body = json_encode( array( 'events' => array( array( 'id' => 'EV' . substr( md5( $type . $action . $link_id ), 0, 12 ), 'created_at' => gmdate( 'Y-m-d\TH:i:s.000\Z' ),
	'resource_type' => $type, 'action' => $action, 'links' => array( $link_key => $link_id ),
	'details' => array( 'origin' => 'gocardless', 'cause' => $type . '_' . $action ), 'metadata' => new stdClass(),
	'resource_metadata' => array( 'order_id' => (string) $order_id ) ) ) ) );
echo hash_hmac( 'sha256', $body, $secret ), "\n", $body;
