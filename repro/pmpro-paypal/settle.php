<?php
// wp eval-file settle.php <paypal-order-id> <COMPLETED|DECLINED> — what happens later at PayPal to a PENDING capture: the review
// (or eCheck) clears and the capture becomes COMPLETED, or it is refused and the capture is DECLINED (PayPal then sends
// PAYMENT.CAPTURE.COMPLETED or PAYMENT.CAPTURE.DENIED). Only the fake's stored state changes.
$orders = (array) get_option( 'stand_paypal_orders', array() );
$orders[ $args[0] ]['capture']['status'] = $args[1];
unset( $orders[ $args[0] ]['capture']['status_details'] );
update_option( 'stand_paypal_orders', $orders, false );
echo "capture of {$args[0]} is now {$args[1]} at PayPal\n";
