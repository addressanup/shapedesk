import Stripe from 'stripe';
import { configuration } from './config.js';
import { database } from './database.js';
import { upstreams } from './upstreams.js';
import { service } from './service.js';
import { httpHandler } from './http.js';
import { stripeBilling } from './stripe-billing.js';
import { stripeWebhookHandler } from './stripe-webhook.js';
import { billingPage } from './billing-page.js';

let runtime;
export default async function dispatch(request, response) {
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Referrer-Policy', 'no-referrer');
  if (!runtime) {
    try {
      const config = configuration();
      const db = database(config.databaseURL);
      const stripe = config.stripeKey ? new Stripe(config.stripeKey, { apiVersion: '2025-02-24.acacia', timeout: 8000, maxNetworkRetries: 1 }) : null;
      const billing = stripeBilling({ config, db, stripe });
      runtime = { db, config, handle: httpHandler(service({ config, db, billing, upstream: upstreams(config) })),
        webhook: stripeWebhookHandler({ stripe, secret: config.stripeWebhook, handle: billing.webhook }) };
    } catch {
      response.writeHead(503, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      response.end(JSON.stringify({ code: 'service_unavailable' }));
      return;
    }
  }
  const path = new URL(request.url, runtime.config.origin).pathname;
  if (path === '/v1/webhooks/stripe') return runtime.webhook(request, response);
  if (request.method === 'GET' && ['/checkout/success', '/checkout/cancel', '/billing/return'].includes(path)) {
    return billingPage(path, response, runtime.config.stripeLive);
  }
  if (request.method === 'GET' && path === '/v1/health') {
    return httpHandler(async () => { await runtime.db.pool.query('SELECT 1'); return { status: 'ok', service: 'shapedesk', version: '1.1' }; })(request, response);
  }
  return runtime.handle(request, response);
}
