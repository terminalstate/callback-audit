"""Reproductions: payments that stop short of a terminal state (django-payments @ 8edfb1f).

Run from the django-payments checkout with the project's own settings::

    pytest -p no:cacheprovider --no-cov payments/test_repro_terminal_state.py -v

Every test uses the concrete ``payments.test_core.Payment`` model in the test database and the
project's own routes (``payments/process/<token>/`` and ``payments/process/<variant>/``). Only the
HTTP call to the provider is faked:

* Stripe: ``stripe.default_http_client`` is replaced by a stub (signature verification is the real
  ``stripe.Webhook.construct_event`` with a real ``whsec`` secret and a real signature);
* PayPal: ``requests.post`` / ``requests.request`` answer by URL;
* CyberSource: the real ``suds`` client builds the SOAP envelope from the WSDL shipped in the
  package; only ``suds.transport.http.HttpTransport.send`` is replaced;
* Sage Pay: nothing to fake (the return route is a browser redirect; ``aes_enc`` is the module's own).

Tests named ``*_current_behaviour`` pass on the unmodified code and pin what happens today.
Tests named ``*_if_fixed`` are ``xfail(strict=True)``: they fail today and will start passing (and
fail the run, so the marker can be removed) once the bug is fixed.
"""

from __future__ import annotations

import datetime
import json
import re
import time
from decimal import Decimal
from unittest.mock import MagicMock, patch
from urllib.parse import parse_qs

import pytest
from django.test import override_settings
from payments import PaymentStatus, PurchasedItem, RedirectNeeded
from payments.models import BasePayment

pytestmark = pytest.mark.django_db

PAYMENT_MODEL = "payments.ReproPayment"


@pytest.fixture(autouse=True)
def _fresh_provider_cache():
    """``provider_factory`` caches one instance per variant name; tests here change the config."""
    from payments import core

    core.PROVIDER_CACHE.clear()
    yield
    core.PROVIDER_CACHE.clear()


class ReproPayment(BasePayment):
    """Concrete payment model for these tests (the suite's ``test_core.Payment`` has no URLs)."""

    def get_failure_url(self):
        return "https://shop.example.invalid/failure/"

    def get_success_url(self):
        return "https://shop.example.invalid/success/"

    def get_purchased_items(self):
        return [PurchasedItem(name="Ticket", quantity=Decimal(1), price=self.total, currency=self.currency, sku="T-1")]


Payment = ReproPayment


def _payment(variant, **kw):
    kw.setdefault("currency", "USD")
    kw.setdefault("total", Decimal("100.00"))
    kw.setdefault("status", PaymentStatus.WAITING)
    kw.setdefault("billing_first_name", "Jane")
    kw.setdefault("billing_last_name", "Roe")
    kw.setdefault("billing_address_1", "1 Example St")
    kw.setdefault("billing_city", "Springfield")
    kw.setdefault("billing_postcode", "12345")
    kw.setdefault("billing_country_code", "US")
    kw.setdefault("billing_country_area", "CA")
    kw.setdefault("billing_email", "jane@example.invalid")
    kw.setdefault("customer_ip_address", "203.0.113.10")
    p = Payment(variant=variant, **kw)
    p.save()
    return p


# --------------------------------------------------------------------------------------------
# 1. Stripe (StripeProviderV3): use_token=False breaks every webhook delivery
# --------------------------------------------------------------------------------------------

STRIPE_SECRET = "whsec_" + "a" * 32


class _StripeStub:
    """Minimal stripe HTTP client: records requests and answers canned JSON."""

    name = "stub"

    def __init__(self, answer):
        self.answer = answer
        self.calls = []

    def request_with_retries(self, method, url, headers, post_data=None, max_network_retries=None, *, _usage=None):
        self.calls.append((method, url, post_data))
        return json.dumps(self.answer), 200, {}

    def request_stream_with_retries(self, *a, **k):  # pragma: no cover
        raise AssertionError("not used")

    def close(self):
        pass


