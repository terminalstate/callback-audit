# Harness: django-oscar-paypal, a PENDING or DECLINED PayPal capture places the order as paid

A test module, `terminal_state_tests.py`, that runs inside django-oscar-paypal's own test suite (its sandbox
settings, django-oscar 4.0, the suite's `SubmitOrderMixin`/`SubmitOrderBase` and recorded fixtures) and fakes only
the HTTP calls to PayPal.

```
./run.sh        # django-oscar-paypal at d2c0171, django-oscar 4.0
```

Needs git and Python 3.10+.

## What is real and what is not

| Part | |
|---|---|
| django-oscar-paypal: `paypal.express_checkout` (REST v2: `gateway.PaymentProcessor`, `facade.capture_order`, `SuccessResponseView.handle_payment`) and `paypal.express` (classic NVP: `gateway`, `facade.confirm_transaction`, `SuccessResponseView.handle_payment`); django-oscar's checkout, order placement, `Source` and `PaymentEvent` | **real**, driven by Django's test client on the suite's sqlite test database |
| PayPal Checkout SDK (`paypalcheckoutsdk`, `paypalhttp`), OAuth token flow | **real** |
| PayPal HTTP (REST v2) | fake: `requests.request` answers by path — `/v1/oauth2/token`, `GET /v2/checkout/orders/{id}` (the suite's recorded order), `POST …/capture` (the suite's recorded capture with its `captures[0].status` replaced) |
| PayPal HTTP (NVP) | fake: `requests.post` answers by NVP method, as in the suite, with `PAYMENTINFO_0_PAYMENTSTATUS`/`PENDINGREASON` replaced |

## The finding

Neither module reads the status of the capture. `facade.capture_order()` stores `Transaction.COMPLETED` as a
constant, `handle_payment()` checks that constant, records a `Source` with `amount_debited` and a `Settled`
payment event, and django-oscar places the order. PayPal's capture status `PENDING` ("the funds … was not yet
credited"), `DECLINED` ("the funds could not be captured") and the NVP `PAYMENTSTATUS=Pending` with
`PENDINGREASON=echeck|paymentreview|…` are treated like `COMPLETED`. The package has no webhook/IPN endpoint,
so a pending capture that later fails is never reflected. The suite's own fixtures were recorded with a
`PENDING` capture (`RECEIVING_PREFERENCE_MANDATES_MANUAL_ACTION`) and `PAYMENTSTATUS=Pending`.

## Result at d2c0171 (2026-10-10, django-oscar 4.0, Django 5.2)

| module | PayPal says | order placed | `amount_debited` | `Settled` event |
|---|---|---|---|---|
| express_checkout | capture `COMPLETED` | yes | 19.99 | yes |
| express_checkout | capture **`PENDING`** / `RECEIVING_PREFERENCE_MANDATES_MANUAL_ACTION` | yes | 19.99 | yes |
| express_checkout | capture **`PENDING`** / `ECHECK` | yes | 19.99 | yes |
| express_checkout | capture **`DECLINED`** | yes | 19.99 | yes |
| express (NVP) | `PAYMENTSTATUS=Completed` | yes | 33.98 | yes |
| express (NVP) | **`PAYMENTSTATUS=Pending`**, `echeck` | yes | 33.98 | yes |
| express (NVP) | **`PAYMENTSTATUS=Pending`**, `paymentreview` | yes | 33.98 | yes |

7 passed, 2 skipped (the "if fixed" expectations, which fail today).
