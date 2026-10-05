import test, { before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, randomBytes, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { once } from 'node:events';
import { createServer } from 'node:http';
import Stripe from 'stripe';
import { database } from '../src/database.js';
import { stripeBilling } from '../src/stripe-billing.js';
import { stripeWebhookHandler } from '../src/stripe-webhook.js';
import { service } from '../src/service.js';

const url = process.env.SHAPEDESK_TEST_DATABASE_URL;
const integration = (name, fn) => test(name, { skip: !url }, fn);
let db, billing, stripe, handle, subscription, session, config, creates, aiCalls, instant;
const file = { name: 'report.pdf', fileExtension: 'pdf', byteSize: 100,
  createdAt: '2026-10-01T00:00:00Z', modifiedAt: '2026-10-01T00:00:00Z' };
before(async () => {
  if (!url) return;
  db = database(url); await db.pool.query(await readFile(new URL('../schema.sql', import.meta.url), 'utf8'));
});
after(async () => { if (db) await db.close(); });
beforeEach(async () => {
  if (!db) return;
  await db.pool.query('TRUNCATE checks, usage, devices, subscriptions, checkout_attempts, billing_events, licenses, rate_limits');
  instant = new Date('2026-10-05T00:00:00Z'); creates = 0; aiCalls = 0;
  config = { hashKey: 'x'.repeat(64), stripePrice: 'price_shape', limit: 3, deviceLimit: 2,
    stripeLive: false, checkoutEnabled: true, origin: 'https://api.shapedesk.test' };
  subscription = { id: 'sub_shape', customer: 'cus_shape', livemode: false, status: 'active',
    current_period_end: Date.parse('2026-11-05T00:00:00Z') / 1000,
    items: { data: [{ quantity: 1, price: { id: 'price_shape' } }] } };
  stripe = {
    checkout: { sessions: {
      async create(input, options) {
        creates++; assert.equal(input.line_items[0].price, 'price_shape');
        assert.equal(input.managed_payments.enabled, false);
        assert.ok(options.idempotencyKey.startsWith('shapedesk-checkout-'));
        session = { ...input, id: 'cs_' + creates, livemode: false, url: 'https://checkout.stripe.com/c/pay/cs_shape',
          expires_at: instant.getTime() / 1000 + 86400, status: 'open', payment_status: 'unpaid', customer: 'cus_shape', subscription: 'sub_shape' };
        return structuredClone(session);
      },
      async retrieve() { return structuredClone(session); }
    } },
    subscriptions: { async retrieve() { return structuredClone(subscription); } },
    billingPortal: { sessions: { async create(input) { assert.equal(input.customer, 'cus_shape'); return { url: 'https://billing.stripe.com/p/session/test' }; } } }
  };
  billing = stripeBilling({ db, stripe, config, clock: () => instant });
  handle = service({ db, billing, config, clock: () => instant, upstream: { async classify() {
    aiCalls++; return { category: 'Docs', confidence: 0.9, model: 'jev-1.13.0' };
  } } });
});
function req(path, body, auth) {
  return { url: '/v1/' + path, method: body ? 'POST' : 'GET', body,
    socket: { remoteAddress: '127.0.0.1' }, headers: auth ? {
      authorization: 'Bearer ' + auth.licenseKey, 'x-shapedesk-instance': auth.instanceID
    } : {} };
}
const purchase = () => ({ licenseKey: 'sd_' + randomBytes(32).toString('hex'), deviceID: randomUUID() });
const rejects = (promise, code) => assert.rejects(promise, error => error.code === code);
const classify = auth => handle(req('classify', { requestID: randomUUID(), metadata: file }, auth));
async function paid() {
  const p = purchase(); await handle(req('checkout', p)); session.status = 'complete'; session.payment_status = 'paid';
  return { ...p, ...(await handle(req('checkout/complete', p))) };
}
const event = (type, object, id = 'evt_' + randomUUID()) => ({ id, type, livemode: false, data: { object } });

integration('Stripe checkout is idempotent and a purchase secret is bound to its Mac', async () => {
  const p = purchase();
  const [a,b] = await Promise.all([handle(req('checkout', p)), handle(req('checkout', p))]);
  assert.deepEqual(a, b); assert.equal(creates, 1);
  assert.ok(!JSON.stringify(session).includes(p.licenseKey));
  await rejects(handle(req('checkout/complete', { ...p, deviceID: randomUUID() })), 'invalid_license');
  await rejects(handle(req('activate', p)), 'invalid_license');
  await rejects(handle(req('checkout/complete', p)), 'checkout_pending');
  assert.equal(aiCalls, 0);
});

integration('paid checkout provisions access once and supports restore with shared metering', async () => {
  const a = await paid();
  const retry = await handle(req('checkout/complete', a));
  assert.equal(a.instanceID, retry.instanceID);
  const b = { ...a, ...(await handle(req('activate', { ...a, deviceID: randomUUID() }))) };
  assert.equal((await classify(a)).entitlement.used, 1);
  assert.equal((await classify(b)).entitlement.used, 2);
  assert.equal(a.entitlement.accessType, 'stripe');
  assert.equal(a.entitlement.canManageBilling, true);
  await rejects(handle(req('activate', { ...a, deviceID: randomUUID() })), 'device_limit');
  assert.equal((await handle(req('portal', {}, a))).url, 'https://billing.stripe.com/p/session/test');
});

integration('foreign prices, customers, environments and unpaid sessions cannot provision access', async () => {
  for (const change of [() => subscription.items.data[0].price.id = 'price_foreign',
    () => subscription.customer = 'cus_foreign', () => subscription.livemode = true,
    () => session.client_reference_id = 'foreign']) {
    const p = purchase(); await handle(req('checkout', p));
    session.status = 'complete'; session.payment_status = 'paid';
    const saved = structuredClone(subscription); change();
    await rejects(handle(req('checkout/complete', p)), 'invalid_subscription');
    subscription = saved;
  }
  assert.equal((await db.pool.query('SELECT * FROM subscriptions')).rowCount, 0);
});

integration('Stripe webhooks use canonical status, deduplicate and revoke access on payment failure', async () => {
  const auth = await paid();
  subscription.status = 'past_due';
  const change = event('customer.subscription.updated', { id: 'sub_shape', status: 'active' });
  await billing.webhook(change); await billing.webhook(change);
  assert.equal((await db.pool.query('SELECT * FROM billing_events')).rowCount, 1);
  await rejects(classify(auth), 'inactive');
  assert.equal((await handle(req('entitlement', null, auth))).active, false);
  assert.ok((await handle(req('portal', {}, auth))).url); // Past-due customers can fix payment.
  subscription.status = 'active';
  await billing.webhook(event('customer.subscription.updated', { id: 'sub_shape', status: 'canceled' }));
  assert.equal((await classify(auth)).entitlement.used, 1);
});

integration('expiry, cancellation, pauses, suspension and unknown credentials deny AI use', async () => {
  const auth = await paid();
  for (const status of ['canceled', 'unpaid', 'incomplete', 'paused']) {
    subscription.status = status;
    await billing.webhook(event('customer.subscription.updated', { id: 'sub_shape' }));
    await rejects(classify(auth), 'inactive');
  }
  subscription.status = 'active'; subscription.pause_collection = { behavior: 'void' };
  await billing.webhook(event('customer.subscription.updated', { id: 'sub_shape' }));
  await rejects(classify(auth), 'inactive');
  delete subscription.pause_collection; subscription.current_period_end = instant.getTime()/1000 - 1;
  await rejects(classify(auth), 'inactive');
  await rejects(classify({ ...auth, licenseKey: purchase().licenseKey }), 'inactive');
  assert.equal(aiCalls, 0);
});

integration('checkout gate does not disable existing subscriptions and revoking a Mac preserves undo-independent access', async () => {
  const auth = await paid(); config.checkoutEnabled = false;
  await rejects(handle(req('checkout', purchase())), 'checkout_unavailable');
  await classify(auth);
  await handle(req('deactivate', {}, auth));
  await rejects(classify(auth), 'inactive');
});

integration('completed Checkout webhooks provision access before the app returns, without trusting client success', async () => {
  const p = purchase(); await handle(req('checkout', p)); session.status = 'complete'; session.payment_status = 'paid';
  await billing.webhook(event('checkout.session.completed', { id: session.id }));
  const auth = { ...p, ...(await handle(req('checkout/complete', p))) };
  assert.equal(auth.entitlement.active, true);
  await rejects(billing.webhook({ ...event('customer.subscription.updated', { id: 'sub_shape' }), livemode: true }), 'invalid_event');
});

integration('server-granted owner access is metered and revocable without a Stripe credential', async () => {
  config.checkoutEnabled = false;
  billing = stripeBilling({ db, stripe: null, config, clock: () => instant });
  handle = service({ db, billing, config, clock: () => instant, upstream: { async classify() {
    return { category: 'Docs', confidence: 0.9, model: 'jev-1.13.0' };
  } } });
  const p = purchase();
  const id = createHmac('sha256', config.hashKey).update('license:' + p.licenseKey).digest('hex');
  await rejects(handle(req('activate', p)), 'invalid_license');
  await db.withLicense(id, q => q(`INSERT INTO subscriptions(license_id, kind, status, valid_until)
    VALUES ($1, 'owner', 'active', $2)`, [new Date(instant.getTime() + 86400000)]));
  const auth = { ...p, ...(await handle(req('activate', p))) };
  assert.equal(auth.entitlement.accessType, 'owner');
  assert.equal(auth.entitlement.canManageBilling, false);
  assert.equal((await classify(auth)).entitlement.used, 1);
  await rejects(handle(req('portal', {}, auth)), 'billing_unavailable');
  await rejects(handle(req('checkout', purchase())), 'checkout_unavailable');
  await db.pool.query('UPDATE subscriptions SET suspended = true WHERE license_id = $1', [id]);
  await rejects(classify(auth), 'inactive');
});

integration('full refunds and disputes suspend only the matching subscription and later updates cannot clear the suspension', async () => {
  const auth = await paid();
  stripe.invoices = { async retrieve(id) { return { subscription: id === 'in_shape' ? 'sub_shape' : 'sub_foreign' }; } };
  stripe.charges = { async retrieve() { return { invoice: 'in_shape' }; } };
  await billing.webhook(event('charge.refunded', { id: 'ch_foreign', refunded: true, invoice: 'in_foreign' }));
  await billing.webhook(event('charge.refunded', { id: 'ch_partial', refunded: false, invoice: 'in_shape' }));
  assert.equal((await handle(req('entitlement', null, auth))).active, true);
  await billing.webhook(event('charge.refunded', { id: 'ch_shape', refunded: true, invoice: 'in_shape' }));
  await rejects(classify(auth), 'inactive');
  await billing.webhook(event('customer.subscription.updated', { id: 'sub_shape', status: 'active' }));
  await rejects(classify(auth), 'inactive');
  await db.pool.query('UPDATE subscriptions SET suspended = false');
  await billing.webhook(event('charge.dispute.created', { id: 'dp_shape', charge: 'ch_shape' }));
  await rejects(classify(auth), 'inactive');
  assert.ok((await handle(req('portal', {}, auth))).url);
});

test('Stripe webhook requires a fresh signature over exact bytes, bounds bodies and sanitizes failures', async t => {
  const stripe = new Stripe('sk_test_fake'), secret = 'whsec_test'; let calls = 0;
  const server = createServer(stripeWebhookHandler({ stripe, secret, handle: async () => { calls++; return { received: true }; } }));
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => { server.closeAllConnections(); server.close(); });
  const target = `http://127.0.0.1:${server.address().port}`;
  const payload = JSON.stringify({ id: 'evt_test', data: { object: { value: 1 } } });
  const send = (body, signature) => fetch(target, { method: 'POST', body,
    headers: { 'content-type': 'application/json', 'stripe-signature': signature } });
  const signature = stripe.webhooks.generateTestHeaderString({ payload, secret });
  assert.equal((await send(payload, signature)).status, 200);
  assert.equal((await send(payload + ' ', signature)).status, 400);
  const old = stripe.webhooks.generateTestHeaderString({ payload, secret, timestamp: Math.floor(Date.now()/1000) - 1000 });
  assert.equal((await send(payload, old)).status, 400);
  assert.equal((await send('x'.repeat(262145), signature)).status, 413);
  assert.equal(calls, 1);
});
