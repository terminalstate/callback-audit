<?php
// wp eval-file create-order.php <invoice-id> — an order paid on-chain: BTCPay already sent InvoiceProcessing (paid in full,
// waiting for confirmations), so the plugin put the order on-hold; the invoice id is stored as BTCPay_id.
$product = wc_get_product( (int) get_option( 'stand_product_id' ) );
$order   = wc_create_order( array( 'created_via' => 'checkout' ) );
$order->add_product( $product, 1 );
$order->set_billing_email( 'buyer@example.test' );
$order->set_payment_method( 'btcpaygf_default' );
$order->set_payment_method_title( 'BTCPay' );
$order->calculate_totals();
$order->update_meta_data( 'BTCPay_id', $args[0] );
$order->save();
wc_reduce_stock_levels( $order->get_id() );
$order->update_status( 'on-hold', 'Invoice payment received fully, waiting for settlement.' );
echo $order->get_id();
