<?php
// Must-use plugin, observation only: records the status the classic webhook handler sets with http_response_code(), so the
// run can print it next to the status that actually goes out. The plugin's handler itself is not touched.
add_action( 'woocommerce_api_wc_checkoutcom_webhook', function () {
	register_shutdown_function( function () {
		file_put_contents( WP_CONTENT_DIR . '/stand-handler-codes.log', http_response_code() . "\n", FILE_APPEND );
	} );
}, 0 );
