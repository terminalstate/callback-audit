"""Reproductions: a PayPal payment that is not final is recorded as settled and the order is placed
(django-oscar-paypal @ d2c0171, modules ``paypal.express_checkout`` (REST v2) and ``paypal.express`` (NVP)).

Run from the django-oscar-paypal checkout with the project's own settings (``pytest.ini``)::

    pytest tests/unit/terminal_state_tests.py -v

Only the HTTP call to PayPal is faked: ``requests.request`` (used by ``paypalhttp``, i.e. by the
PayPal Checkout SDK) answers by URL path, and ``requests.post`` (used by the NVP gateway) answers by
NVP method. The SDK client, OAuth token flow, the package's gateway/facade/views and django-oscar's
checkout are the real ones.
"""

import json
from decimal import Decimal as D
from unittest.mock import patch

import requests
from django.test import TestCase
from oscar.apps.order.models import Order
from paypal.express.models import ExpressTransaction
from paypal.express_checkout.models import ExpressCheckoutTransaction
from tests.unit.express import view_tests as nvp_view_tests
from tests.unit.express_checkout.mocked_data import CAPTURE_ORDER_RESULT_DATA_MINIMAL, GET_ORDER_RESULT_DATA
from tests.unit.express_checkout.views_tests import SubmitOrderMixin

# --------------------------------------------------------------------------------------------
# REST v2 (paypal.express_checkout): the capture's status is never read
# --------------------------------------------------------------------------------------------


def _json_response(payload, status=200):
    response = requests.Response()
    response.status_code = status
    response._content = json.dumps(payload).encode()
    response.headers["Content-Type"] = "application/json"
    response.encoding = "utf-8"
    return response


def _capture_result(status, reason=None):
    """The recorded sandbox capture answer with the capture status replaced."""
    data = json.loads(json.dumps(CAPTURE_ORDER_RESULT_DATA_MINIMAL))
    capture = data["purchase_units"][0]["payments"]["captures"][0]
    capture["status"] = status
    capture.pop("status_details", None)
    if reason:
        capture["status_details"] = {"reason": reason}
    return data


def _fake_paypal_http(capture_payload):
    calls = []

    def fake(method=None, url=None, headers=None, data=None, **kwargs):
        url = url.split("?")[0]  # the SDK appends "?" even without query parameters
        calls.append((method, url))
        if url.endswith("/v1/oauth2/token"):
            return _json_response({"access_token": "A21AA", "token_type": "Bearer", "expires_in": 32400})
        if method == "GET" and "/v2/checkout/orders/" in url:
            return _json_response(GET_ORDER_RESULT_DATA)
        if method == "POST" and url.endswith("/capture"):
            return _json_response(capture_payload, status=201)
        raise AssertionError(f"unexpected PayPal call {method} {url}")  # pragma: no cover

    return fake, calls


class CaptureStatusIgnoredTests(SubmitOrderMixin, TestCase):
    """``capture_order`` stores ``Transaction.COMPLETED`` unconditionally; ``handle_payment`` records
    ``amount_debited`` and a ``Settled`` event; oscar places the order. PayPal's answer said the funds
    are not (or not yet) captured."""

    def _place_order(self, capture_payload):
        fake, calls = _fake_paypal_http(capture_payload)
        with patch("requests.request", side_effect=fake):
            response = self.client.post(self.url, self.payload)
        return response, calls

    def _assert_order_placed_as_paid(self):
        order = Order.objects.get()
        self.assertEqual(order.total_incl_tax, D("19.99"))
        source = order.sources.get()
        self.assertEqual(source.amount_debited, D("19.99"))
        self.assertTrue(order.payment_events.filter(event_type__name="Settled").exists())
        self.txn.refresh_from_db()
        self.assertEqual(self.txn.status, ExpressCheckoutTransaction.COMPLETED)
        self.assertEqual(self.txn.capture_id, "2D6171889X1782919")
        return order

    def test_pending_capture_is_recorded_as_settled_current_behaviour(self):
        """``captures[0].status = PENDING`` (``RECEIVING_PREFERENCE_MANDATES_MANUAL_ACTION``, the status the
        package's own fixture was recorded with) → order placed, source debited, event Settled."""
        response, calls = self._place_order(_capture_result("PENDING", "RECEIVING_PREFERENCE_MANDATES_MANUAL_ACTION"))
        self.assertEqual(response.status_code, 302)
        self.assertIn(("POST", "https://api.sandbox.paypal.com/v2/checkout/orders/4MW805572N795704B/capture"), calls)
        self._assert_order_placed_as_paid()

    def test_pending_echeck_capture_is_recorded_as_settled_current_behaviour(self):
        response, _ = self._place_order(_capture_result("PENDING", "ECHECK"))
        self.assertEqual(response.status_code, 302)
        self._assert_order_placed_as_paid()

    def test_declined_capture_is_recorded_as_settled_current_behaviour(self):
        """Even ``DECLINED`` ("The funds could not be captured") is accepted: the order is placed as paid."""
        response, _ = self._place_order(_capture_result("DECLINED"))
        self.assertEqual(response.status_code, 302)
        self._assert_order_placed_as_paid()

    def test_completed_capture_control(self):
        response, _ = self._place_order(_capture_result("COMPLETED"))
        self.assertEqual(response.status_code, 302)
        self._assert_order_placed_as_paid()

    def test_pending_capture_if_fixed(self):
        """Expected: a capture that is not ``COMPLETED`` must not be recorded as debited/settled (a PENDING
        capture needs a later check or a webhook; DECLINED/FAILED must fail the payment)."""
        self._place_order(_capture_result("PENDING", "ECHECK"))
        order = Order.objects.first()
        settled = order is not None and order.payment_events.filter(event_type__name="Settled").exists()
        if settled:
            self.skipTest("expected failure on the unmodified code: PENDING capture recorded as Settled")
        self.fail("capture status is now checked: remove the skipTest wrapper")  # pragma: no cover


