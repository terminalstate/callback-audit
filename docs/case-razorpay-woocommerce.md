# Paid in Razorpay, pending or failed in WooCommerce: what happens to a webhook after the 200

*A third worked case for [callback-audit](https://github.com/terminalstate/callback-audit), done the
same way as the [Stripe](case-woocommerce-stripe-204.md) and [Mollie](case-mollie-woocommerce-200.md)
ones: take a current bug in a widely-installed payment plugin and reproduce it against the plugin's
own code. Everything here is public: no store data and no Razorpay account.*

*The first problem below was reported by jasuuucreates in
[razorpay-woocommerce#664](https://github.com/razorpay/razorpay-woocommerce/issues/664) (August 2026,
plugin 4.8.7). This write-up reproduces it on 4.8.8 with a separate harness and adds what that issue
doesn't cover: what happens when the store's Payment Action is "Authorize", and the 200 the endpoint
sends for deliveries it rejects.*

## TL;DR

**Razorpay for WooCommerce 4.8.8** (100,000+ active installs on WordPress.org) answers a
`payment.authorized` webhook with **200** as soon as it has stored it. A cron job applies it five or
more minutes later. Two things can go wrong after the 200, and Razorpay hears about neither:

1. **The plugin can't fetch the payment from the Razorpay API** (a timeout, a 5xx, a 429). The cron
   marks the event as done anyway. The order stays in *Pending payment*, and nothing tries again:
   not the cron, and not Razorpay, which got its 200 when the webhook arrived.
2. **The store's Payment Action is "Authorize".** The cron marks the order **Failed**, although the
   payment is authorized. When the browser callback brings in the same payment, the order becomes
   *Processing*.

The webhook only matters when the browser callback didn't mark the order paid: the customer closed
the tab after paying, paid in a UPI app and never came back to the browser, or the checkout page
showed an error although the payment went through (as described in
[#631](https://github.com/razorpay/razorpay-woocommerce/issues/631)). Those are exactly the orders
these two problems hit.

The endpoint also answers 200 to deliveries it rejects, for example when the signature doesn't
match. Razorpay counts them as delivered and doesn't retry them, so they never add up to the
"webhook disabled" alert it sends after 24 hours of failures.

## What Razorpay expects

Razorpay's webhook documentation ([best practices](https://razorpay.com/docs/webhooks/best-practices/),
[FAQs](https://razorpay.com/docs/webhooks/faqs/)) says:

- any response other than 2xx is a failed delivery; the endpoint should answer 2xx once it has
  consumed the event;
- a failed delivery is retried with exponential backoff for 24 hours;
- if deliveries keep failing for 24 hours, the webhook is disabled and the account's alert email
  address is notified;
- the endpoint has 5 seconds to answer, and delivery is at least once.

## Two paths to a paid order

Links are to [`d8138d7`](https://github.com/razorpay/razorpay-woocommerce/tree/d8138d762de986b533eb67b8298b2478524d0f39)
on `master` (plugin version 4.8.8).

- **The browser callback.** After checkout, the customer's browser posts the payment id and a
  signature back to the store. A valid signature is enough: the plugin marks the order paid
  ([`woo-razorpay.php#L2079-L2080`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L2079-L2080),
  [`#L2156`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L2156))
  and flags the order's row in the plugin's queue table as handled by the callback
  ([`#L2176-L2186`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L2176-L2186)).
  The row was created with the Razorpay order
  ([`#L1480-L1492`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L1480-L1492)).
- **The webhook.** Razorpay posts `payment.authorized` to `wp-admin/admin-post.php?action=rzp_wc_webhook`
  ([`#L45`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L45),
  [`#L493`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L493)).
  The plugin checks the signature and writes the event into that row
  ([`razorpay-webhook.php#L152-L161`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/includes/razorpay-webhook.php#L152-L161)).
  Nothing sets a status, so WordPress's `admin-post.php` ends the request with 200.
- **The cron.** Every 5 minutes
  ([`woo-razorpay.php#L3339-L3341`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L3339-L3341)),
  `execRzpWooWebhookEvents()` selects the rows whose event is more than 300 seconds old and that
  are still at status 0 ([`#L3393`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L3393)).
  Rows the callback handled are at 1 and are skipped. For each event, the cron calls
  `paymentAuthorized()` and then sets the row to 2
  ([`#L3405-L3421`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L3405-L3421)).

`paymentAuthorized()` fetches the payment from the Razorpay API and decides
([`razorpay-webhook.php#L330-L385`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/includes/razorpay-webhook.php#L330-L385),
shortened):

```php
$payment = $this->getPaymentEntity($razorpayPaymentId, $data);

if ($payment === false)
{
    return;
}

$success      = false;
$errorMessage = 'The payment has failed.';

if ($payment['status'] === 'captured') {
    $success = true;
} else if (($payment['status'] === 'authorized') and
    ($this->razorpay->getSetting('payment_action') === WC_Razorpay::CAPTURE)) {
    // capture the payment; $success = true if that works
}

$this->razorpay->updateOrder($order, $success, $errorMessage, $razorpayPaymentId, null, true);
```

## 1. A failed API call is marked done

`getPaymentEntity()` catches every exception from the SDK, logs it and returns `false`
([`razorpay-webhook.php#L552-L570`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/includes/razorpay-webhook.php#L552-L570)).
`paymentAuthorized()` then returns without touching the order. It returns normally, so the row goes
to status 2. The cron only selects rows at 0, so nobody looks at the event again.

The cron does keep a row for the next run when `paymentAuthorized()` throws: the `catch` leaves it at 0
([`woo-razorpay.php#L3423-L3426`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L3423-L3426)).
A failed API call never throws, so it never gets there. This is item 2 of
[#664](https://github.com/razorpay/razorpay-woocommerce/issues/664), and it is unchanged in 4.8.8.

## 2. With Payment Action "Authorize", an authorized payment becomes a Failed order

The plugin's *Payment Action* setting has two values: "Authorize and Capture", the default, and
"Authorize" ([`woo-razorpay.php#L524-L533`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L524-L533)).
With "Authorize", the plugin creates Razorpay orders with `payment_capture` set to 0
([`#L1572`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L1572)),
so payments stay *authorized* until the merchant captures them in the Razorpay Dashboard. The plugin
never captures them itself.

In `paymentAuthorized()`, an *authorized* payment counts as a success only when the Payment Action
is "Authorize and Capture". With "Authorize", `$success` stays false, and `updateOrder()` marks the
order **Failed**, with the notes "Payment Failed. Please check Razorpay Dashboard." and "Transaction
Failed: The payment has failed."
([`woo-razorpay.php#L2357-L2369`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L2357-L2369)).

So with "Authorize", the order's status depends on which path brought the payment in:

- the browser callback: *Processing*;
- only the webhook: *Failed*.

Unless the merchant follows the note, finds the payment in the Dashboard and captures it by hand,
Razorpay refunds it automatically once the capture timeout runs out: 3 days by default
([capture settings](https://razorpay.com/docs/payments/payments/capture-settings/)). The customer
paid, the order says they didn't, and the money goes back days later.

## 3. The endpoint answers 200 to deliveries it rejects

Every early exit in `process()` returns without setting a status
([`razorpay-webhook.php#L80-L192`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/includes/razorpay-webhook.php#L80-L192)).
Each of these deliveries is answered 200:

- **The signature doesn't match**
  ([`#L126-L148`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/includes/razorpay-webhook.php#L126-L148)).
  The plugin writes an error to its log and sends a `razorpay.webhook.signature.verification.failed`
  event to Razorpay's analytics endpoint. Razorpay's webhook system gets a 200 and records a
  successful delivery.
- **There is no `X-Razorpay-Signature` header**
  ([`#L108`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/includes/razorpay-webhook.php#L108)).
  Nothing is logged.
- **No webhook secret is stored**
  ([`#L115-L124`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/includes/razorpay-webhook.php#L115-L124)).

It also answers 200 when the event wasn't stored. `saveWebhookEvent()` doesn't check what
`$wpdb->update()` returned, and logs "webhook event saved" either way
([`#L214-L226`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/includes/razorpay-webhook.php#L214-L226));
if the order has no row in the table, the event is gone. Two lines earlier it reads a column from
the list of rows that `get_results()` returned
([`#L208-L210`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/includes/razorpay-webhook.php#L208-L210)).
PHP 8 warns `Undefined array key "rzp_webhook_data"` on every `payment.authorized`, and each save
overwrites the events stored for that order before it.

For signatures, the plugin limits the damage on its own. When it creates a Razorpay order and its
last push is more than 12 hours old, `autoEnableWebhook()` pushes the plugin's secret to the webhook
in the merchant's Razorpay account
([`woo-razorpay.php#L1438-L1452`](https://github.com/razorpay/razorpay-woocommerce/blob/d8138d762de986b533eb67b8298b2478524d0f39/woo-razorpay.php#L1438-L1452)),
so a mismatch fixes itself at the next push. Deliveries rejected in the meantime are not coming back.

## Reproduction, against the plugin's own code

The harness is in this repository:
[`repro/razorpay-woocommerce/`](../repro/razorpay-woocommerce/).

- **Real:** the plugin at `d8138d7`, loaded the way WordPress loads a plugin: the webhook handler,
  the cron job, the browser callback, and the bundled Razorpay SDK with its HTTP library, which
  makes real HTTP requests.
- **Stubbed:** WordPress and WooCommerce. The options, one order (#1234, ₹499, *Pending payment*,
  stored the pre-HPOS way) and the plugin's own `wp_rzp_webhook_requests` table live in SQLite, and
  `$wpdb` passes the plugin's SQL to SQLite unchanged. The queue row is seeded with the values the
  plugin inserts when it creates the Razorpay order.
- **Fake:** the Razorpay API, a second local server. The SDK is pointed at it through its own
  `Api::$baseUrl`, and it answers the payment fetch the way the scenario asks.

Each scenario is one signed `payment.authorized` POST to `admin-post.php?action=rzp_wc_webhook`,
then the cron, then the cron once more with the API answering normally. Instead of waiting five
minutes, the harness moves the event's timestamp back 301 seconds; a run with the real five-minute
wait gave the same result.

| Scenario | Webhook answered | Queue row after the cron | Order after the cron | Cron again, API healthy |
|---|---|---|---|---|
| Control: the API answers, payment captured | 200 | event stored, status 2 | processing | processing |
| API timeout (the SDK gives up after 60 s) | **200** | event stored, **status 2** | **pending** | pending, no API call |
| API 503 | **200** | event stored, **status 2** | **pending** | pending, no API call |
| API 429 Too many requests | **200** | event stored, **status 2** | **pending** | pending, no API call |
| Payment Action "Authorize", payment authorized | 200 | event stored, status 2 | **failed** | failed |
| Signature doesn't match the secret | **200** | nothing stored | pending | pending |
| No `X-Razorpay-Signature` header | **200** | nothing stored | pending | pending |

With Payment Action "Authorize", the browser callback for the same authorized payment answered with
a redirect to the order-received page and left the order *Processing*.

The plugin's log (WooCommerce → Status → Logs, source `razorpay-logs`; debug mode is on by
default) shows one error line for a lost event, and nothing after it says the event was dropped:

```
INFO  Woocommerce orderId: 1234, webhook process initiated for payment authorized event by cron
ERROR {"message":"cURL error 28: Operation timed out after 60002 milliseconds with 0 bytes received","payment_id":"pay_RZPHARNESS01","event":"payment.authorized"}
INFO  Webhook cron execution completed.
```

With a 429 the message is `Too many requests`. That is the error a store's log shows in
[#571](https://github.com/razorpay/razorpay-woocommerce/issues/571), on a different API call.

## What would fix it

- **Let `paymentAuthorized()` say whether it finished.** For example, it returns `true` when the
  order was updated or needed nothing, and `false` when the payment couldn't be fetched or captured.
  The cron sets the row to 2 only on `true`. On `false` it leaves the row at 0 for the next run, up
  to a limit (24 hours after the event, say), and then logs an error and stops.
- **With "Authorize", count an authorized payment as a success**, as the browser callback already
  does. If the plugin wants to show that the money isn't captured yet, *On hold* would say so.
- **Answer non-2xx when a delivery is rejected or couldn't be stored.** Razorpay then retries it,
  and if failures continue for 24 hours it disables the webhook and emails the merchant, which is a
  signal where today there is none. `autoEnableWebhook()` already sets the webhook back to active.

## Finding the orders with callback-audit

Both outcomes show only when you put two records side by side: the payment in Razorpay and the
order in WooCommerce.

There is no Razorpay adapter yet, so the Razorpay side goes in through the generic `--events`
format. From a Razorpay payments export, keep three columns: `payment_id`, the WooCommerce order id
(the plugin stores it in each payment's notes as `woocommerce_order_id`); `at`, when the payment was
created; and `status`. The WooCommerce side is the usual orders export
([how to get it](woocommerce-stripe-paid-but-pending.md)).

```
callback-audit --woo-orders orders.csv --gateway razorpay \
               --events razorpay-payments.csv \
               --provider-terminal captured,authorized,failed,refunded \
               --provider-success captured,authorized
```

On three orders in the states the harness left them in (pending after a captured payment, failed
after an authorized one, and one that went through), station 5 reports both problems:

```
SUSPECT: provider success, local terminal failure
provider status -> local status: authorized -> local failed: 1
examples: 1235

SUSPECT: provider terminal, local non-terminal
provider status -> local status: captured -> local pending: 1
examples: 1234
```

Station 7 (age of non-terminal orders) lists the pending ones as well, once they are older than
`--stuck-hours`.
