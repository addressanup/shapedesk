import { createHmac, randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { fail } from './errors.js';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const couponPattern = /^[A-Z0-9][A-Z0-9-]{0,62}[A-Z0-9]$/;
const sessionHours = 12;
const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // No I, L, O, 0 or 1: unambiguous when read aloud.

export function generateCouponCode(random = randomBytes) {
  const chars = [...random(12)].map(byte => alphabet[byte % alphabet.length]).join('');
  return `SD-${chars.slice(0, 4)}-${chars.slice(4, 8)}-${chars.slice(8, 12)}`;
}

export function normalizeCoupon(value) {
  if (typeof value !== 'string') return '';
  const clean = value.trim().toUpperCase().replace(/\s+/g, '');
  const bare = clean.replaceAll('-', '');
  // Typed without dashes is still the same code.
  if (/^SD[A-Z0-9]{12}$/.test(bare)) return `SD-${bare.slice(2, 6)}-${bare.slice(6, 10)}-${bare.slice(10, 14)}`;
  return clean;
}

const couponJSON = row => ({
  code: row.code, grantDays: row.grant_days, maxRedemptions: row.max_redemptions,
  redeemed: row.redeemed, active: row.active, note: row.note,
  createdAt: new Date(row.created_at).toISOString(),
  expiresAt: row.expires_at ? new Date(row.expires_at).toISOString() : null
});
const active = (row, now) => !row?.suspended && row?.status === 'active' && new Date(row.valid_until) > now;

/// The superadmin API. A single operator identity lives in the environment;
/// sessions are 12-hour bearer tokens stored only as HMAC hashes. Every
/// mutation is written to admin_audit. Returns null when unconfigured.
export function adminService({ db, config, clock = () => new Date() }) {
  if (!config.adminUser || !config.adminPassword) return null;
  const hash = (kind, value) => createHmac('sha256', config.hashKey).update(`${kind}:${value}`).digest('hex');
  const ipOf = request => request.headers['x-vercel-forwarded-for'] || request.socket?.remoteAddress || 'unknown';
  const period = () => clock().toISOString().slice(0, 7) + '-01';

  function passwordOK(password) {
    const parts = config.adminPassword.split(':');
    if (parts.length !== 6 || parts[0] !== 'scrypt') return false;
    const [, N, r, p, salt, expectedHex] = parts;
    const expected = Buffer.from(expectedHex, 'hex');
    if (!/^[0-9a-f]+$/.test(salt) || !expected.length) return false;
    try {
      const derived = scryptSync(password, Buffer.from(salt, 'hex'), expected.length,
        { N: Number(N), r: Number(r), p: Number(p), maxmem: 256 * 1024 * 1024 });
      return timingSafeEqual(derived, expected);
    } catch { return false; }
  }

  const audit = (action, target = '', detail = {}) =>
    db.pool.query('INSERT INTO admin_audit(action, target, detail) VALUES ($1, $2, $3)', [action, target, detail]);

  async function login(request) {
    const { username, password } = request.body ?? {};
    await db.rate(`admin-login:${hash('ip', ipOf(request))}`, 10, 60);
    if (typeof username !== 'string' || username.length > 128 ||
        typeof password !== 'string' || !password.length || password.length > 256) fail(400, 'invalid_request');
    // Same shape for every comparison: length never leaks, scrypt always runs.
    const pad = value => value.padEnd(64, ' ').slice(0, 64);
    const userOK = timingSafeEqual(Buffer.from(pad(username)), Buffer.from(pad(config.adminUser)));
    if (!userOK || !passwordOK(password)) fail(401, 'admin_auth');
    const token = randomBytes(32).toString('hex');
    await db.pool.query('DELETE FROM admin_sessions WHERE expires_at <= now()');
    // Expiry lives on database time so a skewed app clock cannot strand sessions.
    const { rows } = await db.pool.query(`INSERT INTO admin_sessions(token, expires_at)
      VALUES ($1, now() + $2 * interval '1 hour') RETURNING expires_at`, [hash('admin', token), sessionHours]);
    await audit('admin_login');
    return { token, expiresAt: new Date(rows[0].expires_at).toISOString() };
  }

  async function authenticate(request) {
    const token = request.headers.authorization?.match(/^Bearer ([0-9a-f]{64})$/)?.[1];
    if (!token) fail(401, 'admin_auth');
    const { rows } = await db.pool.query(`UPDATE admin_sessions SET last_used_at =
      CASE WHEN last_used_at <= now() - interval '60 seconds' THEN now() ELSE last_used_at END
      WHERE token = $1 AND expires_at > now() RETURNING token`, [hash('admin', token)]);
    if (!rows[0]) fail(401, 'admin_auth');
    return rows[0].token;
  }

  async function overview() {
    const [licenses, subs, devices, used, coupons, redemptions, suspended] = await Promise.all([
      db.pool.query('SELECT count(*)::int AS n FROM licenses'),
      db.pool.query(`SELECT kind, count(*)::int AS n,
          count(*) FILTER (WHERE NOT suspended AND status = 'active' AND valid_until > now())::int AS live
        FROM subscriptions GROUP BY kind`),
      db.pool.query('SELECT count(*)::int AS n FROM devices WHERE active'),
      db.pool.query('SELECT coalesce(sum(used), 0)::int AS n FROM usage WHERE period = $1', [period()]),
      db.pool.query('SELECT count(*)::int AS n FROM coupons WHERE active'),
      db.pool.query(`SELECT count(*)::int AS n FROM coupon_redemptions WHERE redeemed_at > now() - interval '7 days'`),
      db.pool.query('SELECT count(*)::int AS n FROM subscriptions WHERE suspended')
    ]);
    const byKind = Object.fromEntries(subs.rows.map(row => [row.kind, row]));
    const total = subs.rows.reduce((sum, row) => sum + row.n, 0);
    const live = subs.rows.reduce((sum, row) => sum + row.live, 0);
    return {
      accounts: licenses.rows[0].n,
      subscriptions: { total, active: live,
        stripe: byKind.stripe ?? { n: 0, live: 0 }, coupon: byKind.coupon ?? { n: 0, live: 0 },
        owner: byKind.owner ?? { n: 0, live: 0 } },
      suspended: suspended.rows[0].n,
      devices: devices.rows[0].n,
      checksThisMonth: used.rows[0].n,
      activeCoupons: coupons.rows[0].n,
      redemptionsThisWeek: redemptions.rows[0].n
    };
  }

  async function accounts(url) {
    const query = (url.searchParams.get('q') ?? '').trim().toLowerCase();
    if (query && !/^[0-9a-f]{1,64}$/.test(query)) fail(400, 'invalid_request');
    const limit = Math.min(50, Math.max(1, Number(url.searchParams.get('limit')) || 25));
    const offset = Math.max(0, Number(url.searchParams.get('offset')) || 0);
    const { rows } = await db.pool.query(`SELECT l.id, l.created_at, s.kind, s.status, s.valid_until, s.suspended,
        (SELECT count(*)::int FROM devices d WHERE d.license_id = l.id AND d.active) AS devices,
        (SELECT used FROM usage u WHERE u.license_id = l.id AND u.period = $1) AS used,
        (SELECT max(d2.last_seen_at) FROM devices d2 WHERE d2.license_id = l.id) AS last_seen
      FROM licenses l LEFT JOIN subscriptions s ON s.license_id = l.id
      WHERE ($2::text = '' OR l.id LIKE $2 || '%')
      ORDER BY l.created_at DESC, l.id LIMIT $3 OFFSET $4`, [period(), query, limit + 1, offset]);
    const now = clock();
    return {
      accounts: rows.slice(0, limit).map(row => ({
        id: row.id, createdAt: new Date(row.created_at).toISOString(),
        kind: row.kind ?? null, status: row.status ?? null,
        active: row.kind ? active(row, now) : false,
        suspended: row.suspended ?? false,
        validUntil: row.valid_until ? new Date(row.valid_until).toISOString() : null,
        devices: row.devices, used: row.used ?? 0,
        lastSeenAt: row.last_seen ? new Date(row.last_seen).toISOString() : null
      })),
      next: rows.length > limit ? offset + limit : null
    };
  }

  async function account(id) {
    const license = (await db.pool.query('SELECT id, created_at FROM licenses WHERE id = $1', [id])).rows[0];
    if (!license) fail(404, 'not_found');
    const [sub, devices, usageRows, redemptions, attempt, checkCounts] = await Promise.all([
      db.pool.query('SELECT * FROM subscriptions WHERE license_id = $1', [id]),
      db.pool.query(`SELECT device_id, instance_id, active, checked_at, expires_at, last_seen_at
        FROM devices WHERE license_id = $1 ORDER BY checked_at`, [id]),
      db.pool.query('SELECT period, used FROM usage WHERE license_id = $1 ORDER BY period DESC LIMIT 4', [id]),
      db.pool.query(`SELECT coupon, device_id, redeemed_at FROM coupon_redemptions WHERE license_id = $1
        ORDER BY redeemed_at DESC LIMIT 50`, [id]),
      db.pool.query(`SELECT device_id, completed, session_id IS NOT NULL AS started, created_at
        FROM checkout_attempts WHERE license_id = $1`, [id]),
      db.pool.query(`SELECT status, count(*)::int AS n FROM checks WHERE license_id = $1 AND period = $2
        GROUP BY status`, [id, period()])
    ]);
    const row = sub.rows[0] ?? null;
    return {
      id, createdAt: new Date(license.created_at).toISOString(),
      subscription: row ? {
        kind: row.kind, status: row.status, suspended: row.suspended,
        active: active(row, clock()),
        validUntil: new Date(row.valid_until).toISOString(),
        checkedAt: new Date(row.checked_at).toISOString(),
        stripeCustomer: row.customer_id, stripeSubscription: row.subscription_id
      } : null,
      devices: devices.rows.map(d => ({
        device: d.device_id, instance: d.instance_id, active: d.active,
        activatedAt: new Date(d.checked_at).toISOString(),
        expiresAt: d.expires_at ? new Date(d.expires_at).toISOString() : null,
        lastSeenAt: d.last_seen_at ? new Date(d.last_seen_at).toISOString() : null
      })),
      usage: usageRows.rows.map(u => ({ period: u.period.toISOString?.().slice(0, 10) ?? u.period, used: u.used })),
      redemptions: redemptions.rows.map(r => ({
        coupon: r.coupon, device: r.device_id, redeemedAt: new Date(r.redeemed_at).toISOString()
      })),
      checkout: attempt.rows[0]
        ? { completed: attempt.rows[0].completed, started: attempt.rows[0].started,
            createdAt: new Date(attempt.rows[0].created_at).toISOString() }
        : null,
      checksThisMonth: Object.fromEntries(checkCounts.rows.map(c => [c.status, c.n]))
    };
  }

  async function requireLicense(id) {
    if (!/^[0-9a-f]{64}$/.test(id)) fail(404, 'not_found');
    const { rowCount } = await db.pool.query('SELECT 1 FROM licenses WHERE id = $1', [id]);
    if (!rowCount) fail(404, 'not_found');
  }

  async function grant(id, body) {
    const days = body?.days;
    if (!Number.isInteger(days) || days < 1 || days > 3650) fail(400, 'invalid_request');
    await requireLicense(id);
    const result = await db.withLicense(id, async q => {
      const sub = (await q('SELECT * FROM subscriptions WHERE license_id = $1 FOR UPDATE')).rows[0];
      if (sub?.kind === 'stripe') fail(409, 'paid_subscription');
      const base = sub && new Date(sub.valid_until) > clock() ? new Date(sub.valid_until) : clock();
      const until = new Date(base.getTime() + days * 86400000);
      if (sub) await q(`UPDATE subscriptions SET kind = 'owner', status = 'active', valid_until = $2,
          checked_at = $3 WHERE license_id = $1`, [until, clock()]);
      else await q(`INSERT INTO subscriptions(license_id, kind, status, valid_until, checked_at)
        VALUES ($1, 'owner', 'active', $2, $3)`, [until, clock()]);
      return { validUntil: until.toISOString() };
    });
    await audit('grant_days', id, { days, validUntil: result.validUntil });
    return result;
  }

  async function setSuspended(id, suspended) {
    await requireLicense(id);
    await db.withLicense(id, async q => {
      const { rowCount } = await q('UPDATE subscriptions SET suspended = $2 WHERE license_id = $1', [suspended]);
      if (!rowCount) fail(404, 'not_found');
    });
    await audit(suspended ? 'account_suspended' : 'account_unsuspended', id);
    return { suspended };
  }

  async function deactivateDevices(id, body) {
    const device = body?.device;
    if (device !== 'all' && !uuid.test(device ?? '')) fail(400, 'invalid_request');
    await requireLicense(id);
    const result = await db.withLicense(id, async q => {
      const { rowCount } = device === 'all'
        ? await q('UPDATE devices SET active = false WHERE license_id = $1 AND active')
        : await q(`UPDATE devices SET active = false WHERE license_id = $1 AND active
            AND (device_id = $2::uuid OR instance_id = $2::uuid)`, [device]);
      if (!rowCount) fail(404, 'device_not_found');
      return { deactivated: true };
    });
    await audit('devices_deactivated', id, { device });
    return result;
  }

  async function setQuota(id, body) {
    const used = body?.used;
    if (!Number.isInteger(used) || used < 0 || used > 100000) fail(400, 'invalid_request');
    await requireLicense(id);
    await db.withLicense(id, q => q(`INSERT INTO usage(license_id, period, used) VALUES ($1, $2, $3)
      ON CONFLICT (license_id, period) DO UPDATE SET used = EXCLUDED.used`, [period(), used]));
    await audit('quota_set', id, { used });
    return { used };
  }

  async function coupons() {
    const { rows } = await db.pool.query('SELECT * FROM coupons ORDER BY created_at DESC, code LIMIT 200');
    return { coupons: rows.map(couponJSON) };
  }

  async function createCoupon(body) {
    const grantDays = body?.grantDays;
    const max = body?.maxRedemptions ?? 1;
    const note = body?.note ?? null;
    const expiresInput = body?.expiresAt ?? null;
    if (!Number.isInteger(grantDays) || grantDays < 1 || grantDays > 3650 ||
        !Number.isInteger(max) || max < 1 || max > 100000 ||
        (note !== null && (typeof note !== 'string' || note.length > 200)) ||
        (expiresInput !== null && !Number.isFinite(Date.parse(expiresInput)))) fail(400, 'invalid_request');
    const expiry = expiresInput ? new Date(expiresInput) : null;
    if (expiry && expiry <= clock()) fail(400, 'invalid_request');
    let code = normalizeCoupon(body?.code);
    const provided = Boolean(code);
    if (provided && !couponPattern.test(code)) fail(400, 'invalid_request');
    for (let attempt = 0; attempt < 5; attempt++) {
      if (!provided) code = generateCouponCode();
      const { rowCount } = await db.pool.query(`INSERT INTO coupons(code, grant_days, max_redemptions, note, expires_at)
        VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING`, [code, grantDays, max, note, expiry]);
      if (rowCount) {
        await audit('coupon_created', code, { grantDays, maxRedemptions: max, expiresAt: expiry?.toISOString() ?? null, note });
        return couponJSON((await db.pool.query('SELECT * FROM coupons WHERE code = $1', [code])).rows[0]);
      }
      if (provided) fail(409, 'coupon_exists');
    }
    fail(503, 'service_unavailable');
  }

  async function setCouponState(code, couponActive) {
    const normalized = normalizeCoupon(code);
    const { rowCount } = await db.pool.query('UPDATE coupons SET active = $2 WHERE code = $1', [normalized, couponActive]);
    if (!rowCount) fail(404, 'not_found');
    await audit(couponActive ? 'coupon_activated' : 'coupon_revoked', normalized);
    return { code: normalized, active: couponActive };
  }

  async function redemptions(code) {
    const normalized = normalizeCoupon(code);
    const { rows } = await db.pool.query(`SELECT license_id, device_id, redeemed_at FROM coupon_redemptions
      WHERE coupon = $1 ORDER BY redeemed_at DESC LIMIT 200`, [normalized]);
    return { code: normalized, redemptions: rows.map(r => ({
      account: r.license_id, device: r.device_id, redeemedAt: new Date(r.redeemed_at).toISOString()
    })) };
  }

  async function auditLog(url) {
    const limit = Math.min(200, Math.max(1, Number(url.searchParams.get('limit')) || 100));
    const { rows } = await db.pool.query('SELECT id, at, action, target, detail FROM admin_audit ORDER BY id DESC LIMIT $1', [limit]);
    return { audit: rows.map(r => ({
      id: Number(r.id), at: new Date(r.at).toISOString(), action: r.action, target: r.target, detail: r.detail
    })) };
  }

  return async function handle(request) {
    const url = new URL(request.url, 'https://api.shapedesk.space');
    const path = url.pathname;
    const method = request.method;
    if (method === 'POST' && path === '/v1/admin/session') return login(request);
    await db.rate(`admin:${hash('ip', ipOf(request))}`, 120, 60);
    const session = await authenticate(request);
    if (method === 'DELETE' && path === '/v1/admin/session') {
      await db.pool.query('DELETE FROM admin_sessions WHERE token = $1', [session]);
      await audit('admin_logout');
      return { ended: true };
    }
    const seg = path.slice('/v1/admin/'.length).split('/');
    if (method === 'GET' && path === '/v1/admin/overview') return overview();
    if (method === 'GET' && path === '/v1/admin/audit') return auditLog(url);
    if (seg[0] === 'accounts') {
      if (seg.length === 1 && method === 'GET') return accounts(url);
      const id = seg[1] ?? '';
      if (seg.length === 2 && method === 'GET') return account(id);
      if (seg.length !== 3 || method !== 'POST') fail(404, 'not_found');
      if (seg[2] === 'grant') return grant(id, request.body);
      if (seg[2] === 'suspend') return setSuspended(id, true);
      if (seg[2] === 'unsuspend') return setSuspended(id, false);
      if (seg[2] === 'deactivate-devices') return deactivateDevices(id, request.body);
      if (seg[2] === 'quota') return setQuota(id, request.body);
      fail(404, 'not_found');
    }
    if (seg[0] === 'coupons') {
      if (seg.length === 1) {
        if (method === 'GET') return coupons();
        if (method === 'POST') return createCoupon(request.body);
      }
      if (seg.length === 2 && method === 'GET' && seg[1]) {
        return { coupon: couponJSON((await db.pool.query('SELECT * FROM coupons WHERE code = $1', [normalizeCoupon(seg[1])])).rows[0] ?? fail(404, 'not_found')) };
      }
      if (seg.length === 3 && method === 'GET' && seg[2] === 'redemptions') return redemptions(seg[1]);
      if (seg.length === 3 && method === 'POST' && seg[2] === 'revoke') return setCouponState(seg[1], false);
      if (seg.length === 3 && method === 'POST' && seg[2] === 'activate') return setCouponState(seg[1], true);
      fail(404, 'not_found');
    }
    fail(404, 'not_found');
  };
}
