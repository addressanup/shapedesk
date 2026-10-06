import { createHmac, randomUUID } from 'node:crypto';
import { fail } from './errors.js';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const identifier = value => typeof value === 'string' ? value : value?.id;

export function stripeBilling({ db, stripe, config, clock = () => new Date() }) {
  const hash = (kind, value) => createHmac('sha256', config.hashKey).update(`${kind}:${value}`).digest('hex');
  const isActive = account => !account.suspended && account.status === 'active' && new Date(account.valid_until) > clock();
  function canonical(subscription, customerID) {
    const item = subscription.items?.data?.find(item => identifier(item.price) === config.stripePrice);
    const end = subscription.current_period_end ?? item?.current_period_end;
    if (!item || item.quantity !== 1 || subscription.items.data.length !== 1 ||
        identifier(subscription.customer) !== customerID || subscription.livemode !== config.stripeLive ||
        !Number.isFinite(end)) fail(403, 'invalid_subscription');
    return { status: subscription.pause_collection ? 'paused' : subscription.status, until: new Date(end * 1000) };
  }
  async function sync(q, account) {
    if (account.kind === 'owner') return account;
    if (!stripe) fail(503, 'billing_unavailable');
    const subscription = await stripe.subscriptions.retrieve(account.subscription_id);
    const state = canonical(subscription, account.customer_id);
    const { rows } = await q(`UPDATE subscriptions SET status = $2, valid_until = $3, checked_at = $4
      WHERE license_id = $1 RETURNING *`, [state.status, state.until, clock()]);
    return rows[0];
  }
  async function account(q) {
    const { rows } = await q('SELECT * FROM subscriptions WHERE license_id = $1');
    if (!rows[0]) fail(403, 'invalid_license');
    const value = rows[0];
    if (value.kind === 'stripe' && (clock() - new Date(value.checked_at) >= 300000 || new Date(value.valid_until) <= clock())) {
      return sync(q, value);
    }
    return value;
  }
  async function activate(q, { deviceID }) {
    const value = await account(q);
    const existing = (await q('SELECT * FROM devices WHERE license_id = $1 AND device_id = $2', [deviceID])).rows[0];
    if (!existing?.active) {
      const count = (await q('SELECT count(*)::int AS count FROM devices WHERE license_id = $1 AND active')).rows[0].count;
      if (count >= config.deviceLimit) fail(403, 'device_limit');
    }
    const instanceID = existing?.instance_id ?? randomUUID();
    await q(`INSERT INTO devices(license_id, device_id, instance_id, active, checked_at, expires_at, last_seen_at)
      VALUES ($1, $2, $3, true, $4, $5, $4) ON CONFLICT (license_id, device_id)
      DO UPDATE SET active = true, checked_at = EXCLUDED.checked_at, expires_at = EXCLUDED.expires_at,
      last_seen_at = EXCLUDED.last_seen_at`,
    [deviceID, instanceID, clock(), value.valid_until]);
    return { instanceID, active: isActive(value) };
  }
  async function authorize(q, auth, allowInactive = false) {
    const device = (await q('SELECT active, last_seen_at FROM devices WHERE license_id = $1 AND instance_id = $2', [auth.instance])).rows[0];
    if (!device?.active) fail(401, 'inactive');
    if (!device.last_seen_at || clock() - new Date(device.last_seen_at) > 600000)
      await q('UPDATE devices SET last_seen_at = $3 WHERE license_id = $1 AND instance_id = $2', [auth.instance, clock()]);
    const active = isActive(await account(q));
    if (!active && !allowInactive) fail(401, 'inactive');
    return active;
  }
  async function access(q) {
    return isActive(await account(q));
  }
  async function accountPortal(q) {
    const value = await account(q);
    if (value.kind !== 'stripe') fail(409, 'billing_unavailable');
    if (!stripe) fail(503, 'billing_unavailable');
    const session = await stripe.billingPortal.sessions.create({ customer: value.customer_id,
      configuration: config.stripePortal, return_url: `${config.webOrigin}/account` });
    return { url: session.url };
  }
  async function details(q) {
    const value = (await q('SELECT kind, status, valid_until FROM subscriptions WHERE license_id = $1')).rows[0];
    return value ? { accessType: value.kind, subscriptionStatus: value.status,
      renewsAt: new Date(value.valid_until).toISOString(), canManageBilling: value.kind === 'stripe' } : {};
  }
  function plan() {
    return { monthlyLimit: config.limit, unitAmount: 500, currency: 'USD', interval: 'month',
      deviceLimit: config.deviceLimit, checkoutEnabled: config.checkoutEnabled,
      billingMode: config.stripeLive ? 'live' : 'test' };
  }
  async function portal(q, auth) {
    await authorize(q, auth, true);
    const value = await account(q);
    if (value.kind !== 'stripe') fail(409, 'billing_unavailable');
    if (!stripe) fail(503, 'billing_unavailable');
    const session = await stripe.billingPortal.sessions.create({ customer: value.customer_id,
      configuration: config.stripePortal, return_url: `${config.origin}/billing/return` });
    return { url: session.url };
  }
  async function checkout(request, complete = false) {
    const { licenseKey, deviceID } = request.body ?? {};
    if (!/^sd_[0-9a-f]{64}$/.test(licenseKey ?? '') || !uuid.test(deviceID ?? '')) fail(400, 'invalid_request');
    const ip = request.headers['x-vercel-forwarded-for'] || request.socket?.remoteAddress || 'unknown';
    await db.rate(`checkout:${hash('ip', ip)}`, 20, 60);
    const id = hash('license', licenseKey);
    return db.withLicense(id, async q => {
      let attempt = (await q('SELECT * FROM checkout_attempts WHERE license_id = $1')).rows[0];
      if (attempt && attempt.device_id !== deviceID.toLowerCase()) fail(403, 'invalid_license');
      if (complete) {
        if (!attempt?.session_id) fail(409, 'checkout_pending');
        if (!attempt.completed) await fulfill(q, attempt);
        return activate(q, { deviceID });
      }
      if (!config.checkoutEnabled || !stripe) fail(503, 'checkout_unavailable');
      if (attempt?.session_id) {
        if (attempt.completed) fail(409, 'already_subscribed');
        if (new Date(attempt.expires_at) <= clock()) fail(410, 'checkout_expired');
        return { sessionID: attempt.session_id, url: attempt.checkout_url, expiresAt: new Date(attempt.expires_at).toISOString() };
      }
      // The stable Stripe idempotency key also recovers a process crash after Stripe succeeds.
      const session = await stripe.checkout.sessions.create({ mode: 'subscription',
        // Use the account's direct Stripe Billing flow, irrespective of Managed Payments defaults.
        managed_payments: { enabled: false },
        line_items: [{ price: config.stripePrice, quantity: 1 }],
        client_reference_id: id, metadata: { shapedesk_license: id },
        subscription_data: { metadata: { shapedesk_license: id } },
        success_url: `${config.origin}/checkout/success`, cancel_url: `${config.origin}/checkout/cancel`,
        custom_text: { submit: { message: 'Includes 1,000 AI checks per UTC calendar month. Unused checks do not roll over. Cancel future renewals anytime in ShapeDesk.' } },
        ...(config.stripeAutomaticTax ? { automatic_tax: { enabled: true } } : {})
      }, { idempotencyKey: `shapedesk-checkout-${id}` });
      if (!session.url || session.livemode !== config.stripeLive) fail(503, 'checkout_unavailable');
      await q(`INSERT INTO checkout_attempts(license_id, device_id, session_id, checkout_url, expires_at)
        VALUES ($1, $2, $3, $4, $5)`, [deviceID, session.id, session.url, new Date(session.expires_at * 1000)]);
      return { sessionID: session.id, url: session.url, expiresAt: new Date(session.expires_at * 1000).toISOString() };
    });
  }
  async function fulfill(q, attempt) {
    if (!stripe) fail(503, 'billing_unavailable');
    const session = await stripe.checkout.sessions.retrieve(attempt.session_id);
    if (session.status === 'expired') fail(410, 'checkout_expired');
    if (session.status !== 'complete' || session.payment_status !== 'paid') fail(409, 'checkout_pending');
    if (session.mode !== 'subscription' || session.livemode !== config.stripeLive ||
        session.client_reference_id !== attempt.license_id || session.metadata?.shapedesk_license !== attempt.license_id ||
        !identifier(session.customer) || !identifier(session.subscription)) fail(403, 'invalid_subscription');
    const subscription = await stripe.subscriptions.retrieve(identifier(session.subscription));
    const state = canonical(subscription, identifier(session.customer));
    // Each purchase has its own secret. No email address or Stripe ID alone can activate a Mac.
    await q(`INSERT INTO subscriptions(license_id, kind, customer_id, subscription_id, status, valid_until, checked_at)
      VALUES ($1, 'stripe', $2, $3, $4, $5, $6) ON CONFLICT (license_id) DO UPDATE SET
      status = EXCLUDED.status, valid_until = EXCLUDED.valid_until, checked_at = EXCLUDED.checked_at`,
    [identifier(session.customer), subscription.id, state.status, state.until, clock()]);
    await q('UPDATE checkout_attempts SET completed = true WHERE license_id = $1');
  }
  async function webhook(event) {
    if (event.livemode !== config.stripeLive) fail(400, 'invalid_event');
    const object = event.data.object;
    let id, attempt, suspend;
    if (['checkout.session.completed', 'checkout.session.async_payment_succeeded'].includes(event.type)) {
      attempt = (await db.pool.query('SELECT * FROM checkout_attempts WHERE session_id = $1', [object.id])).rows[0];
      id = attempt?.license_id;
    } else if (event.type.startsWith('customer.subscription.')) {
      id = (await db.pool.query('SELECT license_id FROM subscriptions WHERE subscription_id = $1', [object.id])).rows[0]?.license_id;
    } else if (['invoice.paid', 'invoice.payment_failed'].includes(event.type)) {
      const sub = identifier(object.subscription ?? object.parent?.subscription_details?.subscription);
      if (sub) id = (await db.pool.query('SELECT license_id FROM subscriptions WHERE subscription_id = $1', [sub])).rows[0]?.license_id;
    } else if (event.type === 'charge.dispute.created' || (event.type === 'charge.refunded' && object.refunded)) {
      const charge = event.type === 'charge.refunded' ? object : await stripe.charges.retrieve(identifier(object.charge));
      if (charge.invoice) {
        const invoice = await stripe.invoices.retrieve(identifier(charge.invoice));
        const sub = identifier(invoice.subscription ?? invoice.parent?.subscription_details?.subscription);
        id = (await db.pool.query('SELECT license_id FROM subscriptions WHERE subscription_id = $1', [sub])).rows[0]?.license_id;
        suspend = true;
      }
    }
    if (!id) return { received: true };
    await db.withLicense(id, async q => {
      if ((await q('SELECT id FROM billing_events WHERE id = $2 AND $1::text IS NOT NULL', [event.id])).rowCount) return;
      if (attempt) {
        // An incomplete async payment is acknowledged; its success event completes access later.
        try { await fulfill(q, attempt); }
        catch (error) { if (error.code === 'checkout_pending') return; throw error; }
      } else {
        const value = (await q('SELECT * FROM subscriptions WHERE license_id = $1')).rows[0];
        await sync(q, value); // Fetch canonical Stripe state; never trust an older event snapshot.
        if (suspend) await q('UPDATE subscriptions SET suspended = true WHERE license_id = $1');
      }
      await q('INSERT INTO billing_events(id, type) SELECT $2, $3 WHERE $1::text IS NOT NULL ON CONFLICT DO NOTHING', [event.id, event.type]);
    });
    return { received: true };
  }
  return { plan, activate, authorize, details, portal, accountPortal, access, checkout, webhook };
}
