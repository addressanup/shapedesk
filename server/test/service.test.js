import test, { before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { database } from '../src/database.js';
import { service } from '../src/service.js';
import { upstreams } from '../src/upstreams.js';

const url = process.env.SHAPEDESK_TEST_DATABASE_URL;
const integration = (name, fn) => test(name, { skip: !url }, fn);
const config = { limit: 3, hashKey: 'test-only-hash-key'.repeat(4), store: 42, variant: 7,
  checkoutURL: 'https://example.lemonsqueezy.com/buy/test', jevKey: 'fake-vendor-key' };
const file = { name: 'report.pdf', fileExtension: 'pdf', byteSize: 100,
  createdAt: '2026-10-01T00:00:00Z', modifiedAt: '2026-10-01T00:00:00Z' };
let db, handle, upstream, calls, invalid, failure, instant, waitForAI;
before(async () => {
  if (!url) return;
  db = database(url);
  await db.pool.query(await readFile(new URL('../schema.sql', import.meta.url), 'utf8'));
});
after(async () => { if (db) await db.close(); });
beforeEach(async () => {
  if (!db) return;
  await db.pool.query('TRUNCATE checks, usage, devices, subscriptions, checkout_attempts, billing_events, licenses, rate_limits');
  calls = { activate: 0, validate: 0, classify: 0, deactivate: 0 };
  invalid = false; failure = false; waitForAI = null; instant = new Date('2026-10-05T00:00:00Z');
  upstream = {
    ...upstreams(config),
    async license(action, key, fields) {
      calls[action]++;
      if (action === 'deactivate') return { deactivated: true };
      return { activated: !invalid, valid: !invalid,
        license_key: { status: invalid ? 'expired' : 'active', expires_at: null },
        instance: { id: fields.instance_id ?? randomUUID() }, meta: { store_id: 42, variant_id: 7 } };
    },
    async classify() {
      calls.classify++;
      if (waitForAI) await waitForAI;
      if (failure) throw new Error('Simulated upstream failure with secret data that must not escape');
      return { category: 'Docs', confidence: 0.8, model: 'jev-1.13.0' };
    }
  };
  handle = service({ config, db, upstream, clock: () => instant });
});
function request(path, body, auth, method = body ? 'POST' : 'GET') {
  return { url: '/v1/' + path, method, body, socket: { remoteAddress: '127.0.0.1' },
    headers: auth ? { authorization: 'Bearer ' + auth.key, 'x-shapedesk-instance': auth.instance } : {} };
}
async function activate(key = 'customer-license', deviceID = randomUUID()) {
  const result = await handle(request('activate', { licenseKey: key, deviceID }));
  return { key, instance: result.instanceID, deviceID, entitlement: result.entitlement };
}
const classify = (auth, requestID = randomUUID(), metadata = file) => handle(request('classify', { requestID, metadata }, auth));
const rejects = (promise, code) => assert.rejects(promise, error => error.code === code);

integration('activation retry uses the same device slot; devices share one allowance', async () => {
  const a = await activate();
  const retry = await activate(a.key, a.deviceID);
  const b = await activate(a.key);
  assert.equal(a.instance, retry.instance);
  assert.equal(calls.activate, 2);
  assert.equal(calls.validate, 1);
  await classify(a); await classify(b);
  assert.equal((await handle(request('entitlement', null, a))).used, 2);
  const rows = await db.pool.query('SELECT * FROM devices');
  assert.equal(rows.rows.length, 2);
});

integration('server authorization cannot be bypassed with an unknown license or instance', async () => {
  await rejects(classify({ key: 'made-up-license', instance: randomUUID() }), 'inactive');
  const auth = await activate();
  await rejects(classify({ ...auth, instance: randomUUID() }), 'inactive');
  assert.equal(calls.classify, 0);
});

integration('concurrent requests cannot exceed the monthly quota', async () => {
  const auth = await activate();
  const results = await Promise.allSettled(Array.from({ length: 12 }, () => classify(auth)));
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 3);
  assert.equal(results.filter(r => r.reason?.code === 'quota_exhausted').length, 9);
  assert.equal(calls.classify, 3);
  assert.equal((await handle(request('entitlement', null, auth))).used, 3);
});

integration('lost-response replay is free, even at quota, and altered metadata is rejected', async () => {
  const auth = await activate(), id = randomUUID();
  const first = await classify(auth, id);
  await classify(auth); await classify(auth);
  const replay = await classify(auth, id);
  assert.equal(replay.confidence, first.confidence);
  assert.equal(replay.entitlement.used, 3);
  assert.equal(calls.classify, 3);
  await rejects(classify(auth, id, { ...file, name: 'changed.pdf' }), 'request_conflict');
});

