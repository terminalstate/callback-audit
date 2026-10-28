/**
 * Reproduction: editing a recurring contribution (amount, tier or platform tip) while its delayed charge
 * (SEPA Direct Debit, ACH, Bacs…) is PROCESSING drops the stored PaymentIntent reference
 * (server/lib/subscriptions.ts updateSubscriptionDetails). When Stripe later sends payment_intent.succeeded,
 * the webhook finds no order for that PaymentIntent and answers 200, so the payment is never recorded,
 * the order stays PROCESSING and Stripe does not resend the event.
 *
 * The edit goes through the real `updateOrder` mutation as the contributor (the website offers
 * "Update contribution amount" for PROCESSING contributions). The event is POSTed to /webhooks/stripe with
 * a real Stripe signature (config.stripe.webhookSigningSecret); only Stripe's HTTP API is faked (nock).
 */
import { expect } from 'chai';
import config from 'config';
import gql from 'fake-tag';
import nock from 'nock';
import request from 'supertest';

import OrderStatuses from '../../../../server/constants/order-status';
import { PAYMENT_METHOD_SERVICE, PAYMENT_METHOD_TYPE } from '../../../../server/constants/paymentMethods';
import PlatformConstants from '../../../../server/constants/platform';
import { idEncode } from '../../../../server/graphql/v2/identifiers';
import stripe from '../../../../server/lib/stripe';
import models from '../../../../server/models';
import app from '../../../../server/index';
import {
  fakeCollective,
  fakeConnectedAccount,
  fakeHost,
  fakeOrder,
  fakePaymentMethod,
  fakeUser,
  randStr,
} from '../../../test-helpers/fake-data';
import { graphqlQueryV2, resetTestDB } from '../../../utils';

const updateOrderMutation = gql`
  mutation UpdateOrder($order: OrderReferenceInput!, $amount: AmountInput) {
    updateOrder(order: $order, amount: $amount) {
      id
      status
    }
  }
`;

