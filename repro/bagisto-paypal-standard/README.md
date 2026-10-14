# Harness: Bagisto PayPal Standard, a buyer who doesn't come back pays but gets no order

Two Pest tests added to Bagisto's own `packages/Webkul/Paypal/tests/Feature/PaypalStandardTest.php`
(`paypal-standard-ipn-test.patch`), run inside the project's suite on a migrated and seeded database.

```
DB_USERNAME=… DB_PASSWORD=… DB_DATABASE=bagisto_stand bash run.sh [WORK_DIR]      # 2.4 at 73e15b7
BAGISTO_COMMIT=<sha> bash run.sh [WORK_DIR]                                         # another commit
```

Needs git, PHP 8.3 or 8.4 with the extensions in Bagisto's `composer.json`, Composer, and an empty MySQL or MariaDB
database (`DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_DATABASE`; defaults `127.0.0.1`, `3306`, `root`,
empty, `bagisto_stand`). `run.sh` clones the pinned commit, installs the locked dependencies, migrates and seeds,
applies the patch and runs the test file; it refuses a database that already has tables. Where Packagist is not
reachable it fetches the locked packages from their GitHub sources (`../invoiceninja/fetch_vendor.py`). It prints
`REPRODUCED` and exits 0 while the bug is present.

## What is real and what is not

| Part | |
|---|---|
| Bagisto: the `paypal/standard/ipn` route, `StandardController::ipn()`, `Ipn::processIpn()`, the order and cart models, `StandardController::success()` | **real**, on a migrated and seeded database |
| PayPal's IPN postback (`_notify-validate`) | fake: `Http::fake(['*paypal.com/*' => Http::response('VERIFIED')])`, so every IPN is verified |
| The IPN | `txn_type=cart`, `payment_status=Completed`, `invoice` = the cart id, the cart's total and currency, posted twice (PayPal's retry) |
| The buyer | paid at PayPal and never came back to the return URL (`success()` is not called) |

## The finding

With PayPal Standard the order is created only in `StandardController::success()`, the return URL, for the cart id
kept in that browser's session
([StandardController.php#L59-L82](https://github.com/bagisto/bagisto/blob/73e15b7c8e31a9d50a50250efc98a8c9d4e446c8/packages/Webkul/Paypal/src/Http/Controllers/StandardController.php#L59-L82)).
The IPN only updates an existing order: `Ipn::processIpn()` looks it up by `cart_id = invoice`, and `processOrder()`
reads `$this->order->grand_total`
([Ipn.php#L54-L61](https://github.com/bagisto/bagisto/blob/73e15b7c8e31a9d50a50250efc98a8c9d4e446c8/packages/Webkul/Paypal/src/Helpers/Ipn.php#L54-L61),
[#L96-L97](https://github.com/bagisto/bagisto/blob/73e15b7c8e31a9d50a50250efc98a8c9d4e446c8/packages/Webkul/Paypal/src/Helpers/Ipn.php#L96-L97)).
When the buyer doesn't come back there is no order, so the IPN throws `Attempt to read property "grand_total" on null`
and answers 500 every time PayPal resends it.

PayPal: "By default, auto return is disabled", and an IPN that doesn't get a 200 is resent "for up to four days, with a
maximum of 15 retries" (https://developer.paypal.com/api/nvp-soap/ipn/IPNIntro/). The money is at PayPal; the store
has an active cart and no order. #3343 (2020) reported the same thing and was closed as fixed in January 2021.

## Result at 73e15b7 (2.4), run on 2026-10-14

| test | input | HTTP | order |
|---|---|---|---|
| `it should place the order from a verified Completed IPN when the buyer never returned` | the IPN, twice, for a cart whose buyer never returned | **500, 500** | **none**, the cart stays active |
| `it should complete the order from a verified Completed IPN after the buyer returned` (control) | the buyer returned first (`success()` placed the order), then the same IPN | 200 | `processing` |

The first test states the expected behaviour, so it fails while the bug is present; the four existing tests in the
file pass. The IPN code (`StandardController.php`, `Helpers/Ipn.php`, `Payment/Standard.php`) is identical on `2.5`
(e3ba5b0), which needs PHP 8.4. On 2026-10-13 the same tests were run on `master` at 13a8078 (the 2.5 line), with the
same result.