def _stripe_variants(use_token):
    return {
        "stripe": (
            "payments.stripe.StripeProviderV3",
            {
                "api_key": "sk_test_dummy",
                "use_token": use_token,
                "endpoint_secret": STRIPE_SECRET,
                "secure_endpoint": True,
            },
        )
    }


def _stripe_signed_post(client, event):
    body = json.dumps(event)
    t = int(time.time())
    import stripe

    sig = stripe.WebhookSignature._compute_signature(f"{t}.{body}", STRIPE_SECRET)
    return client.post(
        "/payments/process/stripe/",
        data=body,
        content_type="application/json",
        headers={"STRIPE_SIGNATURE": f"t={t},v1={sig}"},
    )


def _stripe_completed_event(client_reference_id):
    return {
        "id": "evt_1",
        "object": "event",
        "type": "checkout.session.completed",
        "data": {
            "object": {
                "id": "cs_test_1",
                "object": "checkout.session",
                "status": "complete",
                "payment_status": "paid",
                "client_reference_id": client_reference_id,
                "url": None,
            }
        },
    }


@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=_stripe_variants(use_token=False))
def test_stripe_use_token_false_session_carries_pk_current_behaviour():
    """With ``use_token=False`` the Checkout Session is created with ``client_reference_id = pk``."""
    import stripe
    from payments.stripe import StripeProviderV3

    payment = _payment("stripe")
    stub = _StripeStub({"id": "cs_test_1", "object": "checkout.session", "url": "https://checkout.stripe.test/s"})
    stripe.default_http_client = stub
    provider = StripeProviderV3(api_key="sk_test_dummy", use_token=False, endpoint_secret=STRIPE_SECRET)
    # stripe<15: RedirectNeeded; stripe>=15: TypeError while storing the Session in extra_data (see
    # test_stripe_get_form_crashes_with_stripe15_current_behaviour). The request has been sent either way.
    with pytest.raises((RedirectNeeded, TypeError)):
        provider.get_form(payment)
    ((method, url, post_data),) = stub.calls
    assert url.endswith("/v1/checkout/sessions")
    sent = parse_qs(post_data) if isinstance(post_data, str) else post_data
    assert sent["client_reference_id"] == [str(payment.pk)]  # the pk, not the uuid token
    assert payment.token != str(payment.pk)


@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=_stripe_variants(use_token=False))
def test_stripe_use_token_false_webhook_is_404_current_behaviour(client):
    """Stripe sends the session back with ``client_reference_id = "<pk>"``; the static webhook looks the
    payment up by ``token`` and answers 404. Stripe retries 404s for three days, then stops."""
    payment = _payment("stripe", transaction_id="cs_test_1")
    event = _stripe_completed_event(str(payment.pk))
    response = _stripe_signed_post(client, event)
    assert response.status_code == 404
    assert response.json() == {"error": "Payment not found", "variant": "stripe"}
    payment.refresh_from_db()
    assert payment.status == PaymentStatus.WAITING
    assert payment.captured_amount == 0


def _stripe_major():
    import stripe

    return int(stripe.VERSION.split(".")[0])


@pytest.mark.skipif(_stripe_major() >= 15, reason="stripe>=15: see test_stripe_signed_webhook_crashes_with_stripe15")
@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=_stripe_variants(use_token=True))
def test_stripe_use_token_true_webhook_confirms_control(client):
    """Control (stripe<15): the same delivery with the default ``use_token=True`` is found and confirmed."""
    payment = _payment("stripe", transaction_id="cs_test_1")
    event = _stripe_completed_event(payment.token)
    response = _stripe_signed_post(client, event)
    assert response.status_code == 200
    payment.refresh_from_db()
    assert payment.status == PaymentStatus.CONFIRMED
    assert payment.captured_amount == payment.total


