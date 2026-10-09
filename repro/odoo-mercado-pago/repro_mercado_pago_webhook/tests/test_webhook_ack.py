"""What Odoo's Mercado Pago webhook answers when the payment can't be fetched from the Mercado Pago API.

Everything below the HTTP request is Odoo's own code: the /payment/mercado_pago/webhook/<reference>
route, the controller, `_send_api_request` with its error handling (and, for an expired OAuth
token, the refresh through Odoo's proxy), and the transaction update. The only thing replaced is
`requests.request` for URLs on api.mercadopago.com and on Odoo's Mercado Pago proxy, which answer
the way the scenario asks. Other HTTP traffic (the test's own request to the Odoo server) goes
through untouched.
"""

import json
import logging
from datetime import timedelta
from http import HTTPStatus
from unittest.mock import patch

import requests
from odoo import fields
from odoo.addons.payment.tests.http_common import PaymentHttpCommon
from odoo.addons.payment_mercado_pago import const
from odoo.addons.payment_mercado_pago.controllers.payment import MercadoPagoPaymentController
from odoo.addons.payment_mercado_pago.tests.common import MercadoPagoCommon
from odoo.tests import tagged

_logger = logging.getLogger(__name__)

PAYMENT_ID = "1325678901"
API_URL = "https://api.mercadopago.com/"
REAL_REQUEST = requests.request
SCENARIOS = ("approved", "connection error", "timeout", "500", "503", "429", "502 HTML page", "404")


def _response(status, body, url, content_type="application/json"):
    response = requests.Response()
    response.status_code = status
    response.reason = HTTPStatus(status).phrase
    response._content = body if isinstance(body, bytes) else json.dumps(body).encode()
    response.headers["Content-Type"] = content_type
    response.url = url
    return response


def _api_error(status, message, error, url):
    return _response(status, {"message": message, "error": error, "status": status, "cause": []}, url)


