// Operator-only grant. This script is excluded from the deployed API and app.
import { readFileSync, writeFileSync, existsSync, chmodSync } from 'node:fs';
import { createHmac, randomBytes } from 'node:crypto';
import { configuration } from '../src/config.js';
import { database } from '../src/database.js';

process.umask(0o077);
const output = new URL('../.env.owner.local', import.meta.url);
const config = configuration();
const prior = existsSync(output) ? JSON.parse(readFileSync(output, 'utf8')) : null;
if (prior && prior.origin !== config.origin) throw new Error('Owner grant belongs to another service');
const grant = prior ?? { origin: config.origin, licenseKey: 'sd_' + randomBytes(32).toString('hex'),
  validUntil: new Date(Date.now() + 365 * 86400000).toISOString() };
// Persist proof first so a retry never creates an inaccessible grant.
writeFileSync(output, JSON.stringify(grant) + '\n', { mode: 0o600 });
chmodSync(output, 0o600);
const id = createHmac('sha256', config.hashKey).update('license:' + grant.licenseKey).digest('hex');
const db = database(config.databaseURL);
try {
  await db.withLicense(id, async q => {
    const existing = (await q('SELECT kind FROM subscriptions WHERE license_id = $1')).rows[0];
    if (existing && existing.kind !== 'owner') throw new Error('Refusing to alter paid access');
    await q(`INSERT INTO subscriptions(license_id, kind, status, valid_until)
      VALUES ($1, 'owner', 'active', $2) ON CONFLICT (license_id) DO NOTHING`, [grant.validUntil]);
  });
  console.log(JSON.stringify({ ownerAccessReady: true, origin: grant.origin, validUntil: grant.validUntil,
    keyStoredPrivately: true, monthlyLimit: config.limit }));
} catch { console.error('Owner grant failed; existing usage and subscriptions were preserved.'); process.exitCode = 1; }
finally { await db.close(); }