@pytest.mark.skipif(_stripe_major() < 15, reason="only stripe>=15 removed the dict methods")
@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=_stripe_variants(use_token=True))
def test_stripe_signed_webhook_crashes_with_stripe15_current_behaviour(client):
    """With the default ``secure_endpoint=True`` and stripe-python >= 15 (``StripeObject`` is no longer a
    ``dict``), a correctly signed ``checkout.session.completed`` crashes in ``process_data`` at
    ``event.get("type")`` → 500 on every delivery; the paid session is never confirmed."""
    payment = _payment("stripe", transaction_id="cs_test_1")
    event = _stripe_completed_event(payment.token)
    with pytest.raises(AttributeError, match="not a dict"):
        _stripe_signed_post(client, event)
    payment.refresh_from_db()
    assert payment.status == PaymentStatus.WAITING
    assert payment.captured_amount == 0


@pytest.mark.skipif(_stripe_major() < 15, reason="only stripe>=15 removed dict inheritance")
@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=_stripe_variants(use_token=True))
def test_stripe_get_form_crashes_with_stripe15_current_behaviour():
    """The outgoing side breaks too: ``get_form`` stores the ``Session`` object in ``extra_data`` with
    ``json.dumps`` → ``TypeError`` under stripe-python >= 15 (the suite mocks ``Session.create`` with a dict)."""
    import stripe
    from payments.stripe import StripeProviderV3

    payment = _payment("stripe")
    stripe.default_http_client = _StripeStub({"id": "cs_test_1", "object": "checkout.session", "url": "https://checkout.stripe.test/s"})
    provider = StripeProviderV3(api_key="sk_test_dummy", use_token=True, endpoint_secret=STRIPE_SECRET)
    with pytest.raises(TypeError, match="not JSON serializable"):
        provider.get_form(payment)


@override_settings(
    PAYMENT_MODEL=PAYMENT_MODEL,
    PAYMENT_VARIANTS={"stripe": ("payments.stripe.StripeProviderV3", {"api_key": "sk_test_dummy", "secure_endpoint": False})},
)
def test_stripe_unsigned_webhook_confirms_control(client):
    """Control: with ``secure_endpoint=False`` (the documented *development* setting) the body is parsed with
    ``json.loads`` and the same delivery is confirmed — which is why the suite never sees the crash."""
    payment = _payment("stripe", transaction_id="cs_test_1")
    event = _stripe_completed_event(payment.token)
    response = client.post("/payments/process/stripe/", data=json.dumps(event), content_type="application/json")
    assert response.status_code == 200
    payment.refresh_from_db()
    assert payment.status == PaymentStatus.CONFIRMED
    assert payment.captured_amount == payment.total


@pytest.mark.xfail(_stripe_major() >= 15, strict=True, reason="process_data must not use dict methods on a StripeObject")
@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=_stripe_variants(use_token=True))
def test_stripe_signed_webhook_if_fixed(client):
    payment = _payment("stripe", transaction_id="cs_test_1")
    response = _stripe_signed_post(client, _stripe_completed_event(payment.token))
    assert response.status_code == 200
    payment.refresh_from_db()
    assert payment.status == PaymentStatus.CONFIRMED


@pytest.mark.xfail(strict=True, reason="webhook lookup ignores use_token=False")
@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=_stripe_variants(use_token=False))
def test_stripe_use_token_false_webhook_if_fixed(client):
    payment = _payment("stripe", transaction_id="cs_test_1")
    response = _stripe_signed_post(client, _stripe_completed_event(str(payment.pk)))
    assert response.status_code == 200
    payment.refresh_from_db()
    assert payment.status == PaymentStatus.CONFIRMED


# --------------------------------------------------------------------------------------------
# 2. PayPal (REST v1 PaypalProvider): an executed sale in state "pending" is marked CONFIRMED
# --------------------------------------------------------------------------------------------

PAYPAL_VARIANTS = {
    "paypal": (
        "payments.paypal.PaypalProvider",
        {"client_id": "cid", "secret": "sec", "endpoint": "https://api.sandbox.paypal.test"},
    )
}


