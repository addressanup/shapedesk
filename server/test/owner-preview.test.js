import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ownerService } from '../src/owner-service.js';

const token = 'a'.repeat(64), instanceID = randomUUID(), port = 18787;
const file = { name: 'report.pdf', fileExtension: 'pdf', byteSize: 100,
  createdAt: '2026-10-01T00:00:00Z', modifiedAt: '2026-10-01T00:00:00Z' };
const decision = { category: 'Docs', confidence: 0.9, model: 'jev-1.13.0' };
function request(id = randomUUID(), metadata = file) {
  return { method: 'POST', url: '/v1/classify', body: { requestID: id, metadata },
    headers: { host: `127.0.0.1:${port}`, authorization: `Bearer ${token}`, 'x-shapedesk-instance': instanceID },
    socket: { remoteAddress: '127.0.0.1' } };
}
function setup(t, options = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'shapedesk-owner-test-'));
  const config = { token, instanceID, port, databasePath: join(directory, 'usage.sqlite'),
    classify: async () => decision, ...options };
  let service = ownerService(config);
  t.after(() => { service.close(); rmSync(directory, { recursive: true, force: true }); });
  return { handle: r => service.handle(r), restart() { service.close(); service = ownerService(config); } };
}
const code = expected => error => error.code === expected;

test('owner preview authenticates every call and rejects browser, remote and rebound hosts', async t => {
  let calls = 0;
  const service = setup(t, { classify: async () => { calls++; return decision; } });
  for (const modify of [r => delete r.headers.authorization, r => r.headers.authorization = 'Bearer wrong',
    r => r.headers['x-shapedesk-instance'] = randomUUID(), r => r.headers.origin = 'https://hostile.test',
    r => r.headers.referer = 'https://hostile.test', r => r.headers.host = 'hostile.test',
    r => r.socket.remoteAddress = '192.168.1.1']) {
    const r = request(); modify(r); await assert.rejects(service.handle(r));
  }
  assert.equal(calls, 0);
  const r = request(); r.method = 'GET'; r.url = '/v1/plans';
  await assert.rejects(service.handle(r), code('not_found'));
});

test('owner replay survives restart, preserves strict confidence and does not spend twice', async t => {
  let calls = 0;
  const service = setup(t, { limit: 1, classify: async () => { calls++; return { ...decision, confidence: 0.8 }; } });
  const r = request();
  const first = await service.handle(r);
  assert.equal(first.confidence, 0.8);
  assert.equal(first.entitlement.used, 1);
  service.restart();
  assert.deepEqual(await service.handle(r), first);
  assert.equal(calls, 1);
  await assert.rejects(service.handle(request()), code('quota_exhausted'));
  await assert.rejects(service.handle(request(r.body.requestID, { ...file, name: 'changed.pdf' })), code('idempotency_conflict'));
});

test('concurrent owner requests reserve quota before contacting Jev and reuse pending IDs', async t => {
  let finish;
  const gate = new Promise(resolve => { finish = resolve; });
  const service = setup(t, { limit: 1, classify: async () => { await gate; return decision; } });
  const r = request(), first = service.handle(r);
  await assert.rejects(service.handle(r), code('pending'));
  await assert.rejects(service.handle(request()), code('quota_exhausted'));
  finish();
  assert.equal((await first).entitlement.used, 1);
});

test('owner upstream errors are sanitized, refunded and cannot rerun the same failed ID', async t => {
  let calls = 0;
  const service = setup(t, { limit: 1, classify: async () => {
    if (++calls === 1) throw new Error('secret metadata or API key');
    return decision;
  } });
  const r = request();
  await assert.rejects(service.handle(r), error => error.message === 'check_failed');
  await assert.rejects(service.handle(r), code('check_failed'));
  assert.equal((await service.handle(request())).entitlement.used, 1);
  assert.equal(calls, 2);
});

test('owner monthly allowance resets and validates metadata before contacting Jev', async t => {
  let now = new Date('2026-10-31T23:59:59Z');
  const service = setup(t, { limit: 1, clock: () => now });
  await assert.rejects(service.handle(request(undefined, { ...file, contents: 'not allowed' })), code('invalid_metadata'));
  assert.equal((await service.handle(request())).entitlement.resetsAt, '2026-11-01T00:00:00.000Z');
  now = new Date('2026-11-01T00:00:01Z');
  assert.equal((await service.handle(request())).entitlement.used, 1);
});

test('abandoned owner reservations recover without repeating uncertain upstream work', async t => {
  let now = new Date('2026-10-05T00:00:00Z'), finish;
  const gate = new Promise(resolve => { finish = resolve; });
  const service = setup(t, { limit: 1, clock: () => now, classify: async () => { await gate; return decision; } });
  const r = request(), pending = service.handle(r);
  now = new Date(now.getTime() + 90001);
  const usage = request(); usage.method = 'GET'; usage.url = '/v1/entitlement';
  assert.equal((await service.handle(usage)).used, 0);
  finish();
  await assert.rejects(pending, code('check_failed'));
  await assert.rejects(service.handle(r), code('check_failed'));
});