describe('stripe webhook: contribution edited while its delayed charge is PROCESSING', () => {
  let expressApp, user, collective;

  before(async () => {
    await resetTestDB();
    await fakeHost({ id: PlatformConstants.PlatformCollectiveId, slug: randStr('platform-') });
    user = await fakeUser();
    collective = await fakeCollective({ currency: 'USD' });
    await fakeConnectedAccount({ service: 'stripe', username: 'host_stripe_account', CollectiveId: collective.host.id });
    expressApp = await app();
  });

  afterEach(() => {
    nock.cleanAll();
  });

  /** A monthly SEPA contribution whose current charge was confirmed and is still processing at Stripe. */
  const createOrderWithChargeInFlight = async () => {
    const piId = randStr('pi_inflight_');
    const pmId = randStr('pm_sepa_');
    const paymentMethod = await fakePaymentMethod({
      service: PAYMENT_METHOD_SERVICE.STRIPE,
      type: PAYMENT_METHOD_TYPE.SEPA_DEBIT,
      CollectiveId: user.CollectiveId,
      CreatedByUserId: user.id,
      data: { stripePaymentMethodId: pmId, stripeAccount: config.stripe.accountId },
    });
    const order = await fakeOrder(
      {
        CreatedByUserId: user.id,
        FromCollectiveId: user.CollectiveId,
        CollectiveId: collective.id,
        PaymentMethodId: paymentMethod.id,
        status: OrderStatuses.PROCESSING,
        totalAmount: 1000,
        currency: 'USD',
        data: { stripePaymentIntent: { id: piId, status: 'processing' } },
      },
      { withSubscription: true },
    );
    return { order, piId, pmId };
  };

  /** Stripe settles the debit: payment_intent.succeeded, signed the way Stripe signs it. */
  const deliverPaymentIntentSucceeded = async ({ piId, pmId, amount = 1000 }) => {
    const chargeId = randStr('ch_sepa_');
    const balanceTransactionId = randStr('txn_sepa_');
    const event = {
      id: randStr('evt_'),
      object: 'event',
      type: 'payment_intent.succeeded',
      livemode: false,
      created: Math.floor(Date.now() / 1000),
      data: {
        object: {
          id: piId,
          object: 'payment_intent',
          amount,
          currency: 'usd',
          status: 'succeeded',
          payment_method: pmId,
          latest_charge: {
            id: chargeId,
            object: 'charge',
            amount,
            amount_captured: amount,
            amount_refunded: 0,
            currency: 'usd',
            status: 'succeeded',
            paid: true,
            payment_intent: piId,
            payment_method: pmId,
            balance_transaction: balanceTransactionId,
            application_fee_amount: null,
          },
        },
      },
    };
    // Only reached when the webhook finds the order (control case).
    const stripeApi = nock('https://api.stripe.com')
      .get(`/v1/balance_transactions/${balanceTransactionId}`)
      .optionally()
      .reply(200, {
        id: balanceTransactionId,
        object: 'balance_transaction',
        amount,
        currency: 'usd',
        fee: 50,
        fee_details: [{ type: 'stripe_fee', amount: 50, currency: 'usd' }],
        net: amount - 50,
        status: 'pending',
        exchange_rate: null,
        available_on: Math.floor(Date.now() / 1000) + 86400,
      });

    const payload = JSON.stringify(event);
    const signature = stripe.webhooks.generateTestHeaderString({ payload, secret: config.stripe.webhookSigningSecret });
    const response = await request(expressApp)
      .post('/webhooks/stripe')
      .set('Content-Type', 'application/json')
      .set('Stripe-Signature', signature)
      .send(payload);

    return { response, chargeId, stripeApi };
  };

  it('control: without an edit, payment_intent.succeeded records the charge and activates the order', async () => {
    const { order, piId, pmId } = await createOrderWithChargeInFlight();

    const { response } = await deliverPaymentIntentSucceeded({ piId, pmId });

    expect(response.status).to.eq(200);
    await order.reload();
    expect(order.status).to.eq(OrderStatuses.ACTIVE);
    expect(await models.Transaction.count({ where: { OrderId: order.id } })).to.be.greaterThan(0);
  });

  it('current behaviour: after an amount edit, the same success is answered 200 and never recorded', async () => {
    const { order, piId, pmId } = await createOrderWithChargeInFlight();

    // The contributor raises the monthly amount while this month's SEPA debit is still processing.
    const result = await graphqlQueryV2(
      updateOrderMutation,
      { order: { id: idEncode(order.id, 'order') }, amount: { valueInCents: 1500, currency: 'USD' } },
      user,
    );
    expect(result.errors).to.not.exist;
    await order.reload();
    expect(order.status).to.eq(OrderStatuses.PROCESSING);
    expect(order.data?.stripePaymentIntent).to.be.undefined; // the only link to the in-flight charge is gone

    // Six business days later Stripe settles the original debit (the 10.00 confirmed before the edit).
    const { response } = await deliverPaymentIntentSucceeded({ piId, pmId, amount: 1000 });

    expect(response.status).to.eq(200); // Stripe will not redeliver
    await order.reload();
    expect(order.status).to.eq(OrderStatuses.PROCESSING);
    expect(await models.Transaction.count({ where: { OrderId: order.id } })).to.eq(0);
  });
  // Run separately: `--grep "if fixed"`; fails on main as of 2026-10-28. A fix may refuse the edit while the charge is in flight
  // or keep the PaymentIntent and check it against the amount it was confirmed for; either way it is recorded.
  it('if fixed: a success for the charge confirmed before the edit is still recorded', async () => {
    const { order, piId, pmId } = await createOrderWithChargeInFlight();

    await graphqlQueryV2(
      updateOrderMutation,
      { order: { id: idEncode(order.id, 'order') }, amount: { valueInCents: 1500, currency: 'USD' } },
      user,
    );

    await deliverPaymentIntentSucceeded({ piId, pmId, amount: 1000 });

    expect(await models.Transaction.count({ where: { OrderId: order.id } })).to.be.greaterThan(0);
  });
});