def _paypal_fake_http(sale_state, reason_code=None):
    sale = {
        "id": "SALE-1",
        "state": sale_state,
        "amount": {"total": "100.00", "currency": "USD"},
        "links": [{"rel": "refund", "href": "https://api.sandbox.paypal.test/v1/payments/sale/SALE-1/refund", "method": "POST"}],
    }
    if reason_code:
        sale["reason_code"] = reason_code
    executed = {
        "id": "PAY-1",
        "state": "approved",
        "payer": {"payment_method": "paypal", "payer_info": {"email": "buyer@example.invalid"}},
        "transactions": [{"amount": {"total": "100.00", "currency": "USD"}, "related_resources": [{"sale": sale}]}],
        "links": [],
    }
    token = {"token_type": "Bearer", "access_token": "A21AA", "expires_in": 32400}

    def fake(method_or_url, *args, **kwargs):
        url = method_or_url if method_or_url.startswith("http") else args[0]
        resp = MagicMock()
        resp.status_code = 200
        if url.endswith("/v1/oauth2/token"):
            resp.json.return_value = token
        elif url.endswith("/execute"):
            resp.json.return_value = executed
        else:  # pragma: no cover
            raise AssertionError(f"unexpected call {url}")
        return resp

    return fake


def _paypal_payment():
    links = {
        "approval_url": {"href": "https://www.sandbox.paypal.test/checkout?token=EC-1", "rel": "approval_url"},
        "execute": {"href": "https://api.sandbox.paypal.test/v1/payments/payment/PAY-1/execute", "rel": "execute"},
    }
    return _payment("paypal", transaction_id="PAY-1", extra_data=json.dumps({"links": links}))


@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=PAYPAL_VARIANTS)
def test_paypal_pending_sale_marked_confirmed_current_behaviour(client):
    """PayPal executes the payment but the sale is ``pending`` (eCheck): the provider confirms anyway."""
    payment = _paypal_payment()
    fake = _paypal_fake_http("pending", reason_code="ECHECK")
    with patch("requests.post", side_effect=fake), patch("requests.request", side_effect=fake):
        response = client.get(f"/payments/process/{payment.token}/", {"token": "EC-1", "PayerID": "PAYER1"})
    assert response.status_code == 302
    assert response["Location"] == payment.get_success_url()
    payment.refresh_from_db()
    assert payment.status == PaymentStatus.CONFIRMED
    assert payment.captured_amount == payment.total
    assert json.loads(payment.extra_data)["response"]["transactions"][0]["related_resources"][0]["sale"]["state"] == "pending"


@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=PAYPAL_VARIANTS)
def test_paypal_completed_sale_marked_confirmed_control(client):
    payment = _paypal_payment()
    fake = _paypal_fake_http("completed")
    with patch("requests.post", side_effect=fake), patch("requests.request", side_effect=fake):
        response = client.get(f"/payments/process/{payment.token}/", {"token": "EC-1", "PayerID": "PAYER1"})
    assert response.status_code == 302
    payment.refresh_from_db()
    assert payment.status == PaymentStatus.CONFIRMED


@pytest.mark.xfail(strict=True, reason="sale.state is never read")
@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=PAYPAL_VARIANTS)
def test_paypal_pending_sale_if_fixed(client):
    payment = _paypal_payment()
    fake = _paypal_fake_http("pending", reason_code="ECHECK")
    with patch("requests.post", side_effect=fake), patch("requests.request", side_effect=fake):
        client.get(f"/payments/process/{payment.token}/", {"token": "EC-1", "PayerID": "PAYER1"})
    payment.refresh_from_db()
    assert payment.status != PaymentStatus.CONFIRMED
    assert payment.captured_amount == 0


# --------------------------------------------------------------------------------------------
# 3. CyberSource (SOAP): a "sale" (capture=True, the default) requests ccCreditService
# --------------------------------------------------------------------------------------------

CARD = {"name": "Jane Roe", "number": "4111111111111111", "expiration_0": "1", "expiration_1": "2031", "cvv2": "123"}
CARD_CLEANED = {"name": "Jane Roe", "number": "4111111111111111", "expiration": datetime.date(2031, 1, 1), "cvv2": "123"}


class _SoapCapture:
    """Replaces suds' HTTP transport: records the envelope and answers a canned reply."""

    def __init__(self, reply_xml=None):
        self.reply_xml = reply_xml
        self.bodies = []

    def __call__(self, transport, request):
        self.bodies.append(request.message)
        if self.reply_xml is None:
            raise RuntimeError("no network")
        from suds.transport import Reply

        return Reply(200, {}, self.reply_xml)


