<?php
// php postback.php <vendor-dir> <verifier-url> <ipn-file> [fixed]
// Lines marked "module" are copied from Payment::confirm() in akaunting/module-paypal-standard (Http/Controllers/Payment.php,
// commit c74bdeb): the IPN fields go into the second argument of Guzzle's post(), which is the request *options* array.
require $argv[1] . '/autoload.php';
parse_str(trim(file_get_contents($argv[3])), $request);   // what Laravel's $request->toArray() holds for the IPN POST
$client = new GuzzleHttp\Client(['verify' => false]);      // module
$paypal_request['cmd'] = '_notify-validate';              // module
foreach ($request as $key => $value) {                     // module
    $paypal_request[$key] = urlencode(html_entity_decode($value, ENT_QUOTES, 'UTF-8'));   // module
}
if (($argv[4] ?? '') === 'fixed') {
    $response = $client->post($argv[2], ['body' => 'cmd=_notify-validate&' . trim(file_get_contents($argv[3])),
        'headers' => ['Content-Type' => 'application/x-www-form-urlencoded']]);
} else {
    $response = $client->post($argv[2], $paypal_request);  // module
}
echo $response->getBody()->getContents();
