# Harness: Paid Memberships Pro, a Stripe webhook that can't fetch its event still answers 200

A real WordPress site with Paid Memberships Pro and a member with an active Stripe subscription. The script posts a
Stripe webhook delivery to PMPro's own `admin-ajax.php?action=stripe_webhook` endpoint while the Stripe API fails in
different ways. PMPro has no test suite, so this is a site, not a test file.

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]       # PMPro 3.8.8 (bb8b0dd)
PMPRO_REPO=https://github.com/<fork>/paid-memberships-pro PMPRO_COMMIT=<sha> bash run.sh [WORK_DIR]   # another commit
```

Needs PHP 8 with mysqli, [WP-CLI](https://wp-cli.org/), git, curl and an empty MySQL or MariaDB database (`DB_NAME`,
default `pmpro_stand`; it is created if missing). `run.sh` downloads WordPress 7.1.3, installs it, checks out PMPro at
the pinned commit, adds the must-use plugin, seeds the member and starts PHP's built-in server on `PORT` (default 8899).

## What is real and what is not

| Part | |
|---|---|
| WordPress, PMPro, `services/stripe-webhook.php`, `PMPro_Stripe_Webhook_Handler`, the subscription and membership update | **real**, over HTTP on a real database |
| Stripe API | fake: the must-use plugin `stand-fake-stripe.php` gives PMPro's bundled stripe-php its own HTTP client (`\Stripe\ApiRequestor::setHttpClient()`). `GET /v1/events/evt_test_1` answers 500 `api_error` (`outage`), 404 `resource_missing` (`missing`) or a `customer.subscription.deleted` event for `sub_test_1` (`ok`) |
| The member | user `member`, level 1, an active PMPro subscription `sub_test_1`, created by `seed.php` |

## The finding

PMPro re-fetches every webhook event from Stripe with `Stripe_Event::retrieve()`. When that call fails, the handler
logs the error and returns without setting a status
([class-pmpro-stripe-webhook-handler.php#L89-L126](https://github.com/strangerstudios/paid-memberships-pro/blob/bb8b0dd948e5476759648660f148427b05325a4b/services/class-pmpro-stripe-webhook-handler.php#L89-L126)),
so Stripe gets a 200. Stripe only redelivers events that did not get a 2xx (https://docs.stripe.com/webhooks), so the
event is lost: a cancelled subscription stays active in PMPro and the membership never ends.

## Result

| Stripe's answer to the event fetch | 3.8.8 (bb8b0dd) and `dev` (ae37d2a, 3.8.9) | with the change in the PR |
|---|---|---|
| 500 `api_error` | 200, subscription stays active, no end date | 503, so Stripe redelivers |
| 404 `resource_missing` | 200 | 200 |
| the event | 200, subscription cancelled, end date set | the same |

`run.sh` prints `REPRODUCED` and exits 0 while the bug is present; on a commit with a fix it says what changed and
exits 1.
