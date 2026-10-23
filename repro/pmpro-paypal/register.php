<?php
// wp eval-file register.php — runs the add-on's own webhook registration (PMProGateway_paypal::maybe_register_webhook(), called
// when the admin saves the payment settings and no webhook id is stored) and prints the event types it asks PayPal for. The
// stand site is plain http, which the add-on refuses to register, so rest_url() is reported as https for this call only; the
// stored webhook id is put back afterwards.
$saved = get_option( 'pmpro_paypal_webhook_id_sandbox' );
delete_option( 'pmpro_paypal_webhook_id_sandbox' );
add_filter( 'rest_url', function ( $url ) { return preg_replace( '#^http://#', 'https://', $url ); } );
PMProGateway_paypal::maybe_register_webhook();
update_option( 'pmpro_paypal_webhook_id_sandbox', $saved );
$req = json_decode( (string) get_option( 'stand_paypal_registered' ), true );
echo implode( ' ', wp_list_pluck( $req['event_types'] ?? array(), 'name' ) ), "\n";
