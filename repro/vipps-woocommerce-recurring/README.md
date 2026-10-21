# Harness: Vipps MobilePay for WooCommerce, a renewal whose charge response is lost is marked failed, then charged by Vipps anyway

A real WordPress site with WooCommerce, [WooCommerce Subscriptions core](https://github.com/Automattic/woocommerce-subscriptions-core)
(GPL) in place of the paid WooCommerce Subscriptions, and the Vipps MobilePay plugin (`woo-vipps`) from git. A renewal order paid with
Vipps MobilePay Recurring goes through the gateway's `scheduled_subscription_payment()` — the hook WooCommerce Subscriptions calls on
the renewal date — and the plugin's own API client talks to a stand-in for the Recurring API. Reported in
[vippsas/vipps-woocommerce#420](https://github.com/vippsas/vipps-woocommerce/issues/420).

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]   # master on 2026-10-20 (6.3.3)
VIPPS_COMMIT=<sha> bash run.sh                                              # another commit
```

Needs PHP 8 with mysqli, [WP-CLI](https://wp-cli.org/), git and an empty MySQL or MariaDB database (`DB_NAME`, default `vipps_stand`).

## What is real and what is not

| Part | |
|---|---|
| WordPress, WooCommerce, WooCommerce Subscriptions core 8.2.0, the plugin's recurring gateway (`scheduled_subscription_payment()`, `process_subscription_payment()`, `check_charge_status()`, `handle_webhook_callback()`) and its API client | **real** |
| WooCommerce Subscriptions | the free core instead of the paid plugin: `stand-wcs.php` defines the empty `WC_Subscriptions_Plugin` class the plugin's loader looks for and an empty retry store (no earlier retries) |
| The renewal order | created by `renew.php` as a renewal order on agreement `agr_STAND1` |
| Vipps Recurring API | `stand-fake-vipps.php` (`pre_http_request`) keeps charges in an option. `create_lost`: the charge is saved as `DUE`, but the response never arrives (cURL timeout); `get_fails`: create answers, every GET of the new charge times out; `ok`: both answer |
| The charge webhook | `recurring.charge-captured.v1` passed to `handle_webhook_callback()` after the stand marks the charge `CHARGED` — what the endpoint does once the request is authenticated |

## The finding

`scheduled_subscription_payment()` catches every exception from `process_subscription_payment()` as "completely unrecoverable" and
sets the renewal order `failed`, including the plugin's own `WC_Vipps_Recurring_Temporary_Exception` (timeouts, 5xx, 429). If that
happens on `POST …/charges` after Vipps has saved the charge, no charge id is stored. Vipps processes the charge on its due date; the
charge webhook looks the order up by charge id, finds none, and returns. If the charge id was stored (the GET after it failed),
`check_charge_status()` returns for `failed` orders without looking at the charge. Either way the customer is charged and the renewal
stays failed; the subscription goes on hold.

## Result

| Case | Renewal order | At Vipps | After the charge is taken and its webhook arrives |
|---|---|---|---|
| 1. response to "create charge" lost | `failed`, no charge id | `DUE` | **`failed`, not paid** — the webhook finds no order |
| 2. control | `processing`, charge id stored | `DUE` | `processing`, paid |
| 3. both GETs of the new charge fail | `failed`, charge id stored; the due charge could not be read, so it is not cancelled | `DUE` | **`failed`, not paid** — `check_charge_status()` skips failed orders |

Run on 2026-10-21 (WordPress 7.1.3, WooCommerce 11.2.1, PHP 8.4, MariaDB 11.4):

```
plugin: 6146a9c 2026-10-20
== 1. create-charge response lost (charge saved at Vipps)
order=11 status=failed charge_id_stored=none last_note="Failed creating a charge: 500 cURL error 28: Operation timed out after 5001 milliseconds with 0 bytes received"
vipps: chr-stand-1 status=DUE due=2026-10-22 amount=19900
calls: POST /accessToken/get -> 200; GET /recurring/v3/agreements/agr_STAND1 -> 200; POST /recurring/v3/agreements/agr_STAND1/charges -> created chr-stand-1 (DUE), response lost: timeout
after Vipps charged chr-stand-1 and sent recurring.charge-captured.v1: order status=failed paid_date=none
== 2. control: create and fetch work
order=13 status=processing charge_id_stored=chr-stand-2 last_note="Email \"New order\" sent."
vipps: chr-stand-2 status=DUE due=2026-10-22 amount=19900
calls: GET /recurring/v3/agreements/agr_STAND1 -> 200; POST /recurring/v3/agreements/agr_STAND1/charges -> 201 chr-stand-2; GET /recurring/v3/agreements/agr_STAND1/charges/chr-stand-2 -> 200
after Vipps charged chr-stand-2 and sent recurring.charge-captured.v1: order status=processing paid_date=set
== 3. fetch of the new charge fails (the plugin then tries to cancel the due charge, but cannot read it either)
order=15 status=failed charge_id_stored=chr-stand-3 last_note="Failed creating a charge: 500 cURL error 28: Operation timed out after 5001 milliseconds with 0 bytes received"
vipps: chr-stand-3 status=DUE due=2026-10-22 amount=19900
calls: GET /recurring/v3/agreements/agr_STAND1 -> 200; POST /recurring/v3/agreements/agr_STAND1/charges -> 201 chr-stand-3; GET /recurring/v3/agreements/agr_STAND1/charges/chr-stand-3 -> timeout; GET /recurring/v3/agreements/agr_STAND1/charges/chr-stand-3 -> timeout
after Vipps charged chr-stand-3 and sent recurring.charge-captured.v1: order status=failed paid_date=none

REPRODUCED: the charge exists at Vipps and is collected on its due date, but the renewal order is failed with no charge id;
the charge webhook finds no order, so the customer pays and the renewal stays failed (the subscription goes on hold).
```