def _cybs_reply(request_id="7000000000000000001", reason_code=100, service="ccCreditReply"):
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">'
        '<soap:Body><c:replyMessage xmlns:c="urn:schemas-cybersource-com:transaction-data-1.101">'
        f"<c:merchantReferenceCode>1</c:merchantReferenceCode><c:requestID>{request_id}</c:requestID>"
        f"<c:decision>ACCEPT</c:decision><c:reasonCode>{reason_code}</c:reasonCode>"
        "<c:requestToken>tok</c:requestToken><c:purchaseTotals><c:currency>USD</c:currency></c:purchaseTotals>"
        f"<c:{service}><c:reasonCode>{reason_code}</c:reasonCode><c:amount>100.00</c:amount></c:{service}>"
        "</c:replyMessage></soap:Body></soap:Envelope>"
    ).encode()


def _services(body):
    # suds picks the namespace prefix (ns0/ns1/...) per run, so match any prefix
    return sorted(set(m.decode() for m in re.findall(rb"<(?:\w+:)?(\w+Service)\b", body)))


def _cybs_provider(capture=True):
    from payments.cybersource import CyberSourceProvider

    return CyberSourceProvider(merchant_id="merchant", password="pw", org_id=None, sandbox=True, capture=capture)


def test_cybersource_sale_requests_credit_service_current_behaviour():
    """``charge()`` with the default ``capture=True`` sends ``ccCreditService`` (money *to* the card),
    no ``ccAuthService``/``ccCaptureService``; an ACCEPT reply is recorded as a CONFIRMED sale."""
    cap = _SoapCapture(_cybs_reply())
    with patch("suds.transport.http.HttpTransport.send", new=cap):
        provider = _cybs_provider(capture=True)
        payment = _payment("cybersource")
        payment.attrs.fingerprint_session_id = "fp"
        payment.attrs.merchant_defined_data = {}
        with pytest.raises(RedirectNeeded):
            provider.get_form(payment, data=CARD)
    assert _services(cap.bodies[0]) == ["ccCreditService", "payerAuthEnrollService"]
    assert b"ccAuthService" not in cap.bodies[0] and b"ccCaptureService" not in cap.bodies[0]
    assert b"captureRequestID" not in cap.bodies[0]  # a stand-alone credit, not a follow-on
    assert payment.status == PaymentStatus.CONFIRMED
    assert payment.captured_amount == payment.total


def test_cybersource_preauth_requests_auth_service_control():
    cap = _SoapCapture(_cybs_reply(service="ccAuthReply"))
    with patch("suds.transport.http.HttpTransport.send", new=cap):
        provider = _cybs_provider(capture=False)
        payment = _payment("cybersource")
        payment.attrs.fingerprint_session_id = "fp"
        payment.attrs.merchant_defined_data = {}
        with pytest.raises(RedirectNeeded):
            provider.get_form(payment, data=CARD)
    assert _services(cap.bodies[0]) == ["ccAuthService", "payerAuthEnrollService"]
    assert payment.status == PaymentStatus.PREAUTH


def test_cybersource_refund_uses_the_same_credit_service_control():
    """The module's own refund path uses ``ccCreditService`` + ``captureRequestID`` — the same service
    the "sale" sends without a reference."""
    cap = _SoapCapture(_cybs_reply())
    with patch("suds.transport.http.HttpTransport.send", new=cap):
        provider = _cybs_provider(capture=True)
        payment = _payment(
            "cybersource", status=PaymentStatus.CONFIRMED, transaction_id="7000000000000000001", captured_amount=Decimal("100.00")
        )
        payment.attrs.merchant_defined_data = {}
        provider.refund(payment, Decimal("100.00"))
    assert _services(cap.bodies[0]) == ["ccCreditService"]
    assert re.search(rb"<(\w+:)?captureRequestID>7000000000000000001</(\w+:)?captureRequestID>", cap.bodies[0])


