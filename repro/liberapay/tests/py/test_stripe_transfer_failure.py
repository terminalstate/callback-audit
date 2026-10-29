"""When `stripe.Transfer.create` fails while the Stripe webhook settles
a charge, the handler records the transfer as `pending` and answers 200, so Stripe
never redelivers the event, and no cron job or page retries the transfer.

Only the Stripe SDK calls are mocked; the webhook signature is computed for real
and checked by `stripe.Webhook.construct_event`, the database is the real one.
Each scenario test asserts the end state that a working retry would reach, and
prints what was observed, so a FAIL shows the current behaviour.
"""

from hashlib import sha256
import hmac
import json
import time
from unittest.mock import patch

import stripe

from liberapay.testing import EUR
from liberapay.testing.emails import EmailHarness
from liberapay.testing.vcr import vcr


WEBHOOK_SECRET = 'whsec_stand_test'
BOB_ACCOUNT = 'acct_standbob'  # NOT the default `acct_1ChyayFk4eGpfLOC`, see below


def sign(payload, secret=WEBHOOK_SECRET, timestamp=None):
    """Compute a `Stripe-Signature` header the way Stripe does."""
    timestamp = int(time.time()) if timestamp is None else timestamp
    mac = hmac.new(secret.encode(), b'%i.' % timestamp + payload, sha256)
    return 't=%i,v1=%s' % (timestamp, mac.hexdigest())


def charge_dict(payin_id, charge_id, amount, captured=True, status='succeeded'):
    return {
        "id": charge_id,
        "object": "charge",
        "amount": amount,
        "amount_captured": amount if captured else 0,
        "amount_refunded": 0,
        "balance_transaction": "txn_stand" if captured else None,
        "captured": captured,
        "currency": "eur",
        "destination": None,
        "failure_code": None,
        "failure_message": None,
        "livemode": False,
        "metadata": {"payin_id": str(payin_id)},
        "paid": status == 'succeeded',
        "payment_intent": None,
        "refunded": False,
        "refunds": {
            "object": "list", "data": [], "has_more": False, "total_count": 0,
            "url": f"/v1/charges/{charge_id}/refunds",
        },
        "status": status,
        "transfer": None,
    }


def charge_event(payin_id, charge_id, amount, event_type='charge.succeeded', **kw):
    return json.dumps({
        "id": "evt_stand_%s_%s" % (event_type.replace('.', '_'), charge_id),
        "object": "event",
        "api_version": "2019-08-14",
        "created": int(time.time()),
        "livemode": False,
        "pending_webhooks": 1,
        "type": event_type,
        "data": {"object": charge_dict(payin_id, charge_id, amount, **kw)},
    }).encode('ascii')


def balance_transaction(amount, fee):
    return stripe.BalanceTransaction.construct_from({
        "id": "txn_stand", "object": "balance_transaction", "amount": amount,
        "currency": "eur", "fee": fee, "net": amount - fee, "status": "pending",
        "type": "payment",
    }, stripe.api_key)


def transfer_ok(pt_id, amount, destination_payment=None):
    return stripe.Transfer.construct_from({
        "id": "tr_standok", "object": "transfer", "amount": amount, "currency": "eur",
        "description": "Liberapay donation", "destination": BOB_ACCOUNT,
        "destination_payment": destination_payment,
        "metadata": {"payin_transfer_id": str(pt_id)}, "reversals": {"data": []},
    }, stripe.api_key)


def capability_error():
    # A Stripe 400 that is not "No such destination": the connected account
    # can't receive transfers right now (e.g. its `transfers` capability became
    # inactive while the SEPA debit was settling). Any `StripeError` that
    # survives stripe-python's retries (connection error, replayed 500, 429)
    # takes the same branch of `execute_transfer`.
    return stripe.InvalidRequestError(
        "Your destination account needs to have at least one of the following "
        "capabilities enabled: transfers, crypto_transfers, legacy_payments",
        param='destination', code='insufficient_capabilities_for_transfer',
        http_status=400,
        json_body={"error": {
            "code": "insufficient_capabilities_for_transfer",
            "message": "Your destination account needs to have at least one of the "
                       "following capabilities enabled: transfers, crypto_transfers, "
                       "legacy_payments",
            "type": "invalid_request_error",
        }},
        headers={"request-id": "req_stand"},
    )


