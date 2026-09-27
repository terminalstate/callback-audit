"""What Odoo's Mollie webhook answers when the payment status can't be fetched from the Mollie API.

Everything below the HTTP request is Odoo's own code: the /payment/mollie/webhook route, the
controller, `_send_api_request` with its error handling, and the transaction update. The only thing
replaced is `requests.request` for URLs on api.mollie.com, which answers the way the scenario asks.
Other HTTP traffic (the test's own request to the Odoo server) goes through untouched.
"""

import json
import logging
from unittest.mock import patch

import requests
from odoo.addons.payment.tests.http_common import PaymentHttpCommon
from odoo.addons.payment_mollie.controllers.main import MollieController
from odoo.addons.payment_mollie.tests.common import MollieCommon
from odoo.tests import tagged

_logger = logging.getLogger(__name__)

PAYMENT_ID = "tr_ABCxyz0123"
REAL_REQUEST = requests.request


def _mollie_response(status, body):
    response = requests.Response()
    response.status_code = status
    response._content = json.dumps(body).encode()
    response.headers["Content-Type"] = "application/hal+json"
    response.url = f"https://api.mollie.com/v2/payments/{PAYMENT_ID}"
    return response


@tagged("post_install", "-at_install", "repro_mollie")
class TestMollieWebhookAck(MollieCommon, PaymentHttpCommon):
    def _answer(self, scenario):
        """The Mollie API's answer to GET /v2/payments/{id}, per scenario."""
        if scenario == "paid":
            return _mollie_response(
                200,
                {
                    "resource": "payment",
                    "id": PAYMENT_ID,
                    "status": "paid",
                    "method": "ideal",
                    "amount": {"value": f"{self.amount:.2f}", "currency": self.currency.name},
                },
            )
        if scenario == "connection error":
            raise requests.exceptions.ConnectionError(
                "HTTPSConnectionPool(host='api.mollie.com', port=443): Max retries exceeded "
                "(Caused by NameResolutionError: Failed to resolve 'api.mollie.com')"
            )
        if scenario == "timeout":
            raise requests.exceptions.ReadTimeout("HTTPSConnectionPool(host='api.mollie.com', port=443): Read timed out. (read timeout=10)")
        if scenario == "503":
            return _mollie_response(
                503,
                {
                    "status": 503,
                    "title": "Service Unavailable",
                    "detail": "The service is temporarily unavailable",
                },
            )
        if scenario == "429":
            return _mollie_response(
                429,
                {
                    "status": 429,
                    "title": "Too Many Requests",
                    "detail": "You have exceeded the rate limit",
                },
            )
        if scenario == "502 HTML page":
            # What a gateway in front of the API may send instead of Mollie's JSON error.
            response = _mollie_response(502, {})
            response._content = b"<html><body><h1>502 Bad Gateway</h1></body></html>"
            response.headers["Content-Type"] = "text/html"
            return response
        if scenario == "404":
            return _mollie_response(
                404,
                {
                    "status": 404,
                    "title": "Not Found",
                    "detail": f"No payment exists with token {PAYMENT_ID}.",
                },
            )
        raise AssertionError(scenario)

    def _fake_api(self, scenario, calls):
        def fake_request(method, url, **kwargs):
            if not str(url).startswith("https://api.mollie.com/"):
                return REAL_REQUEST(method, url, **kwargs)
            calls.append(f"{method} {url}")
            return self._answer(scenario)

        return patch("requests.request", side_effect=fake_request)

    def _deliver_webhook(self, tx, scenario):
        """One webhook delivery as Mollie sends it: `ref` in the URL Odoo gave Mollie, `id` in the body."""
        calls = []
        url = f"{self._build_url(MollieController._webhook_url)}?ref={tx.reference}"
        with self._fake_api(scenario, calls):
            response = self._make_http_post_request(url, data={"id": PAYMENT_ID})
        tx.invalidate_recordset()
        return response, calls

    def test_1_webhook_answer_per_api_answer(self):
        rows = []
        for scenario in ("paid", "connection error", "timeout", "503", "429", "502 HTML page", "404"):
            tx = self._create_transaction("redirect", reference=f"repro-{scenario.replace(' ', '-')}", provider_reference=PAYMENT_ID)
            response, calls = self._deliver_webhook(tx, scenario)
            rows.append((scenario, response.status_code, tx.state, len(calls)))

        _logger.info(
            "REPRO TABLE\n| Mollie API answer | Webhook answered | Transaction afterwards | API calls |\n|---|---|---|---|\n%s",
            "\n".join(f"| {s} | {code} | {state} | {n} |" for s, code, state, n in rows),
        )
        # What Odoo does today (not what it should do): every delivery is acknowledged, except that
        # 18.0 fails on an error page that isn't JSON (500) where 19.0 acknowledges it too.
        gateway = 200 if hasattr(MollieController, "_verify_and_process") else 500
        codes = {s: code for s, code, _st, _n in rows}
        self.assertEqual(codes.pop("502 HTML page"), gateway)
        self.assertEqual(set(codes.values()), {200})
        self.assertEqual(rows[0][2], "done")
        self.assertEqual({state for _s, _c, state, _n in rows[1:]}, {"draft"})

    def test_2_nothing_fetches_the_status_again(self):
        """After an acknowledged failure, the post-processing cron doesn't ask Mollie again, while a
        second delivery (what Mollie would send after a non-2xx answer) would have fixed it."""
        tx = self._create_transaction("redirect", provider_reference=PAYMENT_ID)
        response, _calls = self._deliver_webhook(tx, "503")
        self.assertEqual((response.status_code, tx.state), (200, "draft"))

        cron_calls = []
        # The cron commits after each transaction; tests may not, so the commits become no-ops here.
        with (
            self._fake_api("paid", cron_calls),
            patch.object(self.env.cr, "commit", lambda: None),
            patch.object(self.env.cr, "rollback", lambda: None),
        ):
            self.env["payment.transaction"]._cron_post_process()
        tx.invalidate_recordset()
        after_cron = tx.state

        response, calls = self._deliver_webhook(tx, "paid")
        _logger.info(
            "REPRO RETRY\nafter the acknowledged 503: post-processing cron made %s API calls, "
            "transaction %s; a second delivery with the API healthy: HTTP %s, %s API call(s), "
            "transaction %s",
            len(cron_calls),
            after_cron,
            response.status_code,
            len(calls),
            tx.state,
        )
        self.assertEqual((len(cron_calls), after_cron), (0, "draft"))
        self.assertEqual(tx.state, "done")

    def test_3_webhook_answer_if_the_error_propagated(self):
        """The same deliveries with the fetch error left to Odoo's HTTP layer instead of swallowed,
        as a possible fix would do for the webhook route. Unknown references still get a 200.
        Written against the 19.0 controller (`_verify_and_process`); skipped on older versions."""
        if not hasattr(MollieController, "_verify_and_process"):
            self.skipTest("the controller has no _verify_and_process (Odoo 18.0 and older)")

        def verify_and_process_without_swallowing(data):
            tx_sudo = self.env["payment.transaction"].sudo()._search_by_reference("mollie", data)
            if not tx_sudo:
                return
            verified_data = tx_sudo._send_api_request("GET", f"/payments/{tx_sudo.provider_reference}")
            tx_sudo._process("mollie", verified_data)

        rows = []
        with patch.object(MollieController, "_verify_and_process", staticmethod(verify_and_process_without_swallowing)):
            for scenario in ("paid", "connection error", "timeout", "503", "429", "502 HTML page", "404"):
                tx = self._create_transaction("redirect", reference=f"fix-{scenario.replace(' ', '-')}", provider_reference=PAYMENT_ID)
                response, calls = self._deliver_webhook(tx, scenario)
                rows.append((scenario, response.status_code, tx.state))
            calls = []
            url = f"{self._build_url(MollieController._webhook_url)}?ref=no-such-reference"
            with self._fake_api("paid", calls):
                unknown = self._make_http_post_request(url, data={"id": PAYMENT_ID})
            rows.append(("(unknown reference, no API call)", unknown.status_code, "-"))

        _logger.info(
            "REPRO FIX\n| Mollie API answer | Webhook answered | Transaction afterwards |\n|---|---|---|\n%s",
            "\n".join(f"| {s} | {code} | {state} |" for s, code, state in rows),
        )
        self.assertEqual(rows[0][1:], (200, "done"))
        self.assertTrue(all(code >= 400 for _s, code, _st in rows[1:7]))
        self.assertEqual(rows[7][1], 200)
