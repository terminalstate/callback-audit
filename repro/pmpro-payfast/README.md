# Harness: Paid Memberships Pro Payfast add-on, an ITN is answered 200 when its validation request to Payfast fails

A real WordPress site with Paid Memberships Pro and the Payfast add-on from git. A buyer checks out through PMPro's checkout
page; the add-on saves the order as `token` and redirects to Payfast. The script then posts the ITN for the completed payment
to the `notify_url` from that redirect, signed the way Payfast signs it, while the add-on's server-to-server validation request
fails.

```
DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=… bash run.sh [WORK_DIR]
```

Needs PHP 8 with mysqli, [WP-CLI](https://wp-cli.org/), git, curl, network access to GitHub and wordpress.org, and an empty
MySQL or MariaDB database (`DB_NAME`, default `pmpro_payfast_stand`). Pinned: PMPro `dev` 6b567c69 (3.8.9), pmpro-payfast `dev`
95a8e43d (1.7.4, the latest on 2026-10-23), WordPress 7.1.3. Takes a few minutes.

## What is real and what is not

| Part | |
|---|---|
| WordPress, PMPro, PMPro's checkout page, the add-on's redirect and ITN handler (signature, source IP, amount, order) | **real** |
| The ITN | built by `itn.php` from the redirect and signed as Payfast documents it (fields in order, urlencoded, `&passphrase=`, md5) |
| The source-IP check | real: the ITN carries `X-Forwarded-For` with an address that `sandbox.payfast.co.za` resolves to (the add-on's proxy path, used when a passphrase is set); without DNS the add-on's debug switch is used and the output says so |
| Payfast | fake: a must-use plugin answers only `POST …/eng/query/validate` (`pre_http_request`): timeout, a 503 page, a 403 page, `INVALID` or `VALID` |

## The finding

`services/payfast_itn_handler.php` sends `header( 'HTTP/1.0 200 OK' ); flush();` before it reads the ITN. When the validation
request then fails, `pmpro_pfValidData()` either `die()`s (a `WP_Error`) or returns `false` for any body other than `VALID` (a
5xx or 403 page), and the handler exits. The status is already 200. Payfast re-sends an ITN only when it gets no 200, so the
only notification of the payment is gone. The add-on does not support `check_token_orders`, so PMPro offers no "Recheck
Payment" for the order, and nothing scheduled looks at `token` orders.

## Result

| Case | ITN answer | Order | Membership |
|---|---|---|---|
| one-time level, validation times out | **200** | `token`, no recheck | none |
| one-time level, validation answers a 503 or 403 page | **200** | `token` | none |
| one-time level, validation `INVALID` | 200 (right: Payfast rejected it) | `token` | none |
| control: validation `VALID` | 200 | `success` | granted |
| the timed-out order after every WP-Cron event has run | — | still `token` | none |
| subscription, first ITN, validation times out | **200** | `token` | none |
| subscription, the renewal ITN a month later | 200 | stays `token`; a new `success` renewal order and invoice e-mail | **none** |
| `fix.patch`, validation times out / 503 / 403 | **503** | `token` | none |
| `fix.patch`, validation `INVALID` | 200 | `token` | none |
| `fix.patch`, the timed-out ITN re-sent with validation `VALID` | 200 | `success` | granted |
| `fix.patch`, the same ITN once more | 200 | `success`, no second checkout and no e-mails | granted |

`fix.patch` is the proposed change: the upfront 200 is removed, `pmpro_pfValidData()` sends 503 for a `WP_Error` and
for any answer that is not Payfast's verdict (not 200, or a body other than `VALID`/`INVALID`), and a one-time `COMPLETE` ITN for
an order that is already `success` is skipped, as the subscription branch already does. `INVALID`, a bad signature and an amount
mismatch still get 200. `run.sh` applies it to the stand's copy of the add-on at the end and reverts it afterwards.

The subscription renewal is simulated by setting `custom_str1` (the checkout date Payfast echoes back) 31 days back on a new
ITN; the handler tells a renewal from a first payment by that field only.

## Files

- `run.sh`: the site, the checkouts, the ITNs and the assertions
- `stand-fake-payfast.php`: must-use plugin, the validation endpoint and a mail recorder
- `seed.php`: settings, a one-time level and a monthly level, PMPro's pages
- `itn.php`: the ITN body from the Payfast redirect, signed
- `check.php`: the order, the membership, the buyer's orders, whether "Recheck Payment" is offered, the e-mails and validation calls of the last ITN
- `fix.patch`: the proposed change
