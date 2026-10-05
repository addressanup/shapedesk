// Never print, embed in a bundle, or pass a vendor key in a process argument.
import { readFileSync, writeFileSync, mkdirSync, chmodSync, copyFileSync,
         cpSync, rmSync, existsSync, lstatSync, renameSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseEnv } from 'node:util';
import { randomBytes, randomUUID } from 'node:crypto';
import { createServer } from 'node:net';
import { execFileSync } from 'node:child_process';
import { setTimeout } from 'node:timers/promises';

process.umask(0o077);
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const support = join(homedir(), 'Library/Application Support/ShapeDesk/OwnerPreview');
const label = 'com.shapedesk.owner-preview';
const domain = `gui/${process.getuid()}`;
function privateDirectory(path) {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  const info = lstatSync(path);
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid()) throw new Error('Unsafe private directory');
  chmodSync(path, 0o700);
}
function privateWrite(path, data) {
  const temporary = path + '.' + randomUUID() + '.tmp';
  writeFileSync(temporary, data, { mode: 0o600, flag: 'wx' });
  renameSync(temporary, path);
}
function launchctl(args, optional = false) {
  try { execFileSync('/bin/launchctl', args, { stdio: 'pipe' }); }
  catch (error) { if (!optional) throw new Error('Could not start the local LaunchAgent'); }
}
try {
  const source = join(root, 'server/.env');
  const sourceInfo = lstatSync(source);
  if (!sourceInfo.isFile() || sourceInfo.isSymbolicLink() || sourceInfo.uid !== process.getuid() ||
      (sourceInfo.mode & 0o077)) throw new Error('server/.env must be a private owner-only file');
  const key = parseEnv(readFileSync(source, 'utf8')).TYPESAFE_API_KEY;
  if (!key || /\s/.test(key)) throw new Error('A Jev key is required in server/.env');
  privateDirectory(support);
  privateDirectory(join(support, 'src'));
  const clientPath = join(support, 'client.json');
  let client;
  if (existsSync(clientPath)) {
    const info = lstatSync(clientPath);
    if (!info.isFile() || info.isSymbolicLink() || info.uid !== process.getuid() || (info.mode & 0o077)) throw new Error('Unsafe preview credentials');
    client = JSON.parse(readFileSync(clientPath, 'utf8'));
  } else {
    const socket = createServer();
    await new Promise((yes, no) => { socket.once('error', no); socket.listen(0, '127.0.0.1', yes); });
    const port = socket.address().port;
    await new Promise(yes => socket.close(yes));
    client = { baseURL: `http://127.0.0.1:${port}`,
      credentials: { licenseKey: randomBytes(32).toString('hex'), instanceID: randomUUID() } };
  }
  const url = new URL(client.baseURL), token = client.credentials?.licenseKey, instance = client.credentials?.instanceID;
  if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port ||
      url.username || url.password || url.search || url.hash || url.pathname !== '/' ||
      !/^[0-9a-f]{64}$/.test(token) || !/^[0-9a-f-]{36}$/i.test(instance)) throw new Error('Invalid preview credentials');
  const port = Number(url.port);
  launchctl(['bootout', `${domain}/${label}`], true);
  privateWrite(clientPath, JSON.stringify(client));
  // JSON quoting is supported by Node's env-file parser; whitespace in keys is rejected above.
  privateWrite(join(support, 'backend.env'), `SHAPEDESK_OWNER_PREVIEW=1\nTYPESAFE_API_KEY=${JSON.stringify(key)}\nOWNER_PREVIEW_TOKEN=${token}\nOWNER_PREVIEW_INSTANCE=${instance}\nOWNER_PREVIEW_PORT=${port}\n`);
  privateWrite(join(support, 'package.json'), '{"type":"module","private":true}\n');
  for (const name of ['owner-preview.js', 'owner-service.js', 'http.js', 'errors.js', 'service.js', 'upstreams.js']) {
    copyFileSync(join(root, 'server/src', name), join(support, 'src', name));
    chmodSync(join(support, 'src', name), 0o600);
  }
  const agents = join(homedir(), 'Library/LaunchAgents');
  mkdirSync(agents, { recursive: true });
  const plist = join(agents, `${label}.plist`);
  const node = process.argv[2] || process.execPath;
  // plistlib handles escaping paths without exposing any credential.
  const job = { Label: label, ProgramArguments: [node, `--env-file=${join(support, 'backend.env')}`, join(support, 'src/owner-preview.js')],
    RunAtLoad: true, KeepAlive: true, ThrottleInterval: 10, WorkingDirectory: support,
    StandardOutPath: join(support, 'service.log'), StandardErrorPath: join(support, 'service-error.log') };
  const encoded = execFileSync('/usr/bin/python3', ['-c', 'import sys,json,plistlib; sys.stdout.buffer.write(plistlib.dumps(json.load(sys.stdin)))'],
    { input: JSON.stringify(job) });
  privateWrite(plist, encoded);
  launchctl(['bootstrap', domain, plist]);
  let ready = false;
  for (let i = 0; i < 30; i++) {
    try {
      const response = await fetch(`${client.baseURL}/v1/entitlement`, {
        headers: { Authorization: `Bearer ${token}`, 'X-ShapeDesk-Instance': instance },
        signal: AbortSignal.timeout(1000), redirect: 'error'
      });
      if (response.ok && (await response.json()).active === true) { ready = true; break; }
    } catch { /* wait for LaunchAgent */ }
    await setTimeout(200);
  }
  if (!ready) throw new Error('Local AI service did not become ready');
  console.log('Private local AI service is ready.');
  const app = join(homedir(), 'Applications/ShapeDesk.app');
  const executable = join(app, 'Contents/MacOS/ShapeDesk');
  const processes = execFileSync('/bin/ps', ['-axo', 'pid=,comm='], { encoding: 'utf8' });
  const running = processes.split('\n').map(line => line.trim().match(/^(\d+)\s+(.*)$/))
    .filter(match => match?.[2] === executable).map(match => Number(match[1]));
  for (const pid of running) process.kill(pid, 'SIGTERM');
  for (let i = 0; i < 50 && running.length; i++) {
    const alive = running.some(pid => { try { process.kill(pid, 0); return true; } catch { return false; } });
    if (!alive) break;
    if (i === 49) throw new Error('Close ShapeDesk before installing the preview');
    await setTimeout(100);
  }
  const stage = join(homedir(), 'Applications/ShapeDesk-owner-install.app');
  if (existsSync(stage)) rmSync(stage, { recursive: true });
  cpSync(join(root, 'build/OwnerPreview/ShapeDesk.app'), stage, { recursive: true });
  const backup = join(homedir(), 'Applications/ShapeDesk-before-owner-preview.app');
  if (existsSync(app)) {
    if (existsSync(backup)) rmSync(app, { recursive: true });
    else renameSync(app, backup);
  }
  renameSync(stage, app);
  const register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';
  if (existsSync(backup)) execFileSync(register, ['-u', backup], { stdio: 'pipe' });
  execFileSync(register, ['-f', app], { stdio: 'pipe' });
  execFileSync('/usr/bin/open', [app], { stdio: 'pipe' });
  console.log('Owner preview installed in ~/Applications/ShapeDesk.app and opened.');
} catch (error) {
  // All messages here are local, static configuration failures. Never serialize nested errors or env values.
  console.error('Owner preview setup failed. Check private file permissions, Node 24 and the local LaunchAgent.');
  process.exitCode = 1;
}
