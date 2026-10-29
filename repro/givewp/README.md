# Harness: GiveWP, the Stripe webhook answers 200 when the event can't be fetched from Stripe

A real WordPress site with [GiveWP](https://github.com/impress-org/givewp) and a real POST to `/?give-listener=stripe`.
`listen()` reads `php://input` and ends with `exit`, so it can't run inside PHPUnit.
Reported in [impress-org/givewp#8528](https://github.com/impress-org/givewp/issues/8528).

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]   # GiveWP develop as of 2026-10-28 (4.19.1); GIVEWP_COMMIT=… for another commit
```

Needs PHP 8.x with mysqli, composer, wp-cli, git, curl and MySQL or MariaDB. `run.sh` downloads WordPress 7.1.3, fetches
the pinned GiveWP commit with its dev dependencies (the donation is created with GiveWP's own factories), **drops and
recreates** the database `DB_NAME` (default `givewp_stand`), installs the site, seeds one donation and serves it with
`php -S` on port 8898.

## What is real and what is not

| Part | |
|---|---|
| WordPress, GiveWP, `Give_Stripe_Webhooks::listen()`, `StripeEventListener`, the `payment_intent.succeeded` listener, the donation models | **real**, GiveWP code at the pinned commit, not modified |
| The donation | a one-time Stripe Payment Element donation on a v3 form, `processing`, `gatewayTransactionId = pi_test_1`, test mode |
| Stripe API | must-use plugin `stand-fake-stripe.php` replaces only stripe-php's HTTP transport (`\Stripe\ApiRequestor::setHttpClient()`): `GET /v1/events/evt_test_1` answers 500 `api_error` ("outage") or the event ("ok"); nothing goes to Stripe |
| The delivery | the JSON body Stripe would POST; GiveWP takes only the event id from it and fetches the event from Stripe |

## The finding

For every Stripe webhook the listener fetches the event again with `Event::retrieve()`. If that request fails (a 5xx or
429 from Stripe, a DNS or TLS error), the exception reaches `listen()`, whose `catch` still sends `status_header(200)`
with "Unable to process … event" in the body. Stripe only redelivers events that did not get a 2xx, so the event is
never sent again, and a v3 (Payment Element) donation stays "processing" while Stripe has the money.

## Result

Run on 2026-10-29 (PHP 8.4.23, MariaDB, WordPress 7.1.3, GiveWP `407d6ed`, 4.19.1):

```
== before:            donation=7 status=processing gateway=stripe_payment_element stripe_calls=[]
== outage: HTTP 200  donation=7 status=processing gateway=stripe_payment_element stripe_calls=["GET \/v1\/events\/evt_test_1 (outage)"]
   body: Unable to process payment_intent.succeeded event on http://127.0.0.1:8898. Error: Stand: temporary Stripe failure
== ok:     HTTP 200  donation=7 status=publish gateway=stripe_payment_element stripe_calls=["GET \/v1\/events\/evt_test_1 (ok)"]

REPRODUCED: re-fetching the event failed inside GiveWP, but Stripe got HTTP 200 and will not resend it;
the paid donation stays 'processing' (control: the same delivery with Stripe reachable completes it).
```

With `status_header(500); exit(...)` in that `catch` the outage case answers 500 (Stripe retries) and the control case
still answers 200 and completes the donation.
