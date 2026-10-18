<?php
// Router for `php -S`: PayPal's IPN verifier as documented — "Your listener HTTPS POSTs the complete, unaltered message back
// to PayPal; the message must contain the same fields (in the same order) as the original message" and the reply is
// "VERIFIED" or "INVALID" (https://developer.paypal.com/api/nvp-soap/ipn/IPNIntro/). The original IPN is in IPN_FILE.
$original = trim((string) file_get_contents(getenv('IPN_FILE')));
$body = file_get_contents('php://input');
header('Content-Type: text/plain');
echo $body === 'cmd=_notify-validate&' . $original ? 'VERIFIED' : 'INVALID';
file_put_contents(getenv('LOG_FILE'), 'postback body=[' . $body . ']' . PHP_EOL, FILE_APPEND);
