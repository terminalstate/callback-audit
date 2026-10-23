<?php
// wp eval-file recheck.php <paypal-order-id> — what the admin's "Recheck Payment" button on a token order runs (core
// adminpages/orders.php → pmpro_check_token_order_for_completion() → the add-on's check_token_order()). Prints its answer.
global $wpdb;
$id = $wpdb->get_var( $wpdb->prepare( "SELECT pmpro_membership_order_id FROM {$wpdb->pmpro_membership_ordermeta} WHERE meta_key = 'paypal_order_id' AND meta_value = %s", $args[0] ) );
$r  = pmpro_check_token_order_for_completion( (int) $id );
echo true === $r ? 'true (checkout completed)' : ( false === $r ? 'false' : $r ), "\n";