# --------------------------------------------------------------------------------------------
# Classic NVP (paypal.express): PAYMENTINFO_0_PAYMENTSTATUS is never read
# --------------------------------------------------------------------------------------------


def _with_payment_status(do_response, status, pending_reason):
    do_response = do_response.replace("PAYMENTINFO_0_PAYMENTSTATUS=Pending", f"PAYMENTINFO_0_PAYMENTSTATUS={status}")
    return do_response.replace("PAYMENTINFO_0_PENDINGREASON=paymentreview", f"PAYMENTINFO_0_PENDINGREASON={pending_reason}")


class NVPPaymentStatusIgnoredBase(nvp_view_tests.SubmitOrderBase):
    """Same flow as the suite's ``SubmitOrderTests`` (only ``requests.post`` is patched), with the
    ``DoExpressCheckoutPayment`` answer carrying a non-``Completed`` payment status."""

    get_response = nvp_view_tests.SubmitOrderTests.get_response
    status = "Pending"
    pending_reason = "echeck"

    @property
    def do_response(self):
        return _with_payment_status(nvp_view_tests.SubmitOrderTests.do_response, self.status, self.pending_reason)

    def perform_action(self):
        nvp_view_tests.SubmitOrderTests.perform_action(self)

    def assert_order_placed_as_paid(self):
        order = Order.objects.get()
        source = order.sources.get()
        self.assertEqual(source.amount_debited, D("33.98"))  # PAYMENTINFO_0_AMT, the value the view copies
        self.assertTrue(order.payment_events.filter(event_type__name="Settled").exists())
        txn = ExpressTransaction.objects.get(method="DoExpressCheckoutPayment")
        self.assertTrue(txn.is_successful)  # ACK=Success is all the package looks at
        self.assertIn(f"PAYMENTINFO_0_PAYMENTSTATUS={self.status}", txn.raw_response)
        return order


class NVPPendingEcheckTests(NVPPaymentStatusIgnoredBase):
    status, pending_reason = "Pending", "echeck"

    def test_pending_echeck_is_recorded_as_settled_current_behaviour(self):
        self.assert_order_placed_as_paid()


class NVPPendingPaymentReviewTests(NVPPaymentStatusIgnoredBase):
    status, pending_reason = "Pending", "paymentreview"  # the suite's own fixture

    def test_pending_review_is_recorded_as_settled_current_behaviour(self):
        self.assert_order_placed_as_paid()


class NVPCompletedTests(NVPPaymentStatusIgnoredBase):
    status, pending_reason = "Completed", "None"

    def test_completed_control(self):
        self.assert_order_placed_as_paid()


class NVPIfFixedTests(NVPPaymentStatusIgnoredBase):
    status, pending_reason = "Pending", "echeck"

    def test_pending_payment_if_fixed(self):
        order = Order.objects.first()
        settled = order is not None and order.payment_events.filter(event_type__name="Settled").exists()
        if settled:
            self.skipTest("expected failure on the unmodified code: PAYMENTSTATUS=Pending recorded as Settled")
        self.fail("PAYMENTSTATUS is now checked: remove the skipTest wrapper")  # pragma: no cover
