# Harness: Paid Memberships Pro PayPal add-on, a PENDING or DECLINED capture inside a COMPLETED order grants the membership

A real WordPress site with Paid Memberships Pro and the PayPal (REST) add-on from git. A buyer checks out through PMPro's checkout
page; the add-on saves the order as `token`, creates a PayPal order and redirects to PayPal. The script then posts PayPal's
`CHECKOUT.ORDER.APPROVED` to the add-on's webhook route, and the add-on captures the order. PayPal answers the capture with a
`COMPLETED` order whose capture is `PENDING`, `DECLINED` or `COMPLETED`. Reported in [strangerstudios/pmpro-paypal#21](https://github.com/strangerstudios/pmpro-paypal/issues/21).

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]
```

Needs PHP 8 with mysqli, [WP-CLI](https://wp-cli.org/), git, curl, network access to GitHub and wordpress.org, and an empty
MySQL or MariaDB database (`DB_NAME`, default `pmpro_paypal_stand`). Pinned: PMPro `dev` 6b567c69 (3.8.9), pmpro-paypal `dev`
29164a9c (1.1.4, the latest on 2026-10-24), WordPress 7.1.3. Takes a few minutes.

## What is real and what is not

| Part | |
|---|---|
| WordPress, PMPro, PMPro's checkout page, the add-on's redirect, webhook route, handlers and "Recheck Payment" | **real** |
| Webhook verification | real: a webhook id is stored, so the add-on verifies every event with PayPal's `verify-webhook-signature` postback; the fake answers `SUCCESS` |
| PayPal | fake: a must-use plugin answers PayPal's REST API (`pre_http_request`): OAuth, create order, get order, capture (201, order `COMPLETED`, capture `PENDING` with `PENDING_REVIEW`, `DECLINED` or `COMPLETED`), webhook registration and the verify postback |

## The finding

After capturing, `pmpro_paypal_handle_checkout_order_approved()` checks only the order status (`COMPLETED`) and completes the
checkout. `captures[0].status` is never read. "Recheck Payment" (`check_token_order()`) has the same check. PayPal: "Check the
payment status in purchase_units[].payments.captures[].status before fulfilling the order." and "A completed order can indicate
a payment was authorized, an authorized payment was captured, or a payment was declined."
([order_status](https://developer.paypal.com/api/orders/v2/definitions/order_status)). The add-on doesn't subscribe to
`PAYMENT.CAPTURE.COMPLETED`, `DENIED` or `DECLINED`, and its router has no case for them.

## Result

| Case | Webhook answer | Order | Membership |
|---|---|---|---|
| capture `PENDING` (`PENDING_REVIEW`) in a `COMPLETED` order | 200 "completed successfully" | **`success`**, 2 checkout e-mails | **granted** |
| then the review is refused: `PAYMENT.CAPTURE.DENIED` | 200 "Unhandled event type" | `success` | **still granted** |
| capture `DECLINED` in a `COMPLETED` order | 200 "completed successfully" | **`success`** | **granted** |
| control: capture `COMPLETED` | 200 "completed successfully" | `success` | granted |
| no webhook, the admin's "Recheck Payment", capture `PENDING` | — | **`success`** | **granted** |
| `fix.patch`, capture `PENDING` | 200 "not paid. Capture status: PENDING" | `token` | none |
| `fix.patch`, then `PAYMENT.CAPTURE.COMPLETED` | 200 "completed successfully" | `success`, 2 e-mails | granted |
| `fix.patch`, the same event again | 200 "has no pending capture" | `success`, no e-mails | granted |
| `fix.patch`, capture `PENDING`, then `PAYMENT.CAPTURE.DENIED` | 200 "not paid. Capture status: DECLINED" | `error` | none |
| `fix.patch`, capture `DECLINED` | 200 "not paid. Capture status: DECLINED" | `error` | none |
| `fix.patch`, capture `COMPLETED` | 200 "completed successfully" | `success`, 2 e-mails | granted |
| `fix.patch`, then PayPal's `PAYMENT.CAPTURE.COMPLETED` for that capture | 200 "has no pending capture" | `success`, no e-mails | granted |
| `fix.patch`, "Recheck Payment" with the capture `PENDING` | — "Payment is not yet completed" | `token` | none |
| `fix.patch`, "Recheck Payment" after the capture completed | — | `success` | granted |
| `fix.patch`, `PAYMENT.CAPTURE.DENIED` for an order completed before the change | 200 "has no pending capture" | unchanged | unchanged |

`fix.patch` is the change proposed in [#22](https://github.com/strangerstudios/pmpro-paypal/pull/22): checkout completes only when `captures[0].status` is `COMPLETED`, in the webhook
and in "Recheck Payment"; a `DECLINED` or `FAILED` capture marks the order `error`; a `PENDING` one keeps it `token` and is
completed (or marked `error`) by `PAYMENT.CAPTURE.COMPLETED` / `DENIED` / `DECLINED`, which the add-on now subscribes to and
routes. Those events act only on a `token` order whose capture was `PENDING` at approval, so the `PAYMENT.CAPTURE.COMPLETED` that
PayPal sends for every ordinary capture does not run checkout a second time. `run.sh` applies it to the stand's copy of the add-on
at the end and reverts it afterwards.

## Files

- `run.sh`: the site, the checkouts, the webhooks and the assertions
- `stand-fake-paypal.php`: must-use plugin, PayPal's REST API and a mail recorder
- `seed.php`: settings, a one-time $10 level, PMPro's pages
- `event.php`: a webhook body as PayPal posts it
- `settle.php`: what happens later at PayPal to a `PENDING` capture (it completes or is declined)
- `recheck.php`: what the admin's "Recheck Payment" runs
- `register.php`: runs the add-on's webhook registration and prints the events it subscribes to
- `check.php`: the order, the membership, the capture at PayPal, whether "Recheck Payment" is offered, the e-mails and API calls of the last request
- `fix.patch`: the proposed change
