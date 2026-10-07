// Generates the ADMIN_PASSWORD_HASH value for the superadmin dashboard.
// Usage: node scripts/hash-admin-password.mjs   (prompts, never echoes)
//        node scripts/hash-admin-password.mjs --password '<secret>'   (visible in shell history)
import { randomBytes, scryptSync } from 'node:crypto';
import { createInterface } from 'node:readline/promises';

let password = process.argv[2] === '--password' ? process.argv[3] : null;
if (!password) {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  password = await rl.question('Admin password (min 12 characters, input is echoed): ');
  rl.close();
}
if (typeof password !== 'string' || password.length < 12 || password.length > 256) {
  console.error('Password must be 12-256 characters.');
  process.exit(1);
}
const [N, r, p] = [32768, 8, 1];
const salt = randomBytes(16).toString('hex');
const derived = scryptSync(password, Buffer.from(salt, 'hex'), 64, { N, r, p, maxmem: 256 * 1024 * 1024 });
console.log(`ADMIN_PASSWORD_HASH=scrypt:${N}:${r}:${p}:${salt}:${derived.toString('hex')}`);
