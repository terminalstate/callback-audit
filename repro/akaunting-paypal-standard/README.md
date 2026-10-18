# Harness: Akaunting PayPal Standard, the IPN postback is sent with an empty body

The module records a PayPal Standard payment only after PayPal answers `VERIFIED` to the IPN postback in
`Payment::confirm()`. That postback passes the IPN fields as the second argument of Guzzle's `post()`, which is the request
*options* array, so PayPal receives an empty body and answers `INVALID`. Reported in
[akaunting/module-paypal-standard#8](https://github.com/akaunting/module-paypal-standard/issues/8), fix proposed in
[#9](https://github.com/akaunting/module-paypal-standard/pull/9).

```
bash run.sh [WORK_DIR]
```

Needs PHP 8 and Composer (installs `guzzlehttp/guzzle` ^7.8 into `WORK_DIR`).

## What is real and what is not

| Part | |
|---|---|
| The postback: `new Client([...])`, the `$paypal_request` loop and `$client->post($url, $paypal_request)`, copied from `confirm()` | **real** (lines marked `// module` in `postback.php`), with real Guzzle 7 |
| The IPN | `ipn.txt`, a `web_accept` notification in PayPal's format (invented ids and addresses) |
| PayPal's verifier | fake: `fake-paypal.php` answers `VERIFIED` only when the postback is `cmd=_notify-validate&` followed by the original message, unchanged, as PayPal documents ("the complete, unaltered message", developer.paypal.com/api/nvp-soap/ipn/IPNIntro/), otherwise `INVALID` |

## Result

| Postback | Body the verifier receives | Answer |
|---|---|---|
| `$client->post($url, $paypal_request)` (module) | empty | `INVALID` |
| `$client->post($url, ['body' => 'cmd=_notify-validate&' . <raw IPN>, ...])` | the original IPN | `VERIFIED` |

Run on 2026-10-18 (module `master` as of that day, Guzzle 7.16.0, PHP 8.4):

```
module's postback  -> PayPal answers: INVALID
raw-body postback  -> PayPal answers: VERIFIED
postback body=[]
postback body=[cmd=_notify-validate&mc_gross=25.00&protection_eligibility=Eligible&payer_id=STANDPAYER1&payment_date=10%
REPRODUCED: the module posts an empty body, so every IPN is INVALID and no payment is recorded.
```