integration('concurrent identical requests reserve and call Jev only once', async () => {
  const auth = await activate(), id = randomUUID();
  let release;
  waitForAI = new Promise(resolve => { release = resolve; });
  const first = classify(auth, id);
  while (!calls.classify) await new Promise(resolve => setImmediate(resolve));
  await rejects(classify(auth, id), 'pending');
  release();
  await first;
  assert.equal(calls.classify, 1);
  assert.equal((await handle(request('entitlement', null, auth))).used, 1);
});

integration('failed upstream calls refund exactly once and preserve the failed request ID', async () => {
  const auth = await activate(), id = randomUUID();
  failure = true;
  await rejects(classify(auth, id), 'check_failed');
  assert.equal((await handle(request('entitlement', null, auth))).used, 0);
  failure = false;
  await rejects(classify(auth, id), 'check_failed');
  const success = await classify(auth);
  assert.equal(success.entitlement.used, 1);
  assert.equal(calls.classify, 2);
});

integration('crashed invocations release abandoned reservations', async () => {
  const auth = await activate(), id = randomUUID();
  await classify(auth, id);
  await db.pool.query("UPDATE checks SET status = 'pending', response = NULL, created_at = now() - interval '2 minutes'");
  const usage = await handle(request('entitlement', null, auth));
  assert.equal(usage.used, 0);
  await rejects(classify(auth, id), 'check_failed');
});

integration('subscriptions are revalidated after cache expiry and revoked licenses cannot call Jev', async () => {
  const auth = await activate();
  invalid = true;
  instant = new Date('2026-10-05T00:05:01Z');
  await rejects(classify(auth), 'inactive');
  assert.equal(calls.validate, 1);
  assert.equal(calls.classify, 0);
});

integration('calendar-month rollover creates a new quota bucket without erasing prior replay history', async () => {
  const auth = await activate();
  const id = randomUUID();
  await classify(auth, id); await classify(auth); await classify(auth);
  instant = new Date('2026-11-01T00:00:00Z');
  const replay = await classify(auth, id);
  assert.equal(replay.entitlement.used, 0);
  const next = await classify(auth);
  assert.equal(next.entitlement.used, 1);
  assert.equal(next.entitlement.resetsAt, '2026-12-01T00:00:00.000Z');
});

integration('deactivation is idempotent and blocks subsequent AI requests', async () => {
  const auth = await activate();
  await handle(request('deactivate', {}, auth));
  await handle(request('deactivate', {}, auth));
  assert.equal(calls.deactivate, 1);
  await rejects(classify(auth), 'inactive');
});

integration('database contains no raw filename, customer license, or vendor key', async () => {
  const auth = await activate();
  await classify(auth);
  for (const table of ['licenses', 'devices', 'checks', 'usage', 'rate_limits']) {
    const rows = JSON.stringify((await db.pool.query(`SELECT * FROM ${table}`)).rows);
    assert.ok(!rows.includes(file.name));
    assert.ok(!rows.includes(auth.key));
    assert.ok(!rows.includes(config.jevKey));
  }
});

integration('the durable rate limiter enforces its bound across concurrent callers', async () => {
  const results = await Promise.allSettled(Array.from({ length: 20 }, () => db.rate('rate-test', 5, 60)));
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 5);
});

integration('multiple licenses can activate concurrently without exhausting transaction pool slots', async () => {
  const results = await Promise.all(Array.from({ length: 6 }, (_, i) => activate('license-' + i)));
  assert.equal(results.length, 6);
});

integration('a lost database commit acknowledgment replays the completed result without refund or recharge', async () => {
  let transactions = 0;
  const flakyDB = { ...db, async withLicense(id, operation) {
    const result = await db.withLicense(id, operation);
    if (++transactions === 3) throw new Error('Lost COMMIT acknowledgment');
    return result;
  } };
  handle = service({ config, db: flakyDB, upstream, clock: () => instant });
  const auth = await activate();
  const result = await classify(auth);
  assert.equal(result.entitlement.used, 1);
  assert.equal(calls.classify, 1);
  assert.equal((await db.pool.query('SELECT status FROM checks')).rows[0].status, 'complete');
});

integration('a request crossing midnight uses one consistent month for its reservation and refund', async () => {
  const crossingDB = { ...db, async withLicense(id, operation) {
    return db.withLicense(id, q => operation(async (sql, values) => {
      const result = await q(sql, values);
      if (sql.includes('INSERT INTO usage')) instant = new Date('2026-11-01T00:00:00Z');
      return result;
    }));
  } };
  handle = service({ config, db: crossingDB, upstream, clock: () => instant });
  const auth = await activate();
  failure = true;
  await rejects(classify(auth), 'check_failed');
  const rows = (await db.pool.query('SELECT used, period::text FROM usage')).rows;
  assert.equal(rows[0].period, '2026-10-01');
  assert.equal(rows[0].used, 0);
});
