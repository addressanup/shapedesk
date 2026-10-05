// Explicit local entry point, never a fallback for a failed paid entitlement.
import { createServer } from 'node:http';
import { ownerService } from './owner-service.js';
import { upstreams } from './upstreams.js';
import { httpHandler } from './http.js';
import { fileURLToPath } from 'node:url';

process.umask(0o077);
if (process.env.VERCEL || process.env.SHAPEDESK_OWNER_PREVIEW !== '1') {
  throw new Error('Owner preview must be explicitly enabled on the local Mac');
}
const key = process.env.TYPESAFE_API_KEY;
if (!key || /\s/.test(key)) throw new Error('Owner preview requires a private Jev key');
const port = Number(process.env.OWNER_PREVIEW_PORT);
const service = ownerService({
  token: process.env.OWNER_PREVIEW_TOKEN, instanceID: process.env.OWNER_PREVIEW_INSTANCE,
  port, databasePath: fileURLToPath(new URL('../usage.sqlite', import.meta.url)),
  classify: upstreams({ jevKey: key }).classify
});
const server = createServer({ requestTimeout: 10000, headersTimeout: 5000, maxHeaderSize: 8192 }, httpHandler(service.handle));
server.maxConnections = 8;
server.listen(port, '127.0.0.1', () => console.log('ShapeDesk owner preview ready on loopback.'));
server.on('error', () => { console.error('Owner preview could not start.'); process.exit(1); });
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
  server.close(() => { service.close(); process.exit(0); });
  setTimeout(() => process.exit(0), 22000).unref();
});
