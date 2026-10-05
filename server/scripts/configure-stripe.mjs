// Provision only ShapeDesk-owned catalog objects. No charges, payouts, or customer messages.
import Stripe from 'stripe';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseEnv } from 'node:util';
import { randomBytes } from 'node:crypto';

process.umask(0o077);
const mode = process.argv[2], origin = process.argv[3];
if (!['test', 'live'].includes(mode) || !origin?.startsWith('https://')) throw new Error('Supply test/live and the HTTPS service origin');
const output = new URL(`../.env.${mode}.local`, import.meta.url);
const base = parseEnv(readFileSync(new URL('../.env', import.meta.url), 'utf8'));
const prior = existsSync(output) ? parseEnv(readFileSync(output, 'utf8')) : {};
let profile = '', values = {};
for (const line of readFileSync(join(homedir(), '.config/stripe/config.toml'), 'utf8').split('\n')) {
  const section = line.match(/^\[([^\]]+)\]/); if (section) profile = section[1];
  const entry = line.match(/^([a-z_]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/);
  if (profile === 'default' && entry) values[entry[1]] = entry[2] ?? entry[3];
}
const key = mode === 'live' && base.STRIPE_SECRET_KEY ? base.STRIPE_SECRET_KEY : values[`${mode}_mode_api_key`];
if (!key) throw new Error('Stripe credential missing');
const stripe = new Stripe(key, { apiVersion: '2025-02-24.acacia', timeout: 15000, maxNetworkRetries: 1 });
try {
  const products = await stripe.products.list({ limit: 100, active: true });
  let product = products.data.find(p => p.metadata.shapedesk_product === 'pro-v1');
  product ??= await stripe.products.create({ name: 'ShapeDesk Pro',
    description: 'AI file sorting for Mac. 1,000 AI checks per UTC calendar month, shared across up to 3 Macs. Unused checks do not roll over. Cancel future renewals anytime.',
    metadata: { shapedesk_product: 'pro-v1' } }, { idempotencyKey: 'shapedesk-pro-product-v1' });
  const prices = await stripe.prices.list({ product: product.id, active: true, limit: 100 });
  let price = prices.data.find(p => p.unit_amount === 500 && p.currency === 'usd' && p.recurring?.interval === 'month' && p.recurring.interval_count === 1);
  price ??= await stripe.prices.create({ product: product.id, currency: 'usd', unit_amount: 500,
    recurring: { interval: 'month' }, lookup_key: 'shapedesk_pro_monthly_5_usd_v1',
    metadata: { shapedesk_product: 'pro-v1' } }, { idempotencyKey: `shapedesk-pro-price-${product.id}-v1` });
  const portals = await stripe.billingPortal.configurations.list({ limit: 100 });
  let portal = portals.data.find(p => p.metadata?.shapedesk_product === 'pro-v1');
  portal ??= await stripe.billingPortal.configurations.create({
    business_profile: { headline: 'Manage your ShapeDesk Pro subscription' },
    features: { payment_method_update: { enabled: true }, invoice_history: { enabled: true },
      subscription_cancel: { enabled: true, mode: 'at_period_end' },
      customer_update: { enabled: true, allowed_updates: ['email', 'address'] } },
    default_return_url: `${origin}/billing/return`, metadata: { shapedesk_product: 'pro-v1' }
  }, { idempotencyKey: 'shapedesk-pro-portal-v1' });
  const endpoints = await stripe.webhookEndpoints.list({ limit: 100 });
  let webhook = endpoints.data.find(w => w.url === `${origin}/v1/webhooks/stripe`);
  let webhookSecret = prior.STRIPE_WEBHOOK_SECRET;
  if (!webhook) {
    webhook = await stripe.webhookEndpoints.create({ url: `${origin}/v1/webhooks/stripe`, api_version: '2025-02-24.acacia',
      enabled_events: ['checkout.session.completed', 'checkout.session.async_payment_succeeded',
        'customer.subscription.created', 'customer.subscription.updated', 'customer.subscription.deleted',
        'customer.subscription.paused', 'customer.subscription.resumed', 'invoice.paid', 'invoice.payment_failed',
        'charge.dispute.created', 'charge.refunded'],
      description: 'ShapeDesk Pro subscription access', metadata: { shapedesk_product: 'pro-v1' }
    }, { idempotencyKey: `shapedesk-webhook-${mode}-v1` });
    webhookSecret = webhook.secret;
  }
  if (!webhookSecret) throw new Error('Existing webhook secret is missing from the private environment file');
  let automaticTax = false;
  if (mode === 'live') {
    const tax = await stripe.tax.settings.retrieve().catch(() => null);
    automaticTax = tax?.status === 'active';
  }
  const result = { ...prior, TYPESAFE_API_KEY: base.TYPESAFE_API_KEY,
    IDENTITY_HASH_KEY: prior.IDENTITY_HASH_KEY ?? randomBytes(32).toString('hex'),
    STRIPE_SECRET_KEY: key, STRIPE_PRICE_ID: price.id, STRIPE_WEBHOOK_SECRET: webhookSecret,
    STRIPE_PORTAL_CONFIGURATION_ID: portal.id, STRIPE_MODE: mode, SERVICE_ORIGIN: origin,
    MONTHLY_CHECK_LIMIT: '1000', DEVICE_LIMIT: '3', CHECKOUT_ENABLED: 'true',
    STRIPE_AUTOMATIC_TAX: String(automaticTax) };
  writeFileSync(output, Object.entries(result).map(([k,v]) => `${k}=${JSON.stringify(v)}`).join('\n')+'\n', { mode: 0o600 });
  console.log(JSON.stringify({ mode, productID: product.id, priceID: price.id, portalID: portal.id,
    webhookID: webhook.id, automaticTax, credentialExpires: values[`${mode}_mode_key_expires_at`] ?? 'user-managed',
    privateEnvironmentSaved: true }));
} catch (error) {
  console.error(JSON.stringify({ setupFailed: true, type: error.type ?? 'configuration', code: error.code ?? null,
    parameter: error.param ?? null }));
  process.exitCode = 1;
}
