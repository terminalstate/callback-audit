# LearnPress: PayPal subscription webhook answers HTTP 200 to every failure

Reported in [LearnPress/learnpress#650](https://github.com/LearnPress/learnpress/issues/650).

`/wp-json/lp/v1/gateways/{gateway}/subscription-webhook` catches every `Throwable` in `listen_subscription_webhook()` and returns a
plain `LearnPress\Helpers\Response` object, which WordPress REST sends with status 200. PayPal re-sends a webhook only when the answer is
not 2xx, so a subscription activation or renewal (`PAYMENT.SALE.COMPLETED`) that meets a temporary error is never delivered again.
The 4xx codes the plugin itself throws (400 for a failed signature check, 404 for an unknown or disabled gateway) are lost the same way.

The stand is a real WordPress 7.1.3 site with LearnPress from WordPress.org (4.4.13, released 2026-10-30; the controller is identical
on `develop` as of that release). Only LearnPress's calls to the PayPal sandbox API are answered locally (`stand-fake-paypal.php`): the OAuth token, and
`verify-webhook-signature`, which times out (`outage`) or answers `FAILURE` (`fail`).

Run: `DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]` (PHP 8 with mysqli, wp-cli, curl, git, MySQL/MariaDB).

Observed (2026-10-31, LearnPress 4.4.13; the same on 4.4.10 on 2026-10-13):

```
== PAYMENT.SALE.COMPLETED, verify-webhook-signature times out: HTTP 200  {"status":"error","message":"cURL error 28: Operation timed out after 60001 milliseconds with 0 bytes received","data":{}}
   PayPal calls: ["\/v1\/oauth2\/token","\/v1\/notifications\/verify-webhook-signature"]
== verification answers FAILURE (plugin throws code 400): HTTP 200  {"status":"error","message":"PayPal webhook verification failed.","data":{}}
== unknown gateway (plugin throws code 404): HTTP 200  {"status":"error","message":"Gateway not found.","data":{}}
== with patch, verify-webhook-signature times out: HTTP 500  {"status":"error","message":"cURL error 28: Operation timed out after 60001 milliseconds with 0 bytes received","data":{}}
== with patch, verification FAILURE: HTTP 400
== with patch, unknown gateway: HTTP 404
```

`fix-webhook-status.patch` (against `develop`): return a `WP_REST_Response` with the same body: the exception's code when it is 4xx,
otherwise 500. Notes for the stand: LearnPress registers its REST routes only for `/wp-json/lp/` URLs, and the PHP built-in server runs
with `opcache.enable=0` so the patched file is picked up at once.
