# Harness: django-payments, five ways a payment stops short of its terminal state

A test module, `test_repro_terminal_state.py`, that runs inside django-payments' own test suite (its
`test_settings`, routes and a concrete `BasePayment` subclass) and fakes only the HTTP layer of the provider.

```
./run.sh                       # django-payments at 8edfb1f, latest stripe-python (16.x)
STRIPE_SPEC="stripe<15" ./run.sh   # the same with the last stripe-python that still worked
```

Needs git and Python 3.10+.

## What is real and what is not

| Part | |
|---|---|
| django-payments: `payments.urls` (`process/<token>/`, `process/<variant>/`), `provider_factory`, the five providers, `BasePayment`, `change_status` | **real**, driven by Django's test client on the project's own sqlite test database |
| Stripe signature | **real**: a `whsec` secret, a real `t=…,v1=…` signature computed with `stripe.WebhookSignature._compute_signature`, verified by `stripe.Webhook.construct_event` |
| Stripe HTTP | fake: `stripe.default_http_client` is a stub that records the request and answers canned JSON |
| PayPal (REST v1) HTTP | fake: `requests.post` / `requests.request` answer by URL (OAuth token, `…/execute`) |
| CyberSource SOAP | the real `suds` client builds the envelope from the WSDL/XSD shipped in the package; only `suds.transport.http.HttpTransport.send` is replaced to record the envelope and answer a canned reply |
| Sage Pay (Opayo) Form | nothing faked: the return is a browser redirect; `aes_enc`/`aes_dec` are the module's own |

Tests named `*_current_behaviour` pass on the unmodified code and pin what happens today; `*_control` show
the healthy path next to it; `*_if_fixed` are `xfail(strict=True)` and start failing the run once the bug is
fixed, so the marker can be removed.

## The five findings

1. **stripe-python ≥ 15 breaks `StripeProviderV3`** (`stripe>=7.8.0` has no upper bound). `StripeObject` is no
   longer a `dict` since 15.0.0: `get_form()` fails to store the `Session` in `extra_data` (`TypeError`), and every
   correctly signed webhook crashes at `event.get("type")` → 500. Stripe retries for three days, then gives up.
   The suite never sees it: every webhook test uses `secure_endpoint=False` and `Session.create` is mocked with a dict.
2. **`use_token=False`**: the session is created with `client_reference_id = payment.pk`, but the webhook looks the
   payment up by `token` → 404 on every delivery; paid sessions are never confirmed.
3. **PayPal v1: an executed sale in state `pending`** (eCheck, payment review) is marked `confirmed` with
   `captured_amount = total`; `sale.state` is never read and there is no webhook.
4. **CyberSource "sale"** (`capture=True`, the default) sends `ccCreditService` — a credit *to* the card — without
   `ccAuthService`/`ccCaptureService`; the module's own refund uses the same service.
5. **Sage Pay return route** crashes with `TypeError` on every real redirect (`aes_dec(str)`), the outgoing `Crypt`
   field renders as `b'@…'`; a paid return leaves the payment `waiting`.

## Result at 8edfb1f (2026-10-10)

| test | stripe 16.0.0 | stripe 14.4.1 |
|---|---|---|
| signed `checkout.session.completed`, `secure_endpoint=True` | **`AttributeError` → 500**, payment `waiting` | 200, `confirmed` |
| `get_form()` (Checkout Session creation) | **`TypeError`** | `RedirectNeeded` |
| unsigned delivery, `secure_endpoint=False` | 200, `confirmed` | 200, `confirmed` |
| `use_token=False`, signed delivery with `client_reference_id = <pk>` | **404**, `waiting` | **404**, `waiting` |
| PayPal execute → `sale.state = "pending"` (`ECHECK`) | **302, `confirmed`, `captured_amount` = total** | same |
| PayPal execute → `sale.state = "completed"` | 302, `confirmed` | same |
| CyberSource `charge()` with `capture=True` | request: **`ccCreditService`** + `payerAuthEnrollService`; ACCEPT → `confirmed` | same |
| CyberSource `charge()` with `capture=False` | request: `ccAuthService` + `payerAuthEnrollService` → `preauth` | same |
| Sage Pay `GET …/process/<token>/?crypt=@…` with `Status=OK` | **`TypeError` → 500**, `waiting` | same |

12 passed, 1 skipped, 5 xfailed with stripe 16; 12 passed, 2 skipped, 4 xfailed with stripe 14.
