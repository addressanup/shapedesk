// Private, single-owner preview only. The production runtime never imports this module.
import { createHmac, timingSafeEqual } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { metadata } from './service.js';
import { fail } from './errors.js';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function equal(actual, expected) {
  const a = Buffer.from(actual ?? ''), b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function ownerService({ token, instanceID, port, limit = 1000, databasePath,
                               classify, clock = () => new Date() }) {
  if (!/^[0-9a-f]{64}$/.test(token) || !uuid.test(instanceID) ||
      !Number.isInteger(port) || port < 1024 || port > 65535 ||
      !Number.isInteger(limit) || limit < 1 || limit > 10000) throw new Error('Invalid owner preview configuration');
  const db = new DatabaseSync(databasePath);
  db.exec(`PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA busy_timeout = 3000;
    CREATE TABLE IF NOT EXISTS checks (
      id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, period TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('pending','complete','failed')),
      created_ms INTEGER NOT NULL, result TEXT
    );
    CREATE INDEX IF NOT EXISTS checks_usage ON checks(period, status);`);
  const period = () => clock().toISOString().slice(0, 7) + '-01';
  function usage(month = period()) {
    const used = db.prepare("SELECT count(*) AS used FROM checks WHERE period = ? AND status != 'failed'").get(month).used;
    const reset = new Date(month + 'T00:00:00Z'); reset.setUTCMonth(reset.getUTCMonth() + 1);
    return { active: true, limit, used, resetsAt: reset.toISOString() };
  }
  function transaction(work) {
    db.exec('BEGIN IMMEDIATE');
    try { const result = work(); db.exec('COMMIT'); return result; }
    catch (error) { db.exec('ROLLBACK'); throw error; }
  }
  function recover() {
    db.prepare("UPDATE checks SET status = 'failed' WHERE status = 'pending' AND created_ms < ?")
      .run(clock().getTime() - 90000);
  }
  async function handle(request) {
    // Exact host prevents DNS rebinding. Browser-origin traffic is never accepted.
    if (request.socket?.remoteAddress !== '127.0.0.1' ||
        request.headers.host !== `127.0.0.1:${port}` ||
        request.headers.origin !== undefined || request.headers.referer !== undefined) fail(403, 'forbidden');
    if (!equal(request.headers.authorization, `Bearer ${token}`) ||
        !equal(request.headers['x-shapedesk-instance'], instanceID)) fail(401, 'inactive');
    const path = request.url;
    if (request.method === 'GET' && path === '/v1/entitlement') {
      return transaction(() => { recover(); return usage(); });
    }
    if (request.method !== 'POST' || path !== '/v1/classify') fail(404, 'not_found');
    const { requestID, metadata: input } = request.body ?? {};
    if (typeof requestID !== 'string' || !uuid.test(requestID)) fail(400, 'invalid_request');
    const file = metadata(input);
    const id = requestID.toLowerCase();
    const fingerprint = createHmac('sha256', token).update(JSON.stringify(file)).digest('hex');
    const reservation = transaction(() => {
      recover();
      const existing = db.prepare('SELECT * FROM checks WHERE id = ?').get(id);
      if (existing) {
        if (existing.fingerprint !== fingerprint) fail(409, 'idempotency_conflict');
        if (existing.status === 'pending') fail(409, 'pending');
        if (existing.status === 'failed') fail(503, 'check_failed');
        return { result: JSON.parse(existing.result) };
      }
      const month = period();
      if (usage(month).used >= limit) fail(402, 'quota_exhausted');
      db.prepare("INSERT INTO checks(id, fingerprint, period, status, created_ms) VALUES (?, ?, ?, 'pending', ?)")
        .run(id, fingerprint, month, clock().getTime());
      return { month };
    });
    if (reservation.result) return { ...reservation.result, entitlement: usage() };
    try {
      const result = await classify(file);
      const saved = db.prepare("UPDATE checks SET status = 'complete', result = ? WHERE id = ? AND status = 'pending'")
        .run(JSON.stringify(result), id);
      if (saved.changes !== 1) fail(503, 'check_failed');
      return { ...result, entitlement: usage() };
    } catch {
      db.prepare("UPDATE checks SET status = 'failed' WHERE id = ? AND status = 'pending'").run(id);
      fail(503, 'check_failed');
    }
  }
  return { handle, close: () => db.close() };
}
