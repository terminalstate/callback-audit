<?php
// What a WooCommerce ?wc-api= request does: WooCommerce calls status_header( 200 ) (WordPress: header( 'HTTP/1.1 200 OK', true, 200 ))
// before do_action( 'woocommerce_api_*' ); a gateway handler then reports a failure with http_response_code().
header( 'HTTP/1.1 200 OK', true, 200 );
http_response_code( (int) ( getenv( 'STAND_CODE' ) ?: 503 ) );
echo 'handler reported ' . http_response_code();
