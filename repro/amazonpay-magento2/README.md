# Harness: Amazon Pay for Magento 2, a declined capture is invoiced as paid

A unit test of the module's real `CheckoutSessionManagement::handlePayment()`, `AmazonPayAdapter` and
`AsyncManagement\Charge` with the real Amazon Pay PHP SDK (2.8.1), without a Magento install: the module's dependencies
come from the [Mage-OS](https://mirror.mage-os.org/) Composer mirror, and `bootstrap.php` is a minimal stand-in for
Magento's unit-test bootstrap (Composer autoload plus generated Factory / ExtensionAttributes classes).
Reported in [amzn/amazon-payments-magento-2-plugin#1304](https://github.com/amzn/amazon-payments-magento-2-plugin/issues/1304).

```
bash run.sh [WORK_DIR]          # Amazon Pay for Magento 2, master as of 2026-10-20 (5.18.6); AMZ_COMMIT=… for another commit
```

Needs PHP 8.2+, Composer and git (about 340 MB in `WORK_DIR`).

## What is real and what is not

| Part | |
|---|---|
| `handlePayment()` (called through reflection, as `completeCheckoutSession()` does), `AmazonPayAdapter`, `Charge::processStateChange()` | **real** |
| Configuration | "Charge when order is placed" (`authorize_capture`) and Authorization Mode "Immediate" (`synchronous`) |
| The Amazon Pay API | the SDK's `ClientInterface` is a stub returning SDK-shaped responses (`['status' => …, 'response' => json]`) |
| Magento side | order, payment and repositories are PHPUnit stubs; `Charge::capture()` (create the invoice and `pay()` it) only records the call |

## The finding

After CompleteCheckoutSession answers 200 (charge `Authorized`), `handlePayment()` calls `captureCharge()` and does not look
at the result; the adapter returns error responses instead of throwing. In "Immediate" mode it then calls
`Charge::capture()`, which invoices the order total and pays the invoice. `getCharge()` returns `Declined`, the `switch`
has no case for it, and checkout reports success. The later CHARGE notification for the declined charge finds the paid
invoice and returns early as "Duplicate IPN received after capture", so nothing corrects the order.

## Result

Run on 2026-10-20 (PHP 8.4, PHPUnit 12.5, magento/framework 103.0.9):

```
== module at 41c44b4 2026-10-08, SDK 2.8.1
1) Amazon\Pay\Test\Unit\Model\DeclinedCaptureTest::testDeclinedCaptureIsNotInvoicedAsPaid
Amazon answered 422 AmazonRejected and the charge is Declined, but the order was invoiced as paid
Tests: 3, Assertions: 5, Failures: 1.
== with fix.patch
OK (3 tests, 7 assertions)
```

The other two tests pass before and after: a successful capture is invoiced, and a Declined notification for a charge
whose invoice is already paid is dropped without fetching the charge. `fix.patch` invoices only after a 200/201 from
CaptureCharge and throws on a `Declined` charge, so the existing `catch` closes the charge permission and cancels the order.
