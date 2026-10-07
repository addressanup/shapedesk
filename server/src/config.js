export function configuration(env = process.env) {
  for (const name of ['DATABASE_URL', 'TYPESAFE_API_KEY', 'IDENTITY_HASH_KEY', 'STRIPE_MODE', 'SERVICE_ORIGIN']) {
    if (!env[name]) throw new Error(`Missing server configuration: ${name}`);
  }
  const origin = new URL(env.SERVICE_ORIGIN);
  let web = null;
  try { web = new URL(env.WEB_ORIGIN ?? 'https://shapedesk.space'); } catch { /* invalid */ }
  const localWeb = web?.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(web.hostname) && web.port !== '';
  const limit = Number(env.MONTHLY_CHECK_LIMIT ?? 1000);
  const deviceLimit = Number(env.DEVICE_LIMIT ?? 3);
  const stripeLive = env.STRIPE_MODE === 'live';
  const checkoutEnabled = env.CHECKOUT_ENABLED === 'true';
  const hasBilling = Boolean(env.STRIPE_SECRET_KEY || env.STRIPE_PRICE_ID);
  const keyPattern = stripeLive ? /^(sk|rk)_live_[A-Za-z0-9]+$/ : /^(sk|rk)_test_[A-Za-z0-9]+$/;
  if (!['test', 'live'].includes(env.STRIPE_MODE) ||
      (hasBilling && (!keyPattern.test(env.STRIPE_SECRET_KEY ?? '') || !/^price_[a-zA-Z0-9]+$/.test(env.STRIPE_PRICE_ID ?? ''))) ||
      origin.protocol !== 'https:' || origin.username || origin.password || origin.search || origin.hash || origin.pathname !== '/' ||
      !web || web.username || web.password || web.search || web.hash || web.pathname !== '/' ||
      (web.protocol !== 'https:' && !(localWeb && !stripeLive)) ||
      !Number.isSafeInteger(limit) || limit !== 1000 || !Number.isInteger(deviceLimit) || deviceLimit < 1 || deviceLimit > 10 ||
      env.IDENTITY_HASH_KEY.length < 64 || /\s/.test(env.TYPESAFE_API_KEY) ||
      (checkoutEnabled && (!hasBilling || !env.STRIPE_WEBHOOK_SECRET?.startsWith('whsec_') || !env.STRIPE_PORTAL_CONFIGURATION_ID?.startsWith('bpc_')))) {
    throw new Error('Invalid server configuration');
  }
  // The superadmin is optional. Both variables together enable it; either alone is a mistake.
  const adminUser = env.ADMIN_USERNAME?.trim() || null;
  const adminPassword = env.ADMIN_PASSWORD_HASH?.trim() || null;
  if ((adminUser || adminPassword) &&
      (!/^[A-Za-z0-9_.@-]{3,64}$/.test(adminUser ?? '') ||
       !/^scrypt:\d+:\d+:\d+:[0-9a-f]{32,64}:[0-9a-f]{64,256}$/.test(adminPassword ?? ''))) {
    throw new Error('Invalid server configuration');
  }
  return { databaseURL: env.DATABASE_URL, jevKey: env.TYPESAFE_API_KEY, adminUser, adminPassword,
    hashKey: env.IDENTITY_HASH_KEY, limit, deviceLimit, origin: origin.origin, webOrigin: web.origin,
    stripeKey: env.STRIPE_SECRET_KEY, stripePrice: env.STRIPE_PRICE_ID,
    stripeWebhook: env.STRIPE_WEBHOOK_SECRET, stripePortal: env.STRIPE_PORTAL_CONFIGURATION_ID,
    stripeAutomaticTax: env.STRIPE_AUTOMATIC_TAX === 'true', stripeLive, checkoutEnabled };
}
