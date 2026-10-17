import { jest, describe, it, expect, beforeEach } from '@jest/globals';
import Stripe from 'stripe';

/**
 * charge.refunded webhook vs a refund made in EverShop.
 *
 * Stripe has not included `charge.refunds` in Charge objects (and so in `charge.refunded` events) since API version
 * 2022-11-15; event payloads follow the webhook endpoint's API version, which the merchant chooses in the Dashboard.
 * The handler then falls back to `transactionId: charge.id` and `amount: charge.amount_refunded` (cumulative).
 *
 * Only the database layer is faked (an in-memory payment_transaction table), plus logging and event emission.
 * The webhook handler, recordRefund(), the refund-status helpers and Stripe's signature check are the real code.
 */
const ENDPOINT_SECRET = 'whsec_test_endpoint_secret';
const ORDER = {
  order_id: 7, uuid: 'order-uuid-7', payment_method: 'stripe', payment_status: 'stripe_captured', currency: 'USD',
  grand_total: '100.0000'
};
let transactions; // payment_transaction rows
let statuses; // updatePaymentStatus calls
let events; // emitted events

const fakeConnection = {
  query: jest.fn(async (sql, params) => {
    if (/SUM\("amount"\)/.test(sql)) {
      const refunded = transactions
        .filter((t) => t.payment_transaction_order_id === params[0] && t.payment_action === 'refund')
        .reduce((sum, t) => sum + Number(t.amount), 0);
      return { rows: [{ refunded }] };
    }
    if (/FROM "order" o\s+JOIN "payment_transaction"/.test(sql)) {
      const found = transactions.find((t) => t.transaction_id === params[0]);
      return { rows: found ? [ORDER] : [] };
    }
    return { rows: [] };
  })
};

const queryBuilder = {
  startTransaction: jest.fn(async () => {}),
  commit: jest.fn(async () => {}),
  rollback: jest.fn(async () => {}),
  getConnection: jest.fn(async () => fakeConnection),
  select: jest.fn(() => {
    const q = {
      from: () => q,
      orderBy: () => q,
      where: (col, op, val) => { q.orderId = val; return q; },
      execute: async () =>
        transactions
          .filter((t) => t.payment_transaction_order_id === q.orderId)
          .slice()
          .sort((a, b) => b.payment_transaction_id - a.payment_transaction_id)
    };
    return q;
  }),
  insertOnUpdate: jest.fn((table, keys) => ({
    given: (row) => ({
      execute: async () => {
        const existing = transactions.find((t) => keys.every((k) => t[k] === row[k]));
        if (existing) Object.assign(existing, row);
        else transactions.push({ payment_transaction_id: transactions.length + 1, ...row });
      }
    })
  }))
};

jest.unstable_mockModule('@evershop/postgres-query-builder', () => queryBuilder);
jest.unstable_mockModule('../../../../lib/postgres/connection.js', () => ({
  pool: {}, getConnection: jest.fn(async () => fakeConnection), connectionSetting: {}
}));
jest.unstable_mockModule('../../../../lib/util/getConfig.js', () => ({
  getConfig: jest.fn((path, def) =>
    path === 'system.stripe' ? { secretKey: 'sk_test_fake', endpointSecret: ENDPOINT_SECRET } : def)
}));
jest.unstable_mockModule('../../../setting/services/setting.js', () => ({ getSetting: jest.fn(async (n, d) => d) }));
jest.unstable_mockModule('../../../../lib/log/logger.js', () => ({ debug: jest.fn(), error: jest.fn(), info: jest.fn(), warning: jest.fn() }));
jest.unstable_mockModule('../../../../lib/event/emitter.js', () => ({
  emit: jest.fn(async (name, data) => { events.push({ name, data }); })
}));
jest.unstable_mockModule('../../../oms/services/addOrderActivityLog.js', () => ({ default: jest.fn(async () => {}) }));
jest.unstable_mockModule('../../../oms/services/updatePaymentStatus.js', () => ({
  updatePaymentStatus: jest.fn(async (orderId, status) => { statuses.push(status); })
}));

const { recordRefund } = await import('../../../oms/services/recordRefund.js');
const { default: webhook } = await import('../../api/stripeWebHook/[bodyJson]webhook.js');

function chargeRefundedEvent(amountRefunded) {
  // A charge.refunded payload as Stripe sends it on API versions >= 2022-11-15: no `refunds` list.
  return {
    id: 'evt_charge_refunded_1', object: 'event', type: 'charge.refunded', api_version: '2025-09-30.clover',
    data: { object: {
      id: 'ch_test_1', object: 'charge', amount: 10000, amount_captured: 10000, amount_refunded: amountRefunded,
      currency: 'usd', payment_intent: 'pi_test_1', refunded: amountRefunded >= 10000, status: 'succeeded'
    } }
  };
}

async function deliver(event) {
  const payload = JSON.stringify(event);
  const header = Stripe.webhooks.generateTestHeaderString({ payload, secret: ENDPOINT_SECRET });
  const response = { statusCode: 200, body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; }, send(body) { this.body = body; return this; } };
  await webhook({ headers: { 'stripe-signature': header }, body: Buffer.from(payload) }, response, jest.fn());
  return response;
}

describe('Stripe charge.refunded after a refund made in EverShop', () => {
  it('records a refund made in the Stripe Dashboard once', async () => {
    transactions = [{ payment_transaction_id: 1, payment_transaction_order_id: 7, transaction_id: 'pi_test_1',
      amount: '100.0000', payment_action: 'capture', transaction_type: 'online' }];
    statuses = []; events = [];
    await deliver(chargeRefundedEvent(2500));
    await deliver(chargeRefundedEvent(2500)); // retried delivery
    const refunds = transactions.filter((t) => t.payment_action === 'refund');
    expect(refunds.reduce((s, r) => s + Number(r.amount), 0)).toBe(25);
  });

  beforeEach(() => {
    statuses = []; events = [];
    transactions = [{ payment_transaction_id: 1, payment_transaction_order_id: 7, transaction_id: 'pi_test_1',
      amount: '100.0000', payment_action: 'capture', transaction_type: 'online' }];
  });

  it('does not record a partial refund a second time', async () => {
    // Admin refunds 30.00 in EverShop: the refund route calls Stripe, then records the refund under its re_ id.
    await recordRefund({ order: ORDER, transactionId: 're_test_admin', amount: 30 });
    // Stripe then delivers charge.refunded for the same refund.
    const res = await deliver(chargeRefundedEvent(3000));
    expect(res.statusCode).toBe(200);

    const refunds = transactions.filter((t) => t.payment_action === 'refund');
    expect(refunds.map((r) => [r.transaction_id, Number(r.amount)])).toEqual([['re_test_admin', 30]]);
  });

  it('does not report a full refund twice', async () => {
    await recordRefund({ order: ORDER, transactionId: 're_test_admin_full', amount: 100 });
    await deliver(chargeRefundedEvent(10000));

    const refunded = transactions.filter((t) => t.payment_action === 'refund').reduce((s, r) => s + Number(r.amount), 0);
    expect(refunded).toBe(100);
    expect(events.filter((e) => e.name === 'order_refunded')).toHaveLength(1);
  });
});
