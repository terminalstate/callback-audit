"""Reproduction: an IPN whose ``valid_ipn_received`` receiver fails is never delivered again
(django-paypal @ 5d09973, ``paypal/standard/ipn``).

Run from the django-paypal checkout with the project's own runner::

    python runtests.py paypal.standard.ipn.tests.test_repro_terminal_state

Only the HTTP postback to PayPal is faked (``requests.post`` in ``paypal.standard.ipn.models`` answers
``VERIFIED``); the view, form, ``verify()``, ``duplicate_txn_id()`` and the signals are the real ones.
"""

from unittest import mock

from django.db import connections
from django.test import TestCase
from django.test.utils import override_settings
from paypal.standard.ipn.models import PayPalIPN
from paypal.standard.ipn.signals import invalid_ipn_received, valid_ipn_received

from .test_ipn import IPN_POST_PARAMS, IPNUtilsMixin


def _verified_postback():
    response = mock.Mock()
    response.status_code = 200
    response.content = b"VERIFIED"
    return mock.patch("paypal.standard.ipn.models.requests.post", return_value=response)


class FulfilmentFailed(RuntimeError):
    """Stands for anything the merchant's receiver can raise: a DB error, a timeout, a bug."""


@override_settings(ROOT_URLCONF="paypal.standard.ipn.tests.test_urls")
class ReceiverFailureTest(IPNUtilsMixin, TestCase):
    """``ipn()`` saves the IPN row, then calls the receivers; a receiver exception becomes a 500 and the
    row stays unflagged. PayPal resends the same message; ``duplicate_txn_id()`` matches the unflagged row,
    flags the resend and ``invalid_ipn_received`` is sent instead — with a 200, so PayPal stops."""

    def setUp(self):
        super().setUp()
        self.valid_calls = []
        self.invalid_calls = []
        self.fail_next = False

        def on_valid(sender, **kwargs):
            self.valid_calls.append(sender)
            if self.fail_next:
                self.fail_next = False
                raise FulfilmentFailed("order creation failed")

        def on_invalid(sender, **kwargs):
            self.invalid_calls.append(sender)

        # keep references so the weak receivers stay alive
        self.on_valid, self.on_invalid = on_valid, on_invalid
        valid_ipn_received.connect(on_valid)
        invalid_ipn_received.connect(on_invalid)

    def test_receiver_exception_then_resend_is_flagged_duplicate_current_behaviour(self):
        self.fail_next = True
        with _verified_postback():
            with self.assertRaises(FulfilmentFailed):  # the test client re-raises the view's exception (500 in prod)
                self.paypal_post(IPN_POST_PARAMS)
        first = PayPalIPN.objects.get()
        self.assertFalse(first.flag)  # the row is committed and looks healthy
        self.assertEqual(len(self.valid_calls), 1)

        # PayPal did not get a 200, so it resends the identical message
        with _verified_postback():
            response = self.paypal_post(IPN_POST_PARAMS)
        self.assertEqual(response.status_code, 200)  # ... and this time it is acknowledged
        second = PayPalIPN.objects.exclude(pk=first.pk).get()
        self.assertTrue(second.flag)
        self.assertEqual(second.flag_info, "Duplicate txn_id. (51403485VH153354B)")
        self.assertEqual(len(self.valid_calls), 1)  # fulfilment never ran successfully
        self.assertEqual(self.invalid_calls, [second])

        # The documented recovery, admin "Re-verify flagged" on the resend, flags it again
        with _verified_postback():
            second.verify()
        self.assertTrue(second.flag)
        self.assertEqual(len(self.valid_calls), 1)

    def test_healthy_receiver_control(self):
        with _verified_postback():
            response = self.paypal_post(IPN_POST_PARAMS)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(self.valid_calls), 1)
        self.assertEqual(self.invalid_calls, [])
        # a genuine duplicate is (correctly) flagged
        with _verified_postback():
            self.paypal_post(IPN_POST_PARAMS)
        self.assertEqual(len(self.valid_calls), 1)
        self.assertEqual(len(self.invalid_calls), 1)

    def test_with_atomic_requests_the_row_is_rolled_back_control(self):
        """With ``ATOMIC_REQUESTS = True`` (not the default, not documented by the package) the first row
        is rolled back together with the failed request and the resend is processed normally."""
        settings_dict = connections["default"].settings_dict
        old = settings_dict.get("ATOMIC_REQUESTS", False)
        settings_dict["ATOMIC_REQUESTS"] = True
        try:
            self.fail_next = True
            with _verified_postback():
                with self.assertRaises(FulfilmentFailed):
                    self.paypal_post(IPN_POST_PARAMS)
            self.assertEqual(PayPalIPN.objects.count(), 0)
            with _verified_postback():
                response = self.paypal_post(IPN_POST_PARAMS)
            self.assertEqual(response.status_code, 200)
            self.assertFalse(PayPalIPN.objects.get().flag)
            self.assertEqual(len(self.valid_calls), 2)
        finally:
            settings_dict["ATOMIC_REQUESTS"] = old

    def test_resend_after_receiver_exception_if_fixed(self):
        """Expected: the resend of a message whose receiver failed is delivered to ``valid_ipn_received``
        again (e.g. the first row is flagged with the receiver error, or saved only after the receivers ran)."""
        self.fail_next = True
        with _verified_postback():
            with self.assertRaises(FulfilmentFailed):
                self.paypal_post(IPN_POST_PARAMS)
        with _verified_postback():
            response = self.paypal_post(IPN_POST_PARAMS)
        self.assertEqual(response.status_code, 200)
        try:
            self.assertEqual(len(self.valid_calls), 2)
            self.assertEqual(self.invalid_calls, [])
        except AssertionError:
            self.skipTest("expected failure on the unmodified code: resend was flagged as a duplicate")
        else:  # pragma: no cover
            self.fail("the resend is delivered again: remove the skipTest wrapper")
