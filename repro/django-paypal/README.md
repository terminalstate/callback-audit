# Harness: django-paypal, an IPN whose receiver failed is never delivered again

A `TestCase` module, `test_repro_terminal_state.py`, that runs with django-paypal's own `runtests.py` and the
suite's own helpers (`IPNUtilsMixin.paypal_post`, the IPN fixture with its `windows-1252` body). Only the
postback to PayPal is faked.

```
./run.sh        # django-paypal at 5d09973
```

Needs git and Python 3.10+.

## What is real and what is not

| Part | |
|---|---|
| django-paypal: the `ipn` view, `PayPalIPNForm`, `PayPalIPN.verify()`, `_verify_postback`, `duplicate_txn_id()`, `send_signals()`, the admin "Re-verify" action | **real**, driven by Django's test client on the suite's sqlite test database |
| PayPal postback (`requests.post` to `ipnpb…/cgi-bin/webscr`) | fake: answers `VERIFIED` |
| The merchant's `valid_ipn_received` receiver | a receiver that raises once (anything fulfilment can fail on) and then works |

## The finding

The view saves the `PayPalIPN` row (inside `verify()` and again before the signals) and only then calls the
receivers. A receiver exception becomes a 500, but the row is already committed, unflagged. PayPal resends the
IPN it did not get a 200 for; the resend has the same `txn_id` and `payment_status`, so `duplicate_txn_id()`
matches the unflagged first row, the resend is flagged "Duplicate txn_id", `invalid_ipn_received` is sent
instead of `valid_ipn_received`, and the view answers 200. PayPal stops; the payment is never processed.
"Re-verify flagged" in the admin runs `verify()` on the resend and flags it again.

With `ATOMIC_REQUESTS = True` (not the default, and not documented by the package) the first row is rolled
back together with the failed request and the resend is processed.

## Result at 5d09973 (2026-10-10)

| delivery | receiver | HTTP | `PayPalIPN` row | signal |
|---|---|---|---|---|
| 1st | raises | 500 | #1 `flag=False` | `valid_ipn_received` (interrupted) |
| 2nd, identical body | works | **200** | #2 `flag=True`, "Duplicate txn_id. (…)" | **`invalid_ipn_received`** |
| admin "Re-verify" on #2 | — | — | #2 `flag=True` again | `invalid_ipn_received` |
| healthy receiver (control) | works | 200 | #1 `flag=False` | `valid_ipn_received` |
| `ATOMIC_REQUESTS=True` (control) | raises, then works | 500, then 200 | #1 rolled back; one row `flag=False` | `valid_ipn_received` twice |

4 tests: 3 ok, 1 skipped (the "if fixed" expectation, which fails today).
