import { createHmac } from 'node:crypto';
import { fail } from './errors.js';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const text = (v, max) => typeof v === 'string' && v.length <= max && !/[\x00-\x1f\x7f]/.test(v);

export function metadata(value) {
  const keys = ['name', 'fileExtension', 'byteSize', 'contentType', 'mimeType', 'createdAt', 'modifiedAt'];
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(k => !keys.includes(k)) ||
      !text(value.name, 1024) || !value.name || /[\\/]/.test(value.name) ||
      !text(value.fileExtension, 256) || !Number.isSafeInteger(value.byteSize) || value.byteSize < 0 ||
      !['contentType', 'mimeType'].every(k => value[k] == null || text(value[k], 256)) ||
      !['createdAt', 'modifiedAt'].every(k => text(value[k], 40) && Number.isFinite(Date.parse(value[k])))) fail(400, 'invalid_metadata');
  // Canonical order makes request fingerprints stable; reject fields that could carry file content.
  return Object.fromEntries(keys.filter(k => value[k] != null).map(k => [k, value[k]]));
}

export function service({ db, upstream, config, billing, clock = () => new Date() }) {
  const hash = (kind, value) => createHmac('sha256', config.hashKey).update(`${kind}:${value}`).digest('hex');
  const period = () => clock().toISOString().slice(0, 7) + '-01';
  function credentials(request) {
    const key = request.headers.authorization?.match(/^Bearer ([^\s]{1,256})$/)?.[1];
    const instance = request.headers['x-shapedesk-instance'];
    if (!key || !uuid.test(instance ?? '')) fail(401, 'inactive');
    return { key, instance, id: hash('license', key) };
  }
  async function usage(q, active = true, usagePeriod = period()) {
    // A killed invocation never leaves a permanent quota reservation. Same request ID stays terminal.
    const stale = await q(`UPDATE checks SET status = 'failed' WHERE license_id = $1 AND status = 'pending'
      AND created_at < now() - interval '90 seconds' RETURNING period`);
    for (const row of stale.rows) await q('UPDATE usage SET used = GREATEST(0, used - 1) WHERE license_id = $1 AND period = $2', [row.period]);
    const { rows } = await q('SELECT used FROM usage WHERE license_id = $1 AND period = $2', [usagePeriod]);
    const reset = new Date(usagePeriod + 'T00:00:00Z'); reset.setUTCMonth(reset.getUTCMonth() + 1);
    return { active, limit: config.limit, used: rows[0]?.used ?? 0, resetsAt: reset.toISOString(),
      ...(billing ? await billing.details(q) : {}) };
  }
  async function authorize(q, auth) {
    if (billing) return billing.authorize(q, auth);
    const { rows } = await q('SELECT * FROM devices WHERE license_id = $1 AND instance_id = $2', [auth.instance]);
    const device = rows[0];
    if (!device?.active) fail(401, 'inactive');
    const expires = device.expires_at ? new Date(device.expires_at).getTime() : Infinity;
    if (expires > clock().getTime() && clock() - new Date(device.checked_at) < 300000) return;
    await db.rate('lemon-api', 55, 60);
    const result = await upstream.license('validate', auth.key, { instance_id: auth.instance });
    if (!upstream.validLicense(result, auth.instance)) fail(401, 'inactive');
    await q('UPDATE devices SET checked_at = $3, expires_at = $4 WHERE license_id = $1 AND instance_id = $2',
      [auth.instance, clock(), result.license_key.expires_at]);
  }
  return async function handle(request) {
    const path = new URL(request.url, 'https://api.shapedesk.space').pathname;
    const method = request.method;
    if (method === 'GET' && path === '/v1/plans' && billing) return billing.plan();
    if (method === 'GET' && path === '/v1/plans') return { checkoutURL: config.checkoutURL,
      manageURL: 'https://app.lemonsqueezy.com/my-orders', monthlyLimit: config.limit };
    // Trusted Vercel forwarding header in production, socket address in the local runner.
    const ip = request.headers['x-vercel-forwarded-for'] || request.socket?.remoteAddress || 'unknown';
    const bucket = path === '/v1/activate' ? ['activate:', 10] : path.startsWith('/v1/account') ? ['account:', 30] : ['', 180];
    await db.rate(`ip:${bucket[0]}${hash('ip', ip)}`, bucket[1], 60);
    if (billing && method === 'POST' && ['/v1/checkout', '/v1/checkout/complete'].includes(path)) {
      const complete = path.endsWith('/complete');
      const result = await billing.checkout(request, complete);
      if (!complete) return result;
      const entitlement = await handle({ method: 'GET', url: '/v1/entitlement', socket: request.socket,
        headers: { ...request.headers, authorization: `Bearer ${request.body.licenseKey}`,
          'x-shapedesk-instance': result.instanceID } });
      return { instanceID: result.instanceID, entitlement };
    }
    if (method === 'POST' && path === '/v1/activate') {
      const { licenseKey, deviceID } = request.body ?? {};
      if (!text(licenseKey, 256) || !licenseKey || /\s/.test(licenseKey) || !uuid.test(deviceID ?? '')) fail(400, 'invalid_license');
      const id = hash('license', licenseKey);
      return db.withLicense(id, async q => {
        if (billing) {
          const result = await billing.activate(q, { key: licenseKey, deviceID, id });
          return { instanceID: result.instanceID, entitlement: await usage(q, result.active) };
        }
        const { rows } = await q('SELECT * FROM devices WHERE license_id = $1 AND device_id = $2', [deviceID]);
        const existing = rows[0]?.active ? rows[0] : null;
        await db.rate('lemon-api', 55, 60);
        const result = existing
          ? await upstream.license('validate', licenseKey, { instance_id: existing.instance_id })
          : await upstream.license('activate', licenseKey, { instance_name: `ShapeDesk ${deviceID}` });
        if (!upstream.validLicense(result, existing?.instance_id, !existing) || !uuid.test(result.instance?.id ?? '')) fail(403, 'invalid_license');
        try {
          await q(`INSERT INTO devices(license_id, device_id, instance_id, active, checked_at, expires_at)
            VALUES ($1, $2, $3, true, $4, $5) ON CONFLICT (license_id, device_id) DO UPDATE
            SET instance_id = EXCLUDED.instance_id, active = true, checked_at = EXCLUDED.checked_at, expires_at = EXCLUDED.expires_at`,
          [deviceID, result.instance.id, clock(), result.license_key.expires_at]);
        } catch (error) {
          if (!existing) await upstream.license('deactivate', licenseKey, { instance_id: result.instance.id }).catch(() => {});
          throw error;
        }
        return { instanceID: result.instance.id, entitlement: await usage(q) };
      });
    }
    if (method === 'POST' && path.startsWith('/v1/account')) {
      const routes = ['/v1/account', '/v1/account/portal', '/v1/account/deactivate'];
      if (!billing || !routes.includes(path)) fail(404, 'not_found');
      const { licenseKey, device } = request.body ?? {};
      if (!text(licenseKey, 256) || !licenseKey || /\s/.test(licenseKey)) fail(400, 'invalid_license');
      const id = hash('license', licenseKey);
      const deviceHandle = row => hash('device', row.instance_id).slice(0, 32);
      const summary = async q => {
        const entitlement = await usage(q, await billing.access(q));
        const { rows } = await q(`SELECT instance_id, checked_at, last_seen_at FROM devices
          WHERE license_id = $1 AND active ORDER BY checked_at, instance_id`);
        return { ...entitlement, deviceLimit: config.deviceLimit, devices: rows.map(row => ({ id: deviceHandle(row),
          activatedAt: new Date(row.checked_at).toISOString(),
          lastSeenAt: row.last_seen_at ? new Date(row.last_seen_at).toISOString() : null })) };
      };
      if (path === '/v1/account') return db.withLicense(id, summary);
      if (path === '/v1/account/portal') return db.withLicense(id, q => billing.accountPortal(q));
      if (!/^[0-9a-f]{32}$/.test(device ?? '')) fail(400, 'invalid_request');
      return db.withLicense(id, async q => {
        await billing.access(q);
        const target = (await q('SELECT instance_id FROM devices WHERE license_id = $1 AND active')).rows
          .find(row => deviceHandle(row) === device);
        if (!target) fail(404, 'device_not_found');
        await q('UPDATE devices SET active = false WHERE license_id = $1 AND instance_id = $2', [target.instance_id]);
        return summary(q);
      });
    }
    const auth = credentials(request);
    if (method === 'POST' && path === '/v1/deactivate') {
      return db.withLicense(auth.id, async q => {
        const { rows } = await q('SELECT active FROM devices WHERE license_id = $1 AND instance_id = $2', [auth.instance]);
        if (!rows[0]) fail(401, 'inactive');
        if (billing) {
          await q('UPDATE devices SET active = false WHERE license_id = $1 AND instance_id = $2', [auth.instance]);
          return { deactivated: true };
        }
        if (rows[0].active) {
          await db.rate('lemon-api', 55, 60);
          const result = await upstream.license('deactivate', auth.key, { instance_id: auth.instance });
          if (result.deactivated !== true) fail(503, 'upstream_unavailable');
          await q('UPDATE devices SET active = false WHERE license_id = $1 AND instance_id = $2', [auth.instance]);
        }
        return { deactivated: true };
      });
    }
    if (method === 'GET' && path === '/v1/entitlement') {
      return db.withLicense(auth.id, async q => {
        if (billing) return usage(q, await billing.authorize(q, auth, true));
        await authorize(q, auth); return usage(q);
      });
    }
    if (method === 'POST' && path === '/v1/portal' && billing) {
      return db.withLicense(auth.id, q => billing.portal(q, auth));
    }
    if (method !== 'POST' || path !== '/v1/classify') fail(404, 'not_found');
    const requestID = request.body?.requestID;
    if (!uuid.test(requestID ?? '')) fail(400, 'invalid_request');
    const input = metadata(request.body?.metadata);
    const fingerprint = hash('metadata', JSON.stringify(input));
    const reserved = await db.withLicense(auth.id, async q => {
      await authorize(q, auth);
      const reservationPeriod = period();
      const entitlement = await usage(q, true, reservationPeriod);
      const { rows } = await q('SELECT * FROM checks WHERE license_id = $1 AND id = $2', [requestID]);
      if (rows[0]) {
        if (rows[0].metadata_hash !== fingerprint) fail(409, 'request_conflict');
        if (rows[0].status === 'complete') return { cached: { ...rows[0].response, entitlement } };
        fail(rows[0].status === 'pending' ? 409 : 503, rows[0].status === 'pending' ? 'pending' : 'check_failed');
      }
      if (entitlement.used >= config.limit) fail(402, 'quota_exhausted');
      await q(`INSERT INTO usage(license_id, period, used) VALUES ($1, $2, 1)
        ON CONFLICT (license_id, period) DO UPDATE SET used = usage.used + 1`, [reservationPeriod]);
      await q(`INSERT INTO checks(license_id, id, metadata_hash, period, status) VALUES ($1, $2, $3, $4, 'pending')`,
        [requestID, fingerprint, reservationPeriod]);
      return { cached: null };
    });
    if (reserved.cached) return reserved.cached;
    try {
      const decision = await upstream.classify(input);
      return await db.withLicense(auth.id, async q => {
        const { rowCount } = await q(`UPDATE checks SET status = 'complete', response = $3
          WHERE license_id = $1 AND id = $2 AND status = 'pending'`, [requestID, decision]);
        if (rowCount !== 1) fail(503, 'check_failed');
        return { ...decision, entitlement: await usage(q) };
      });
    } catch {
      const recovered = await db.withLicense(auth.id, async q => {
        // A database COMMIT may succeed even if its acknowledgment was lost.
        const existing = await q('SELECT status, response FROM checks WHERE license_id = $1 AND id = $2', [requestID]);
        if (existing.rows[0]?.status === 'complete') return { ...existing.rows[0].response, entitlement: await usage(q) };
        const { rows } = await q(`UPDATE checks SET status = 'failed' WHERE license_id = $1 AND id = $2
          AND status = 'pending' RETURNING period`, [requestID]);
        if (rows[0]) await q('UPDATE usage SET used = GREATEST(0, used - 1) WHERE license_id = $1 AND period = $2', [rows[0].period]);
      });
      if (recovered) return recovered;
      fail(503, 'check_failed');
    }
  };
}