class _StripeWebhookStand(EmailHarness):

    @classmethod
    def setUpVCR(cls):
        # No cassette: every Stripe call is mocked, and record mode "none" turns
        # any unexpected HTTP request into an error instead of a live call.
        cls.vcr_context = vcr.use_cassette(
            f'{cls.__name__}.yml', serializer='custom', record_mode='none',
        )
        cls.vcr_context.__enter__()
        cls.vcr_cassette = cls.vcr_context._CassetteContextDecorator__cassette

    def setUp(self):
        super().setUp()
        self._old_secret = getattr(self.website.app_conf, 'stripe_callback_secret', None)
        self.website.app_conf.stripe_callback_secret = WEBHOOK_SECRET
        self.alice = self.make_participant('alice', email='alice@example.org')
        self.bob = self.make_participant('bob', email='bob@example.org')
        # The test needs a real separate-transfer destination: the default
        # account id of `add_payment_account` is Liberapay's own account, for
        # which `settle_charge_and_transfers` skips `Transfer.create` entirely.
        self.add_payment_account(self.bob, 'stripe', country='FR', id=BOB_ACCOUNT)
        # 20 €/week, paid with 52 € → about 2.6 weeks in advance, i.e. less than
        # the 3 weeks after which a donation is offered for renewal again.
        self.alice.set_tip_to(self.bob, EUR('20.00'), renewal_mode=2)

    def tearDown(self):
        self.website.app_conf.stripe_callback_secret = self._old_secret
        super().tearDown()

    def post_event(self, payload, signature=None):
        return self.client.POST(
            '/callbacks/stripe', body=payload, content_type=b'application/json',
            HTTP_STRIPE_SIGNATURE=signature or sign(payload),
            raise_immediately=False, sentry_reraise=False,
            # the "too late" answer (`response.error(200, …)`) has no Content-Type
            parse_output=False,
        )

    def deliver_like_stripe(self, payload, attempts=5):
        """Stripe redelivers an event (for up to 3 days) until it gets a 2xx."""
        codes = []
        for _ in range(attempts):
            r = self.post_event(payload)
            codes.append(r.code)
            if 200 <= r.code < 300:
                break
        return codes

    def run_payin_cron_jobs(self):
        """Run every periodic job registered in `liberapay/main.py` that deals
        with payments (module `liberapay.payin.*`), the way the cron would."""
        jobs = [
            j.func for j in self.website.cron.jobs
            if getattr(j.func, '__module__', '').startswith('liberapay.payin')
        ]
        names = []
        for func in jobs:
            func()
            names.append(func.__name__)
        return names

    def observe(self, payin_id):
        payin = self.db.one("SELECT * FROM payins WHERE id = %s", (payin_id,))
        pt = self.db.one("SELECT * FROM payin_transfers WHERE payin = %s", (payin_id,))
        tip = self.alice.get_tip_to(self.bob)
        groups = self.alice.get_tips_awaiting_payment()[0]
        offered = any(t.tippee == self.bob.id for g in groups['fundable'] for t in g)
        renewal = self.db.one("""
            SELECT sp.execution_date
              FROM scheduled_payins sp
             WHERE sp.payer = %s
               AND sp.payin IS NULL
               AND %s IN (SELECT (tr->>'tippee_id')::bigint FROM json_array_elements(sp.transfers) tr)
        """, (self.alice.id, self.bob.id))
        return dict(
            payin_status=payin.status,
            transfer_status=pt.status,
            transfer_remote_id=pt.remote_id,
            transfer_error=pt.error,
            paid_in_advance=tip.paid_in_advance,
            donation_offered_for_renewal=offered,
            automatic_renewal_scheduled=renewal is not None,
        )

    def sepa_payin_awaiting_settlement(self):
        """A SEPA payin right after creation: payin and transfer `pending`, no
        transfer id (same state as `test_02_payin_stripe_sdd`), 7 days old."""
        route = self.upsert_route(self.alice, 'stripe-sdd')
        payin, pt = self.make_payin_and_transfer(
            route, self.bob, EUR('52.00'), status='pending', remote_id='py_standsepa',
        )
        assert payin.status == 'pending' and pt.status == 'pending' and pt.remote_id is None
        self.db.run("UPDATE payins SET ctime = ctime - interval '7 days' WHERE id = %s", (payin.id,))
        self.db.run("UPDATE payin_transfers SET ctime = ctime - interval '7 days' WHERE id = %s", (pt.id,))
        return payin, pt


