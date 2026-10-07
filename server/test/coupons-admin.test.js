import test, { before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { database } from '../src/database.js';
import { stripeBilling } from '../src/stripe-billing.js';
import { adminService, generateCouponCode, normalizeCoupon } from '../src/admin.js';
import { service } from '../src/service.js';
import { cors } from '../src/cors.js';

const url = process.env.SHAPEDESK_TEST_DATABASE_URL;
const integration = (name, fn) => test(name, { skip: !url }, fn);
let db, billing, handle, config, instant, stripe, session, creates;

test('coupon codes normalize case, spaces and missing dashes', () => {
  assert.equal(normalizeCoupon('  sd-ab12-cd34-ef56 '), 'SD-AB12-CD34-EF56');
  assert.equal(normalizeCoupon('sdab12cd34ef56'), 'SD-AB12-CD34-EF56');
  assert.equal(normalizeCoupon('press-2026'), 'PRESS-2026');
  assert.equal(normalizeCoupon(''), '');
});
test('generated codes match the coupon pattern', () => {
  for (let i = 0; i < 20; i++) assert.match(generateCouponCode(), /^SD-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/);
});
test('admin paths permit the site origin with Authorization; others stay closed', () => {
  const mw = cors({ webOrigin: 'https://shapedesk.test' });
  const res = () => ({ headers: {}, setHeader(k, v) { this.headers[k] = v; },
    writeHead(s, h = {}) { this.status = s; Object.assign(this.headers, h); }, end() { this.ended = true; } });
  const ok = res();
  assert.equal(mw({ method: 'OPTIONS', headers: { origin: 'https://shapedesk.test' } }, ok, '/v1/admin/overview'), true);
  assert.equal(ok.status, 204);
  assert.equal(ok.headers['Access-Control-Allow-Headers'], 'Content-Type, Authorization');
  const bad = res();
  assert.equal(mw({ method: 'OPTIONS', headers: { origin: 'https://evil.example' } }, bad, '/v1/admin/overview'), true);
  assert.equal(bad.status, 403);
  const closed = res();
  assert.equal(mw({ method: 'GET', headers: { origin: 'https://shapedesk.test' } }, closed, '/v1/classify'), false);
});

before(async () => {
  if (!url) return;
  db = database(url);
  await db.pool.query(await readFile(new URL('../schema.sql', import.meta.url), 'utf8'));
});
after(async () => { if (db) await db.close(); });
beforeEach(async () => {
  if (!db) return;
  await db.pool.query(`TRUNCATE checks, usage, devices, subscriptions, checkout_attempts, billing_events,
    coupon_redemptions, coupons, admin_sessions, admin_audit, licenses, rate_limits`);
  instant = new Date('2026-10-05T00:00:00Z');
  creates = 0;
  const salt = randomBytes(16).toString('hex');
  const digest = scryptSync('test-admin-password', Buffer.from(salt, 'hex'), 64,
    { N: 16384, r: 8, p: 1, maxmem: 256 * 1024 * 1024 }).toString('hex');
  config = { hashKey: 'x'.repeat(64), stripePrice: 'price_shape', limit: 3, deviceLimit: 2,
    stripeLive: false, checkoutEnabled: true, origin: 'https://api.shapedesk.test', webOrigin: 'https://shapedesk.test',
    adminUser: 'ops', adminPassword: `scrypt:16384:8:1:${salt}:${digest}` };
  const subscription = { id: 'sub_shape', customer: 'cus_shape', livemode: false, status: 'active',
    current_period_end: Date.parse('2026-11-05T00:00:00Z') / 1000,
    items: { data: [{ quantity: 1, price: { id: 'price_shape' } }] } };
  stripe = {
    checkout: { sessions: {
      async create(input) {
        creates++;
        session = { ...input, id: 'cs_' + creates, livemode: false, url: 'https://checkout.stripe.com/c/pay/cs_shape',
          expires_at: instant.getTime() / 1000 + 86400, status: 'open', payment_status: 'unpaid',
          customer: 'cus_shape', subscription: 'sub_shape' };
        return structuredClone(session);
      },
      async retrieve() { return structuredClone(session); }
    } },
    subscriptions: { async retrieve() { return structuredClone(subscription); } },
    billingPortal: { sessions: { async create() { return { url: 'https://billing.stripe.com/p/session/test' }; } } }
  };
  billing = stripeBilling({ db, stripe, config, clock: () => instant });
  handle = service({ db, billing, config, admin: adminService({ db, config, clock: () => instant }),
    clock: () => instant, upstream: { async classify() {
      return { category: 'Docs', confidence: 0.9, model: 'jev-1.13.0' };
    } } });
});

function req(path, body, headers = {}, method = body ? 'POST' : 'GET') {
  return { url: '/v1/' + path, method, body, socket: { remoteAddress: '127.0.0.1' }, headers };
}
const appReq = (path, body, key, instance) => req(path, body,
  key ? { authorization: `Bearer ${key}`, 'x-shapedesk-instance': instance } : {});
const adminReq = (path, body, token, method) => req(path, body,
  token ? { authorization: `Bearer ${token}` } : {}, method ?? (body ? 'POST' : 'GET'));
const purchase = () => ({ licenseKey: 'sd_' + randomBytes(32).toString('hex'), deviceID: randomUUID() });
const rejects = (promise, code) => assert.rejects(promise, error => error.code === code);
const redeem = (p, code) => handle(req('redeem', { licenseKey: p.licenseKey, code, deviceID: p.deviceID }));
const login = () => handle(req('admin/session', { username: 'ops', password: 'test-admin-password' }));
const licenseID = key => createHmac('sha256', config.hashKey).update('license:' + key).digest('hex');
const DAY = 86400000;
async function addCoupon(attrs = {}) {
  await db.pool.query(`INSERT INTO coupons(code, grant_days, max_redemptions, active, expires_at)
    VALUES ($1, $2, $3, $4, $5)`, [attrs.code ?? 'WELCOME-30', attrs.days ?? 30, attrs.max ?? 5,
    attrs.active ?? true, attrs.expires ?? null]);
}
async function paidAccount() {
  const p = purchase();
  await handle(req('checkout', p));
  session.status = 'complete'; session.payment_status = 'paid';
  return { ...p, ...(await handle(req('checkout/complete', p))) };
}

integration('a coupon grants N days of Pro and activates this Mac', async () => {
  await addCoupon({ code: 'LAUNCH-2026', days: 30 });
  const p = purchase();
  const result = await redeem(p, 'launch-2026');
  assert.match(result.instanceID, /^[0-9a-f-]{36}$/);
  assert.equal(result.entitlement.active, true);
  assert.equal(result.entitlement.accessType, 'coupon');
  assert.equal(result.entitlement.canManageBilling, false);
  assert.equal(result.entitlement.account.length, 12);
  assert.equal(new Date(result.entitlement.renewsAt).getTime(), instant.getTime() + 30 * DAY);
  const entitlement = await handle(appReq('entitlement', null, p.licenseKey, result.instanceID));
  assert.equal(entitlement.active, true);
  assert.equal(entitlement.accessType, 'coupon');
});

integration('stacked coupons extend validity from the current expiry, expired ones from now', async () => {
  await addCoupon({ code: 'FIRST-30', days: 30 });
  await addCoupon({ code: 'SECOND-10', days: 10 });
  const p = purchase();
  await redeem(p, 'FIRST-30');
  const second = await redeem(p, 'SECOND-10');
  assert.equal(new Date(second.entitlement.renewsAt).getTime(), instant.getTime() + 40 * DAY);
  await rejects(redeem(p, 'FIRST-30'), 'already_redeemed');
  // Lapsed access stacks from now, not from the old expiry.
  const q = purchase();
  const id = licenseID(q.licenseKey);
  await db.pool.query('INSERT INTO licenses(id) VALUES ($1) ON CONFLICT DO NOTHING', [id]);
  await db.pool.query(`INSERT INTO subscriptions(license_id, kind, status, valid_until, checked_at)
    VALUES ($1, 'coupon', 'active', $2, $3)`, [id, new Date(instant.getTime() - DAY), instant]);
  const back = await redeem(q, 'FIRST-30');
  assert.equal(new Date(back.entitlement.renewsAt).getTime(), instant.getTime() + 30 * DAY);
});

integration('invalid, revoked, expired and exhausted coupons are refused distinctly', async () => {
  await addCoupon({ code: 'GONE', active: false });
  await addCoupon({ code: 'OLD', expires: new Date(instant.getTime() - 1000) });
  await addCoupon({ code: 'ONE-USE', max: 1 });
  await rejects(redeem(purchase(), 'NOPE'), 'coupon_invalid');
  await rejects(redeem(purchase(), '!!!'), 'coupon_invalid');
  await rejects(redeem(purchase(), 'GONE'), 'coupon_revoked');
  await rejects(redeem(purchase(), 'OLD'), 'coupon_expired');
  await redeem(purchase(), 'ONE-USE');
  await rejects(redeem(purchase(), 'ONE-USE'), 'coupon_exhausted');
});

integration('paid, owner and suspended accounts cannot redeem', async () => {
  await addCoupon({ code: 'EXTRA', days: 5 });
  const paid = await paidAccount();
  await rejects(redeem(paid, 'EXTRA'), 'already_subscribed');
  const owner = purchase();
  const ownerID = licenseID(owner.licenseKey);
  await db.pool.query('INSERT INTO licenses(id) VALUES ($1)', [ownerID]);
  await db.pool.query(`INSERT INTO subscriptions(license_id, kind, status, valid_until, checked_at)
    VALUES ($1, 'owner', 'active', $2, $3)`, [ownerID, new Date(instant.getTime() + DAY), instant]);
  await rejects(redeem(owner, 'EXTRA'), 'already_subscribed');
  const banned = purchase();
  const bannedID = licenseID(banned.licenseKey);
  await db.pool.query('INSERT INTO licenses(id) VALUES ($1)', [bannedID]);
  await db.pool.query(`INSERT INTO subscriptions(license_id, kind, status, valid_until, checked_at, suspended)
    VALUES ($1, 'coupon', 'active', $2, $3, true)`, [bannedID, new Date(instant.getTime() + DAY), instant]);
  await rejects(redeem(banned, 'EXTRA'), 'account_suspended');
});

integration('redemption respects the Mac limit and rolls back cleanly on failure', async () => {
  await addCoupon({ code: 'C1' }); await addCoupon({ code: 'C2' }); await addCoupon({ code: 'C3' });
  const p = purchase();
  await redeem(p, 'C1');
  await redeem({ licenseKey: p.licenseKey, deviceID: randomUUID() }, 'C2');
  await rejects(redeem({ licenseKey: p.licenseKey, deviceID: randomUUID() }, 'C3'), 'device_limit');
  const { rows } = await db.pool.query('SELECT redeemed FROM coupons WHERE code = $1', ['C3']);
  assert.equal(rows[0].redeemed, 0);
  assert.equal((await db.pool.query('SELECT count(*)::int AS n FROM coupon_redemptions')).rows[0].n, 2);
});

integration('a paid checkout converts coupon access into Stripe access', async () => {
  await addCoupon({ code: 'TRIAL-30', days: 30 });
  const p = purchase();
  await redeem(p, 'TRIAL-30');
  await handle(req('checkout', p));
  session.status = 'complete'; session.payment_status = 'paid';
  const done = await handle(req('checkout/complete', p));
  assert.equal(done.entitlement.accessType, 'stripe');
  const { rows } = await db.pool.query('SELECT kind, customer_id, subscription_id FROM subscriptions WHERE license_id = $1',
    [licenseID(p.licenseKey)]);
  assert.equal(rows[0].kind, 'stripe');
  assert.equal(rows[0].customer_id, 'cus_shape');
  assert.equal(rows[0].subscription_id, 'sub_shape');
});

integration('redeem rejects malformed input and needs billing mode', async () => {
  await addCoupon({ code: 'VALID-CODE', days: 5 });
  await rejects(redeem({ licenseKey: 'not-a-key', deviceID: randomUUID() }, 'VALID-CODE'), 'invalid_request');
  await rejects(redeem({ licenseKey: 'sd_' + 'a'.repeat(64), deviceID: 'nope' }, 'VALID-CODE'), 'invalid_request');
  const bare = service({ db, config, clock: () => instant,
    upstream: { async classify() { return {}; } } });
  await rejects(bare(req('redeem', { licenseKey: 'sd_' + 'a'.repeat(64), code: 'VALID-CODE', deviceID: randomUUID() })),
    'coupon_unavailable');
});

integration('admin login issues a token and refuses wrong credentials', async () => {
  await rejects(handle(req('admin/session', { username: 'ops', password: 'wrong-password-123' })), 'admin_auth');
  await rejects(handle(req('admin/session', { username: 'intruder', password: 'test-admin-password' })), 'admin_auth');
  const { token, expiresAt } = await login();
  assert.match(token, /^[0-9a-f]{64}$/);
  assert.ok(new Date(expiresAt) > instant);
  const overview = await handle(adminReq('admin/overview', null, token));
  assert.equal(typeof overview.accounts, 'number');
  await rejects(handle(adminReq('admin/overview', null, 'f'.repeat(64))), 'admin_auth');
  await rejects(handle(adminReq('admin/overview', null, null)), 'admin_auth');
  await db.pool.query(`UPDATE admin_sessions SET expires_at = now() - interval '1 second'`);
  await rejects(handle(adminReq('admin/overview', null, token)), 'admin_auth');
});

integration('admin routes are hidden when the admin is not configured', async () => {
  const plain = service({ db, billing, config: { ...config, adminUser: null, adminPassword: null },
    admin: null, clock: () => instant, upstream: {} });
  await rejects(plain(req('admin/overview')), 'not_found');
  await rejects(plain(req('admin/session', { username: 'ops', password: 'x' })), 'not_found');
});

integration('the admin manages coupons end to end', async () => {
  const { token } = await login();
  const created = await handle(adminReq('admin/coupons', { grantDays: 14, maxRedemptions: 3, note: 'beta' }, token));
  assert.match(created.code, /^SD-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/);
  assert.equal(created.grantDays, 14);
  const list = await handle(adminReq('admin/coupons', null, token));
  assert.equal(list.coupons.length, 1);
  const revoked = await handle(adminReq(`admin/coupons/${created.code}/revoke`, {}, token));
  assert.equal(revoked.active, false);
  await rejects(redeem(purchase(), created.code), 'coupon_revoked');
  await handle(adminReq(`admin/coupons/${created.code}/activate`, {}, token));
  const account = purchase();
  const done = await redeem(account, created.code);
  assert.equal(done.entitlement.active, true);
  const redemptions = await handle(adminReq(`admin/coupons/${created.code}/redemptions`, null, token));
  assert.equal(redemptions.redemptions.length, 1);
  assert.equal(redemptions.redemptions[0].account, licenseID(account.licenseKey));
  const manual = await handle(adminReq('admin/coupons', { code: 'press-kit', grantDays: 7, maxRedemptions: 100 }, token));
  assert.equal(manual.code, 'PRESS-KIT');
  await rejects(handle(adminReq('admin/coupons', { code: 'PRESS-KIT', grantDays: 7, maxRedemptions: 1 }, token)),
    'coupon_exists');
  await rejects(handle(adminReq('admin/coupons', { grantDays: 0, maxRedemptions: 1 }, token)), 'invalid_request');
  const audit = await handle(adminReq('admin/audit', null, token));
  assert.ok(audit.audit.some(e => e.action === 'coupon_created' && e.target === created.code));
  assert.ok(audit.audit.some(e => e.action === 'coupon_revoked'));
  assert.ok(audit.audit.some(e => e.action === 'admin_login'));
});

integration('the admin manages accounts: suspend, grant, quota and devices', async () => {
  await addCoupon({ code: 'USER-30', days: 30 });
  const p = purchase();
  const activation = await redeem(p, 'USER-30');
  const id = licenseID(p.licenseKey);
  const { token } = await login();
  const found = await handle(adminReq(`admin/accounts?q=${id.slice(0, 8)}`, null, token));
  assert.equal(found.accounts.length, 1);
  assert.equal(found.accounts[0].id, id);
  const detail = await handle(adminReq(`admin/accounts/${id}`, null, token));
  assert.equal(detail.subscription.kind, 'coupon');
  assert.equal(detail.subscription.active, true);
  assert.equal(detail.devices.length, 1);
  assert.equal(detail.redemptions.length, 1);
  // Suspend blocks access without deleting anything.
  await handle(adminReq(`admin/accounts/${id}/suspend`, {}, token));
  const suspended = await handle(appReq('entitlement', null, p.licenseKey, activation.instanceID));
  assert.equal(suspended.active, false);
  await handle(adminReq(`admin/accounts/${id}/unsuspend`, {}, token));
  // Grant stacks onto the remaining validity and switches the account to owner access.
  const grant = await handle(adminReq(`admin/accounts/${id}/grant`, { days: 5 }, token));
  assert.equal(new Date(grant.validUntil).getTime(), instant.getTime() + 35 * DAY);
  const granted = await handle(adminReq(`admin/accounts/${id}`, null, token));
  assert.equal(granted.subscription.kind, 'owner');
  // Quota override is visible to the app.
  await handle(adminReq(`admin/accounts/${id}/quota`, { used: 2 }, token));
  const quota = await handle(appReq('entitlement', null, p.licenseKey, activation.instanceID));
  assert.equal(quota.used, 2);
  // Deactivating every Mac cuts access immediately.
  await handle(adminReq(`admin/accounts/${id}/deactivate-devices`, { device: 'all' }, token));
  await rejects(handle(appReq('entitlement', null, p.licenseKey, activation.instanceID)), 'inactive');
  // Paid accounts refuse a manual grant.
  const paid = await paidAccount();
  await rejects(handle(adminReq(`admin/accounts/${licenseID(paid.licenseKey)}/grant`, { days: 5 }, token)),
    'paid_subscription');
  await rejects(handle(adminReq(`admin/accounts/${'f'.repeat(64)}/grant`, { days: 5 }, token)), 'not_found');
  const audit = await handle(adminReq('admin/audit', null, token));
  for (const action of ['account_suspended', 'account_unsuspended', 'grant_days', 'quota_set', 'devices_deactivated'])
    assert.ok(audit.audit.some(e => e.action === action), `audit ${action}`);
});

integration('admin login rate limits after repeated failures', async () => {
  const wrong = () => handle(req('admin/session', { username: 'ops', password: 'wrong-password-123' }));
  for (let i = 0; i < 10; i++) await rejects(wrong(), 'admin_auth');
  await rejects(wrong(), 'rate_limited');
});
