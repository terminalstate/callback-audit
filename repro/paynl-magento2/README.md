# Harness: Pay. for Magento 2, an exchange is answered `TRUE` when the status request to Pay. fails

A unit test of the module's real `Controller/Checkout/Exchange` with the real Pay. PHP SDK (1.2.3), without a Magento install:
the module's dependencies come from the [Mage-OS](https://mirror.mage-os.org/) Composer mirror, and `bootstrap.php` is a
minimal stand-in for Magento's unit-test bootstrap (Composer autoload plus generated Factory / ExtensionAttributes classes).
Reported in [paynl/magento2-plugin#248](https://github.com/paynl/magento2-plugin/issues/248), fix in
[#249](https://github.com/paynl/magento2-plugin/pull/249).

```
bash run.sh [WORK_DIR]          # Pay. for Magento 2, master as of 2026-10-20 (4.0.17); PAYNL_COMMIT=… for another commit
```

Needs PHP 8.2+, Composer and git (about 320 MB in `WORK_DIR`).

## What is real and what is not

| Part | |
|---|---|
| `Exchange::execute()`, the SDK's `Exchange::process()` and its HTTP client | **real** |
| The exchange call | an unsigned `action=new_ppt` for a transaction, as Pay. posts it; the order repository, config and result are PHPUnit mocks |
| The Pay. API | not reachable: `HTTPS_PROXY` points to a closed local port, so the status request to `rest.pay.nl` fails to connect |

## The finding

`execute()` turns every exception into a response with `result = $exception->getCode() !== PayExchange::ERROR_ACTION_FAULT`,
so only "API says pending" (8005) is answered `FALSE`. A failed status request is an `API-Retrieval error` with code 0 and is
answered `TRUE|`. Pay. treats an answer that begins with `TRUE` as handled and does not use its retry scheme
(developer.pay.nl/docs/retry-scheme), so the order stays `pending_payment` until Magento cancels it, while the customer paid.
In 3.x the same failure was answered `FALSE| Error fetching transaction.`

## Result

Run on 2026-10-20 (PHP 8.4, PHPUnit 10.5):

```
== exchange controller at e897a31 2026-09-10, SDK 1.2.3
Failed asserting that 'TRUE| Exception message: api retrieval error: 2312345678x1a2b3 - something went wrong' starts with "FALSE".
FAILURES!
Tests: 1, Assertions: 1, Failures: 1.
== with fix.patch
OK (1 test, 1 assertion)
```

`fix.patch` answers `false` from that `catch`.