@pytest.mark.xfail(strict=True, reason="sale should be ccAuthService + ccCaptureService")
def test_cybersource_sale_if_fixed():
    cap = _SoapCapture()
    with patch("suds.transport.http.HttpTransport.send", new=cap):
        provider = _cybs_provider(capture=True)
        payment = _payment("cybersource")
        payment.attrs.fingerprint_session_id = "fp"
        payment.attrs.merchant_defined_data = {}
        with pytest.raises(RuntimeError):
            provider.charge(payment, CARD_CLEANED)
    assert "ccCreditService" not in _services(cap.bodies[0])
    assert {"ccAuthService", "ccCaptureService"} <= set(_services(cap.bodies[0]))


# --------------------------------------------------------------------------------------------
# 4. Sage Pay (Form protocol): the return route crashes on every real request
# --------------------------------------------------------------------------------------------

SAGEPAY_VARIANTS = {"sagepay": ("payments.sagepay.SagepayProvider", {"vendor": "vendor", "encryption_key": "1234abcd1234abcd"})}


def _sagepay_crypt(provider, payment, status="OK"):
    fields = {
        "VendorTxCode": str(payment.pk),
        "VPSTxId": "{11111111-2222-3333-4444-555555555555}",
        "Status": status,
        "StatusDetail": "0000 : The Authorisation was Successful.",
        "TxAuthNo": "1234567",
        "Amount": f"{payment.total:.2f}",
        "AVSCV2": "ALL MATCH",
        "AddressResult": "MATCHED",
        "PostCodeResult": "MATCHED",
        "CV2Result": "MATCHED",
        "GiftAid": "0",
        "3DSecureStatus": "OK",
        "CAVV": "AAABBBCCCDDD",
    }
    return provider.aes_enc("&".join(f"{k}={v}" for k, v in fields.items()))


@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=SAGEPAY_VARIANTS)
def test_sagepay_return_crashes_on_str_crypt_current_behaviour(client):
    """Opayo redirects the browser to ``SuccessURL?crypt=@…``. ``request.GET["crypt"]`` is a ``str``;
    ``aes_dec`` calls ``str.lstrip(b"@")`` → ``TypeError`` → 500. The payment stays WAITING."""
    from payments.sagepay import SagepayProvider

    provider = SagepayProvider(vendor="vendor", encryption_key="1234abcd1234abcd")
    payment = _payment("sagepay")
    crypt = _sagepay_crypt(provider, payment)
    assert provider.aes_dec(crypt).startswith("VendorTxCode=")  # bytes in → works (what the suite tests)
    with pytest.raises(TypeError, match="lstrip"):
        client.get(f"/payments/process/{payment.token}/", {"crypt": crypt.decode()})
    payment.refresh_from_db()
    assert payment.status == PaymentStatus.WAITING
    assert payment.captured_amount == 0


@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=SAGEPAY_VARIANTS)
def test_sagepay_outgoing_crypt_is_rendered_as_bytes_repr_current_behaviour():
    """The hidden ``Crypt`` field is the ``bytes`` returned by ``aes_enc``; the form renders ``b'@…'``."""
    from payments.sagepay import SagepayProvider

    provider = SagepayProvider(vendor="vendor", encryption_key="1234abcd1234abcd")
    payment = _payment("sagepay")
    html = str(provider.get_form(payment))
    assert 'name="Crypt"' in html
    assert 'value="b&#x27;@' in html or "value='b'@" in html


@pytest.mark.xfail(strict=True, reason="aes_dec must accept the str Django gives it")
@override_settings(PAYMENT_MODEL=PAYMENT_MODEL, PAYMENT_VARIANTS=SAGEPAY_VARIANTS)
def test_sagepay_return_if_fixed(client):
    from payments.sagepay import SagepayProvider

    provider = SagepayProvider(vendor="vendor", encryption_key="1234abcd1234abcd")
    payment = _payment("sagepay")
    response = client.get(f"/payments/process/{payment.token}/", {"crypt": _sagepay_crypt(provider, payment).decode()})
    assert response.status_code == 302
    payment.refresh_from_db()
    assert payment.status == PaymentStatus.CONFIRMED
