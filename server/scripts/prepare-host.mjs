import { readFileSync, writeFileSync, cpSync, chmodSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';

process.umask(0o077);
const mode = process.argv[2];
if (!['test', 'live'].includes(mode)) throw new Error('Supply test or live');
const root = fileURLToPath(new URL('../../', import.meta.url));
const server = resolve(root, 'server');
const target = mode === 'test' ? resolve(root, 'build/staging-service') : server;
const configPath = resolve(server, `.env.${mode}.local`);
const env = parseEnv(readFileSync(configPath, 'utf8'));
const database = parseEnv(readFileSync(mode === 'test' ? resolve(target, '.env.database.local') : resolve(server, '.env.production.local'), 'utf8'));
const connection = new URL(database.DATABASE_URL); connection.searchParams.set('sslmode', 'verify-full');
env.DATABASE_URL = connection.href;
writeFileSync(configPath, Object.entries(env).map(([k,v]) => `${k}=${JSON.stringify(v)}`).join('\n')+'\n', { mode: 0o600 });
chmodSync(configPath, 0o600);
if (mode === 'test') {
  for (const name of ['src', 'api', 'package.json', 'package-lock.json', 'vercel.json', '.vercelignore', 'schema.sql']) {
    cpSync(resolve(server, name), resolve(target, name), { recursive: true });
  }
}
for (const [name, value] of Object.entries(env)) {
  const secret = /KEY|SECRET|DATABASE_URL/.test(name);
  try {
    execFileSync('vercel', ['env', 'add', name, 'production', '--cwd', target, '--scope', 'groks1',
      '--force', '--yes', secret ? '--sensitive' : '--no-sensitive'], { input: value, stdio: ['pipe', 'pipe', 'pipe'] });
    console.log(`Configured ${name}`);
  } catch { console.error(`Could not configure ${name}`); process.exit(1); }
}
console.log(`Private ${mode} configuration prepared.`);