@tagged("post_install", "-at_install", "repro_mercado_pago")
class TestMercadoPagoWebhookAck(MercadoPagoCommon, PaymentHttpCommon):
    def _payment(self, tx, status):
        """GET /v1/payments/{id} for a voucher payment (OXXO) that the customer paid later."""
        return {
            "id": int(PAYMENT_ID),
            "status": status,
            "status_detail": "accredited" if status == "approved" else "pending_waiting_payment",
            "external_reference": tx.reference,
            "payment_type_id": "ticket",
            "payment_method_id": "oxxo",
            "currency_id": tx.currency_id.name,
            "transaction_amount": tx.amount,
            "additional_info": {"items": [{"unit_price": tx.amount}]},
        }

    def _answer(self, tx, scenario, url):
        """The Mercado Pago API's answer to GET /v1/payments/{id}, per scenario."""
        if scenario == "approved":
            return _response(200, self._payment(tx, "approved"), url)
        if scenario == "connection error":
            raise requests.exceptions.ConnectionError(
                "HTTPSConnectionPool(host='api.mercadopago.com', port=443): Max retries exceeded "
                "(Caused by NameResolutionError: Failed to resolve 'api.mercadopago.com')"
            )
        if scenario == "timeout":
            raise requests.exceptions.ReadTimeout(
                "HTTPSConnectionPool(host='api.mercadopago.com', port=443): Read timed out. (read timeout=10)"
            )
        if scenario == "500":
            return _api_error(500, "Internal server error", "internal_error", url)
        if scenario == "503":
            return _api_error(503, "Service unavailable", "service_unavailable", url)
        if scenario == "429":
            return _api_error(429, "Too many requests", "too_many_requests", url)
        if scenario == "502 HTML page":
            # What a gateway in front of the API may send instead of Mercado Pago's JSON error.
            return _response(502, b"<html><body><h1>502 Bad Gateway</h1></body></html>", url, "text/html")
        if scenario == "404":
            return _api_error(404, "Payment not found", "not_found", url)
        raise AssertionError(scenario)

    def _fake_api(self, tx, scenario, calls, proxy=None):
        def fake_request(method, url, **kwargs):
            url = str(url)
            if url.startswith(const.PROXY_URL):
                calls.append(f"{method} {url}")
                if proxy == "connection error":
                    raise requests.exceptions.ConnectionError(
                        "HTTPSConnectionPool(host='mercadopago.api.odoo.com', port=443): Max retries exceeded"
                    )
                if proxy == "503":
                    return _response(503, b"<html><body>Service Unavailable</body></html>", url, "text/html")
                return _response(
                    200,
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "result": {
                            "access_token": "APP_USR-refreshed",
                            "refresh_token": "TG-refreshed",
                            "expires_in": 15552000,
                        },
                    },
                    url,
                )
            if not url.startswith(API_URL):
                return REAL_REQUEST(method, url, **kwargs)
            calls.append(f"{method} {url}")
            return self._answer(tx, scenario, url)

        return patch("requests.request", side_effect=fake_request)

    def _deliver_webhook(self, tx, scenario, proxy=None, reference=None):
        """One notification as Mercado Pago sends it: the reference in the URL Odoo gave Mercado Pago,
        the payment id in the JSON body."""
        calls = []
        url = self._build_url(f"{const.WEBHOOK_ROUTE}/{reference or tx.reference}")
        body = {
            "action": "payment.updated",
            "api_version": "v1",
            "data": {"id": PAYMENT_ID},
            "date_created": "2026-10-09T10:00:00Z",
            "id": 123456789012,
            "live_mode": True,
            "type": "payment",
            "user_id": "1234567",
        }
        with self._fake_api(tx, scenario, calls, proxy=proxy):
            response = self._make_json_request(url, data=body)
        tx.invalidate_recordset()
        return response, calls

    def _pending_tx(self, reference):
        # The customer chose OXXO: the return from checkout already put the transaction in pending.
        return self._create_transaction("redirect", reference=reference, state="pending")

    def test_1_webhook_answer_per_api_answer(self):
        rows = []
        for scenario in SCENARIOS:
            tx = self._pending_tx(f"repro-{scenario.replace(' ', '-')}")
            response, calls = self._deliver_webhook(tx, scenario)
            rows.append((scenario, response.status_code, tx.state, len(calls)))

        _logger.info(
            "REPRO TABLE\n| Mercado Pago API answer | Webhook answered | Transaction afterwards | API calls |\n|---|---|---|---|\n%s",
            "\n".join(f"| {s} | {code} | {state} | {n} |" for s, code, state, n in rows),
        )
        # What Odoo does today (not what it should do): every delivery is acknowledged.
        self.assertEqual({code for _s, code, _st, _n in rows}, {200})
        self.assertEqual(rows[0][2], "done")
        self.assertEqual({state for _s, _c, state, _n in rows[1:]}, {"pending"})

    def test_2_expired_token_and_proxy_down(self):
        """An expired OAuth access token is refreshed through Odoo's proxy inside the same call; when
        the proxy can't be reached, the notification is acknowledged as well."""
        rows = []
        for proxy in ("connection error", "503"):
            self.provider.write(
                {
                    "mercado_pago_access_token_expiry": fields.Datetime.now() - timedelta(days=1),
                    "mercado_pago_refresh_token": "TG-test-refresh-token",
                }
            )
            tx = self._pending_tx(f"repro-proxy-{proxy.replace(' ', '-')}")
            response, calls = self._deliver_webhook(tx, "approved", proxy=proxy)
            rows.append((proxy, response.status_code, tx.state, calls))
        _logger.info(
            "REPRO PROXY\n| Odoo proxy (token refresh) | Webhook answered | Transaction afterwards | Calls |\n|---|---|---|---|\n%s",
            "\n".join(f"| {p} | {code} | {state} | {', '.join(c.split('?')[0] for c in calls)} |" for p, code, state, calls in rows),
        )
        self.assertEqual({code for _p, code, _s, _c in rows}, {200})
        self.assertEqual({state for _p, _c, state, _calls in rows}, {"pending"})

    def test_3_nothing_fetches_the_payment_again(self):
        """After an acknowledged failure, the post-processing cron doesn't ask Mercado Pago again,
        while a second delivery (what Mercado Pago would send after a non-2xx answer) would have
        fixed it."""
        tx = self._pending_tx("repro-retry")
        response, _calls = self._deliver_webhook(tx, "503")
        self.assertEqual((response.status_code, tx.state), (200, "pending"))

        cron_calls = []
        # The cron commits after each transaction; tests may not, so the commits become no-ops here.
        with (
            self._fake_api(tx, "approved", cron_calls),
            patch.object(self.env.cr, "commit", lambda: None),
            patch.object(self.env.cr, "rollback", lambda: None),
        ):
            self.env["payment.transaction"]._cron_post_process()
        tx.invalidate_recordset()
        after_cron = tx.state

        response, calls = self._deliver_webhook(tx, "approved")
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
        self.assertEqual((len(cron_calls), after_cron), (0, "pending"))
        self.assertEqual(tx.state, "done")

    def test_4_webhook_answer_if_the_error_propagated(self):
        """The same deliveries with the fetch error left to Odoo's HTTP layer instead of swallowed,
        as a possible fix would do for the webhook route. Unknown references still get a 200."""

        def verify_and_process_without_swallowing(data):
            tx_sudo = self.env["payment.transaction"].sudo()._search_by_reference("mercado_pago", data)
            if not tx_sudo:
                return
            verified_data = tx_sudo._send_api_request("GET", f"/v1/payments/{data.get('payment_id')}")
            tx_sudo._process("mercado_pago", verified_data)

        rows = []
        with patch.object(MercadoPagoPaymentController, "_verify_and_process", staticmethod(verify_and_process_without_swallowing)):
            for scenario in SCENARIOS:
                tx = self._pending_tx(f"fix-{scenario.replace(' ', '-')}")
                response, _calls = self._deliver_webhook(tx, scenario)
                rows.append((scenario, response.status_code, tx.state))
            tx = self._pending_tx("fix-unknown")
            unknown, _calls = self._deliver_webhook(tx, "approved", reference="no-such-reference")
            rows.append(("(unknown reference, no API call)", unknown.status_code, "-"))

        _logger.info(
            "REPRO FIX\n| Mercado Pago API answer | Webhook answered | Transaction afterwards |\n|---|---|---|\n%s",
            "\n".join(f"| {s} | {code} | {state} |" for s, code, state in rows),
        )
        self.assertEqual(rows[0][1:], (200, "done"))
        self.assertTrue(all(code >= 400 for _s, code, _st in rows[1 : len(SCENARIOS)]))
        self.assertEqual(rows[-1][1], 200)