@patch('stripe.Charge.retrieve')
@patch('stripe.BalanceTransaction.retrieve')
@patch('stripe.Transfer.create')
class TestTransferFailureInWebhook(_StripeWebhookStand):

    def test_control_transfer_succeeds_first_time(self, tr_create, bt_retrieve, ch_retrieve):
        """Control: same SEPA settlement, Stripe accepts the transfer."""
        payin, pt = self.sepa_payin_awaiting_settlement()
        bt_retrieve.return_value = balance_transaction(5200, 35)
        tr_create.return_value = transfer_ok(pt.id, 5165)
        ch_retrieve.return_value = stripe.Charge.construct_from(
            charge_dict(payin.id, 'py_standsepa', 5200), stripe.api_key)
        codes = self.deliver_like_stripe(charge_event(payin.id, 'py_standsepa', 5200))
        seen = self.observe(payin.id)
        print("control:", dict(webhook_codes=codes, **seen))
        assert codes == [200]
        assert tr_create.call_count == 1
        assert tr_create.call_args.kwargs['destination'] == BOB_ACCOUNT
        assert tr_create.call_args.kwargs['idempotency_key'] == 'payin_transfer_%i' % pt.id
        assert seen == dict(
            payin_status='succeeded', transfer_status='succeeded',
            transfer_remote_id='tr_standok', transfer_error=None,
            paid_in_advance=EUR('51.65'),
            donation_offered_for_renewal=True,
            automatic_renewal_scheduled=True,
        )

    def test_sepa_transfer_failure_is_retried(self, tr_create, bt_retrieve, ch_retrieve):
        """SEPA: one transient failure of `Transfer.create` while the
        webhook settles the debit. Stripe redelivers only after a non-2xx; then
        every payment-related cron job runs, and the payer opens the payin page.
        A working system ends where the control test ends."""
        payin, pt = self.sepa_payin_awaiting_settlement()
        bt_retrieve.return_value = balance_transaction(5200, 35)
        # The first call fails, every later call succeeds.
        tr_create.side_effect = [capability_error(), transfer_ok(pt.id, 5165)]
        ch_retrieve.return_value = stripe.Charge.construct_from(
            charge_dict(payin.id, 'py_standsepa', 5200), stripe.api_key)

        codes = self.deliver_like_stripe(charge_event(payin.id, 'py_standsepa', 5200))
        after_webhook = self.observe(payin.id)
        cron_jobs = self.run_payin_cron_jobs()
        r = self.client.GET('/alice/giving/pay/stripe/%i' % payin.id, auth_as=self.alice)
        assert r.code == 200, r.text
        r = self.client.GET('/alice/giving/', auth_as=self.alice)
        assert r.code == 200, r.text
        seen = self.observe(payin.id)
        print("SEPA: webhook answers", codes)
        print("  state after the webhook:", after_webhook)
        print("  payment cron jobs run:", cron_jobs)
        print("  Transfer.create calls in total:", tr_create.call_count)
        print("  final state:", seen)

        assert seen == dict(
            payin_status='succeeded', transfer_status='succeeded',
            transfer_remote_id='tr_standok', transfer_error=None,
            paid_in_advance=EUR('51.65'),
            donation_offered_for_renewal=True,
            automatic_renewal_scheduled=True,
        ), "the transfer to the creator was never retried"

    def test_card_transfer_failure_is_retried(self, tr_create, bt_retrieve, ch_retrieve):
        """Card: the synchronous flow captured the charge but
        `Transfer.create` failed (payin `succeeded`, transfer `pending`, no id).
        Stripe then delivers `charge.succeeded`: the authorization snapshot,
        `captured: false`: which the handler answers 200 "too late". Whether a
        `charge.captured` event would also come depends on the endpoint's
        subscription, which isn't visible in the code; this test assumes it
        doesn't."""
        route = self.upsert_route(self.alice, 'stripe-card', address='pm_card_visa')
        payin, pt = self.make_payin_and_transfer(
            route, self.bob, EUR('52.00'), status='succeeded', remote_id='ch_standcard',
            pt_extra=dict(status='pending', remote_id=None,
                          error='(request ID: req_sync)'),
        )
        assert pt.status == 'pending' and pt.remote_id is None
        self.db.run("UPDATE payins SET ctime = ctime - interval '7 days' WHERE id = %s", (payin.id,))
        bt_retrieve.return_value = balance_transaction(5200, 35)
        tr_create.side_effect = [transfer_ok(pt.id, 5165)]  # Stripe is fine again
        ch_retrieve.return_value = stripe.Charge.construct_from(
            charge_dict(payin.id, 'ch_standcard', 5200), stripe.api_key)

        codes = self.deliver_like_stripe(
            charge_event(payin.id, 'ch_standcard', 5200, captured=False))
        cron_jobs = self.run_payin_cron_jobs()
        r = self.client.GET('/alice/giving/pay/stripe/%i' % payin.id, auth_as=self.alice)
        assert r.code == 200, r.text
        seen = self.observe(payin.id)
        print("card: charge.succeeded (uncaptured) answered", codes)
        print("  payment cron jobs run:", cron_jobs)
        print("  Transfer.create calls:", tr_create.call_count)
        print("  final state:", seen)
        assert seen['transfer_status'] == 'succeeded', "the card transfer was never retried"
        assert seen['paid_in_advance'] == EUR('51.65')
