import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { metadata } from '../src/service.js';
import { upstreams, criteria, model } from '../src/upstreams.js';
import { httpHandler } from '../src/http.js';
import { configuration } from '../src/config.js';

const config = { store: 42, variant: 7, jevKey: 'server-key' };
const file = { name: 'report.pdf', fileExtension: 'pdf', byteSize: 100, createdAt: '2026-10-01T00:00:00Z', modifiedAt: '2026-10-01T00:00:00Z' };
const decision = () => ({ model, answers: { category: { type: 'choice', choice: 'Docs', confidence: 0.8,
  probabilities: Object.fromEntries(Object.keys(criteria).map(k => [k, k === 'Docs' ? 0.993 : 0.001])) } } });

test('Jev receives the exact choice options, metadata only, and the server key', async () => {
  let request;
  const upstream = upstreams(config, async (url, options) => { request = { url, ...options }; return Response.json(decision()); });
  const result = await upstream.classify(file);
  assert.equal(result.confidence, 0.8);
  assert.equal(request.url, 'https://api.typesafe.ai/v1/systemone');
  assert.equal(request.headers.Authorization, 'Bearer server-key');
  assert.equal(request.redirect, 'error');
  const body = JSON.parse(request.body);
  assert.deepEqual(body.state, file);
  assert.equal(body.questions.category.type, 'choice');
  assert.deepEqual(Object.keys(body.questions.category.criteria), ['Screenshots', 'Recordings', 'Videos', 'Audio', 'Images', 'Docs', 'Code', 'Other']);
});

test('malformed model responses and upstream failures are rejected', async () => {
  const cases = [v => v.model = 'different-model', v => v.answers.category.confidence = 1.1,
    v => v.answers.category.choice = 'Injected/path', v => v.answers.category.probabilities.Docs = 0.1,
    v => delete v.answers.category.probabilities.Audio, v => v.answers.category.type = 'bool'];
  for (const change of cases) {
    const body = decision(); change(body);
    await assert.rejects(upstreams(config, async () => Response.json(body)).classify(file));
  }
  await assert.rejects(upstreams(config, async () => new Response('', { status: 503 })).classify(file));
});

test('store, variant, instance, expiry and active license must all match', () => {
  const upstream = upstreams(config);
  const value = { valid: true, activated: true, license_key: { status: 'active', expires_at: null }, instance: { id: 'instance' }, meta: { store_id: 42, variant_id: 7 } };
  assert.equal(upstream.validLicense(value, 'instance'), true);
  for (const change of [v => v.meta.store_id = 43, v => v.meta.variant_id = 8,
    v => v.license_key.status = 'disabled', v => v.instance.id = 'other',
    v => v.license_key.expires_at = '2020-01-01T00:00:00Z', v => v.valid = false]) {
    const copy = structuredClone(value); change(copy);
    assert.equal(upstream.validLicense(copy, 'instance'), false);
  }
});

test('metadata cannot contain file contents, paths, arbitrary objects or oversized fields', () => {
  assert.deepEqual(metadata(file), file);
  for (const value of [{ ...file, contents: 'secret' }, { ...file, name: '../report.pdf' },
    { ...file, name: 'x'.repeat(1025) }, { ...file, byteSize: -1 }, { ...file, createdAt: 'invalid' },
    { ...file, mimeType: {} }, null]) assert.throws(() => metadata(value));
});

test('HTTP errors are sanitized, bodies are bounded, and responses cannot be cached', async t => {
  const server = createServer(httpHandler(async () => { throw new Error('SECRET vendor key filename'); }));
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => { server.closeAllConnections(); server.close(); });
  const url = `http://127.0.0.1:${server.address().port}/v1/classify`;
  const response = await fetch(url);
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { code: 'service_unavailable' });
  const oversized = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ data: 'x'.repeat(9000) }) });
  assert.equal(oversized.status, 413);
  const malformed = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{' });
  assert.equal(malformed.status, 400);
});

test('missing Stripe configuration, mixed modes and unsafe service URLs fail closed', () => {
  assert.throws(() => configuration({}));
  const env = { DATABASE_URL: 'postgres://localhost/test', TYPESAFE_API_KEY: 'secret', IDENTITY_HASH_KEY: 'x'.repeat(64),
    STRIPE_SECRET_KEY: 'sk_test_fake', STRIPE_PRICE_ID: 'price_test', STRIPE_MODE: 'test', SERVICE_ORIGIN: 'https://api.shapedesk.test', MONTHLY_CHECK_LIMIT: '1000' };
  assert.equal(configuration(env).limit, 1000);
  assert.throws(() => configuration({ ...env, SERVICE_ORIGIN: 'http://untrusted.test' }));
  assert.throws(() => configuration({ ...env, STRIPE_MODE: 'live' }));
  assert.throws(() => configuration({ ...env, CHECKOUT_ENABLED: 'true' }));
  assert.throws(() => configuration({ ...env, MONTHLY_CHECK_LIMIT: '-1' }));
  assert.throws(() => configuration({ ...env, STRIPE_SECRET_KEY: 'sk_test_****masked' }));
  const withoutBilling = { ...env, STRIPE_SECRET_KEY: undefined, STRIPE_PRICE_ID: undefined };
  assert.equal(configuration(withoutBilling).checkoutEnabled, false);
  assert.throws(() => configuration({ ...withoutBilling, CHECKOUT_ENABLED: 'true' }));
});
