# Paid in Stripe, still pending in WooCommerce: find those orders

The customer paid and Stripe shows the payment as succeeded. The WooCommerce order still sits in
*Pending payment* or *On hold*. Or it has already been cancelled as unpaid, and the customer got an
email saying so. The Stripe Dashboard shows the webhook as delivered, so neither side looks wrong.

This page is a read-only check that lists those orders. It takes two exports and about ten minutes,
and you don't need to install a plugin or share any credentials. It works with the official
WooCommerce Stripe Payment Gateway plugin, and with any integration that writes the order number
into the payment's metadata.

What you get, on the [example files](../examples/woocommerce-stripe/):

```
| 5 | provider success, local terminal failure | SUSPECT | 1 payment succeeded at the provider but is closed as a failure locally (oldest success 4d 3h ago) |
| 5 | provider terminal, local non-terminal    | SUSPECT | 2 payments are terminal at the provider but non-terminal locally (oldest terminal event 4d 21h ago); 2 of them succeeded at the provider |
| 7 | age of non-terminal payments             | SUSPECT | oldest non-terminal payment is 4d 21h old (id 1003, status pending); 3 older than 24h |
```

## 1. Export the payments from Stripe

In the Stripe Dashboard, open **Transactions**, set the date range, and click **Export**. Choose CSV,
and under **Columns** include **Metadata**.

The metadata matters. The plugin writes `order_id` (the order number) and `site_url` on every
payment, and `order_id` is the only link between a Stripe payment and a WooCommerce order. Column
names such as `metadata:order_id` and `order_id (metadata)` are both recognised.

The check uses the payment id, created date, status, amount, amount refunded and captured columns.
Customer names, emails and card details are not needed, so you can leave them out of the export.

If you work with the API instead, JSON works too: a list of PaymentIntents, Charges or Checkout
Sessions, a bare array, or one page per line.

## 2. Export the orders from WooCommerce

Run one query in your host's database tool (phpMyAdmin, Adminer) and export the result as CSV.
Replace `wp_` with your table prefix and pick a start date that covers the Stripe export.

WooCommerce → Settings → Advanced → Features shows which order storage your store uses.

High-performance order storage (HPOS):

```sql
SELECT id, status, date_created_gmt, payment_method, type
FROM wp_wc_orders
WHERE type = 'shop_order'
  AND date_created_gmt >= '2026-06-01';
```

WordPress posts storage (the older one):

```sql
SELECT p.ID AS id, p.post_status AS status, p.post_date_gmt AS date_created_gmt,
       pm.meta_value AS payment_method
FROM wp_posts p
LEFT JOIN wp_postmeta pm ON pm.post_id = p.ID AND pm.meta_key = '_payment_method'
WHERE p.post_type = 'shop_order'
  AND p.post_date_gmt >= '2026-06-01';
```

The CSV output of WP-CLI's `wp wc shop_order list --format=csv` works as well. You can glue pages
together; repeated header lines are skipped.

Two traps:

- **Don't use a WooCommerce → Analytics export.** By default Analytics leaves out pending, failed and
  cancelled orders, which are the ones you are looking for.
- **Order numbers.** The plugin stores the order *number* in `order_id`. It is the same as the
  order id unless an order-numbering plugin is active. If one is, add the number to the export as a
  `number` column; it takes precedence over `id`.

Only orders paid with a Stripe method (`payment_method` starting with `stripe`) are checked.
`--all-gateways` keeps the rest.

## 3. Run the check

```
pip install git+https://github.com/terminalstate/callback-audit
callback-audit --stripe stripe-payments.csv --woo-orders orders.csv
```

It runs on your computer and reads the two files. It connects to nothing and writes nothing.

Useful additions:

- `--app-log stripe.log` — the plugin's log, saved from WooCommerce → Status → Logs (source
  `woocommerce-gateway-stripe`). Webhooks rejected for a wrong signing secret show up at station 3.
- `--site-url shop.example` — if one Stripe account serves several stores. Order numbers of
  different stores collide, and the report warns when it sees more than one `site_url`.
- `--top 500` — list every affected order instead of the first ten.

To see the output before exporting anything, run the example from a clone of the repository:

```
callback-audit --stripe examples/woocommerce-stripe/stripe_payments.csv \
               --woo-orders examples/woocommerce-stripe/orders.csv \
               --app-log examples/woocommerce-stripe/stripe-plugin.log --now 2026-09-26T12:00:00Z
```

## 4. Read the report

Three lines answer the question:

- **Station 5, "provider success, local terminal failure"** — paid in Stripe, *cancelled or
  failed* in WooCommerce. The customer was charged, and may have been told the order was cancelled.
  Look at these first.
- **Station 5, "provider terminal, local non-terminal"** — paid in Stripe, still *pending or on
  hold*. The summary says how many of them succeeded at Stripe. The rest are Stripe-side cancels and
  failures the order never caught up with.
- **Station 7, "age of non-terminal payments"** — how long orders sit in pending or on hold. This
  includes abandoned checkouts, so read it together with the two lines above.

The notes at the top say what could not be matched: payments without `order_id` (other
integrations, invoices), orders that appear only in the Stripe export (usually a shorter date
range in the orders export), and payments from other stores.

Refunded payments are not reported as lost. Neither are uncaptured authorisations next to an
on-hold order, or a failed attempt followed by a successful one.

## 5. What to do with the list

For each order, open the payment in Stripe and confirm the amount and status. Then:

- **Pending or on hold, paid in Stripe:** move the order to *Processing*; WooCommerce records the
  change in the order notes. Once the cause is fixed, you can also resend the event from the Stripe
  Dashboard so that the plugin processes it the normal way. The Dashboard allows resending for 15
  days.
- **Cancelled or failed, paid in Stripe:** decide per order whether to fulfil it or refund it, and
  tell the customer, who may have received a cancellation email.

Then fix the cause, or next week's orders will join the list.

## Why it happens

- **The webhook secret in the plugin doesn't match the endpoint.** This is common after an endpoint
  was re-created, a secret was rolled, or a site moved from staging. The plugin answers such
  webhooks with HTTP 204, so Stripe marks them delivered and never retries. Signature failures in
  the log plus 204s in Stripe's delivery log point here. Full analysis:
  [case-woocommerce-stripe-204.md](case-woocommerce-stripe-204.md).
- **The webhook arrived, but no order was found for it.** For example, the Adaptive Pricing order
  lookup gave up after one attempt; it was fixed in
  [#5757](https://github.com/woocommerce/woocommerce-gateway-stripe/pull/5757).
- **Unpaid orders are auto-cancelled.** When stock is held for unpaid orders, WooCommerce cancels
  pending orders after the hold time. A late or missing webhook then becomes a cancelled order.
  [#5759](https://github.com/woocommerce/woocommerce-gateway-stripe/pull/5759) proposes asking
  Stripe for the payment status before cancelling.

The report doesn't decide which cause applies. It gives you the orders to trace, and the station
where each one stopped.
