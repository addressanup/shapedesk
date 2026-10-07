// ShapeDesk superadmin console. The session token lives only in this tab's
// sessionStorage — closing the tab signs out. Every mutation is audited server-side.

const DEFAULT_API = 'https://api.shapedesk.space';
const API = (() => {
  const override = new URLSearchParams(location.search).get('api');
  if (!override || !['localhost', '127.0.0.1'].includes(location.hostname)) return DEFAULT_API;
  try { return new URL(override).origin; } catch { return DEFAULT_API; }
})();

const $ = (id) => document.getElementById(id);
const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const els = {
  loginView: $('view-login'), dash: $('view-dash'), form: $('login-form'),
  user: $('admin-user'), pass: $('admin-pass'), loginBtn: $('login-btn'),
  session: $('adm-session'), logout: $('logout'),
  stats: $('stats'),
  couponForm: $('coupon-form'), couponCreated: $('coupon-created'),
  couponRows: $('coupon-rows'), couponsEmpty: $('coupons-empty'),
  acctQ: $('acct-q'), acctSearch: $('acct-search'), accountRows: $('account-rows'),
  accountsMore: $('accounts-more'), accountsEmpty: $('accounts-empty'),
  accountDetail: $('account-detail'),
  auditRows: $('audit-rows'), auditEmpty: $('audit-empty'),
  alert: $('adm-alert'), note: $('adm-note'),
};

const MESSAGES = {
  admin_auth: 'Wrong username or password — or your session ended. Sign in again.',
  rate_limited: 'Too many tries. Wait a minute, then try again.',
  invalid_request: "That input isn't valid — check the field and try again.",
  not_found: 'Not found — it may have already changed. Refresh the view.',
  coupon_exists: 'A coupon with that code already exists.',
  paid_subscription: 'That account pays with Stripe — manage it in Stripe instead.',
  device_not_found: 'No active Mac matched.',
};
const GENERIC = "Couldn't reach the admin API. Check your connection and try again.";

let token = sessionStorage.getItem('sd-admin-token');
let tokenExpiry = sessionStorage.getItem('sd-admin-expiry');
let activeTab = 'overview';
let accountOffset = 0;
let accountQuery = '';

function setAlert(message) { els.alert.hidden = !message; els.alert.textContent = message ?? ''; }
function setNote(message) { els.note.hidden = !message; els.note.textContent = message ?? ''; }
function failout(error) {
  if (error === 'admin_auth') { dropSession(); render(); }
  setAlert(MESSAGES[error] ?? GENERIC);
}
function dropSession() {
  token = null; tokenExpiry = null;
  sessionStorage.removeItem('sd-admin-token');
  sessionStorage.removeItem('sd-admin-expiry');
}

async function api(path, { method = 'GET', body } = {}) {
  let res;
  try {
    res = await fetch(API + path, {
      method,
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: body === undefined ? undefined : JSON.stringify(body),
      credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer',
    });
  } catch { throw 'network'; }
  let data = {};
  try { data = await res.json(); } catch { /* non-JSON error page */ }
  if (!res.ok) throw (typeof data.code === 'string' ? data.code : 'network');
  return data;
}

const dtFmt = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const dFmt = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' });
const dt = (iso) => iso ? dtFmt.format(new Date(iso)) : '—';
const dd = (iso) => iso ? dFmt.format(new Date(iso)) : '—';

function badge(text, kind) {
  return el('span', `adm-badge adm-badge--${kind}`, text);
}
/** Two-step inline confirm; go() runs after the second click. */
function confirmButton(label, danger, go) {
  const btn = el('button', `btn adm-mini${danger ? ' btn--danger' : ''}`, label);
  btn.type = 'button';
  btn.addEventListener('click', () => {
    if (btn.dataset.arm) { btn.disabled = true; go().finally(() => { btn.disabled = false; }); return; }
    btn.dataset.arm = '1';
    btn.textContent = 'Sure?';
    setTimeout(() => { delete btn.dataset.arm; btn.textContent = label; }, 3000);
  });
  return btn;
}

// Login / logout ---------------------------------------------------------------

els.form.addEventListener('submit', async (e) => {
  e.preventDefault();
  setAlert(); setNote();
  els.loginBtn.disabled = true;
  els.loginBtn.textContent = 'Signing in…';
  try {
    const res = await fetch(API + '/v1/admin/session', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: els.user.value.trim(), password: els.pass.value }),
      credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer',
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw (typeof data.code === 'string' ? data.code : 'network');
    token = data.token; tokenExpiry = data.expiresAt;
    sessionStorage.setItem('sd-admin-token', token);
    sessionStorage.setItem('sd-admin-expiry', tokenExpiry);
    els.pass.value = '';
    render();
    show('overview');
  } catch (error) { setAlert(MESSAGES[error] ?? GENERIC); }
  finally { els.loginBtn.disabled = false; els.loginBtn.textContent = 'Sign in'; }
});

els.logout.addEventListener('click', async () => {
  try { await api('/v1/admin/session', { method: 'DELETE' }); } catch { /* token already gone */ }
  dropSession();
  render();
});

// Tabs -------------------------------------------------------------------------

document.querySelectorAll('.adm-tab').forEach((tab) => {
  tab.addEventListener('click', () => show(tab.dataset.tab));
});

function show(name) {
  activeTab = name;
  document.querySelectorAll('.adm-tab').forEach(t => t.classList.toggle('is-on', t.dataset.tab === name));
  for (const tab of ['overview', 'coupons', 'accounts', 'audit'])
    $(`tab-${tab}`).hidden = tab !== name;
  setAlert(); setNote();
  if (name === 'overview') loadOverview();
  if (name === 'coupons') loadCoupons();
  if (name === 'accounts') loadAccounts(true);
  if (name === 'audit') loadAudit();
}

// Overview ---------------------------------------------------------------------

async function loadOverview() {
  try {
    const o = await api('/v1/admin/overview');
    const cards = [
      ['Accounts', o.accounts], ['Live access', o.subscriptions.active],
      ['Stripe subs', o.subscriptions.stripe.n], ['Coupon subs', o.subscriptions.coupon.n],
      ['Owner grants', o.subscriptions.owner.n], ['Suspended', o.suspended],
      ['Active Macs', o.devices], ['Checks this month', o.checksThisMonth],
      ['Active coupons', o.activeCoupons], ['Redeemed this week', o.redemptionsThisWeek],
    ];
    els.stats.replaceChildren(...cards.map(([label, value]) => {
      const card = el('div', 'adm-stat');
      card.append(el('b', null, new Intl.NumberFormat().format(value)), el('span', null, label));
      return card;
    }));
    setAlert();
  } catch (error) { failout(error); }
}

// Coupons ----------------------------------------------------------------------

function couponStateCell(c) {
  const cell = el('td');
  if (!c.active) cell.append(badge('revoked', 'bad'));
  else if (c.expiresAt && new Date(c.expiresAt) <= new Date()) cell.append(badge('expired', 'warn'));
  else if (c.redeemed >= c.maxRedemptions) cell.append(badge('exhausted', 'warn'));
  else cell.append(badge('active', 'good'));
  return cell;
}

function couponRow(c) {
  const tr = el('tr');
  tr.append(el('td', 'adm-mono', c.code), el('td', null, String(c.grantDays)),
    el('td', null, `${c.redeemed} / ${c.maxRedemptions}`));
  tr.append(couponStateCell(c), el('td', null, dd(c.expiresAt)),
    el('td', 'adm-note', c.note ?? ''));
  const actions = el('td', 'adm-actions');
  actions.append(confirmButton(c.active ? 'Revoke' : 'Activate', c.active, async () => {
    try {
      const updated = await api(`/v1/admin/coupons/${encodeURIComponent(c.code)}/${c.active ? 'revoke' : 'activate'}`, { method: 'POST', body: {} });
      Object.assign(c, updated);
      tr.replaceWith(couponRow(c));
      setNote(`${updated.code} ${updated.active ? 'activated' : 'revoked'}.`);
      setAlert();
    } catch (error) { failout(error); }
  }));
  const uses = el('button', 'btn adm-mini', 'Uses');
  uses.type = 'button';
  uses.addEventListener('click', () => toggleRedemptions(tr, c));
  actions.append(uses);
  tr.append(actions);
  return tr;
}

function toggleRedemptions(tr, coupon) {
  const next = tr.nextElementSibling;
  if (next?.classList.contains('adm-subrow')) { next.remove(); return; }
  const sub = el('tr', 'adm-subrow');
  const td = el('td');
  td.colSpan = 7;
  td.append(el('span', 'adm-note', 'Loading…'));
  sub.append(td);
  tr.after(sub);
  api(`/v1/admin/coupons/${encodeURIComponent(coupon.code)}/redemptions`).then(data => {
    if (!data.redemptions.length) { td.replaceChildren(el('span', 'adm-note', 'No redemptions yet.')); return; }
    const list = el('ul', 'adm-uses');
    for (const r of data.redemptions) {
      const item = el('li');
      item.append(el('code', null, r.account.slice(0, 12)), el('span', 'adm-note', ` · ${dt(r.redeemedAt)}`));
      list.append(item);
    }
    td.replaceChildren(list);
  }).catch(error => { sub.remove(); failout(error); });
}

async function loadCoupons() {
  try {
    const data = await api('/v1/admin/coupons');
    els.couponsEmpty.hidden = data.coupons.length !== 0;
    els.couponRows.replaceChildren(...data.coupons.map(couponRow));
    setAlert();
  } catch (error) { failout(error); }
}

els.couponForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  setAlert(); setNote(); els.couponCreated.hidden = true;
  const body = {
    grantDays: Number($('c-days').value),
    maxRedemptions: Number($('c-max').value),
  };
  const code = $('c-code').value.trim();
  if (code) body.code = code;
  const exp = $('c-exp').value;
  if (exp) body.expiresAt = `${exp}T23:59:59Z`;
  const note = $('c-note').value.trim();
  if (note) body.note = note;
  $('coupon-create').disabled = true;
  try {
    const c = await api('/v1/admin/coupons', { method: 'POST', body });
    els.couponCreated.hidden = false;
    els.couponCreated.textContent = `Created ${c.code} — ${c.grantDays} days, ${c.maxRedemptions} use(s).`;
    els.couponForm.reset();
    $('c-days').value = 30; $('c-max').value = 1;
    await loadCoupons();
    setNote(`Coupon ${c.code} is live.`);
  } catch (error) { failout(error); }
  finally { $('coupon-create').disabled = false; }
});

// Accounts ---------------------------------------------------------------------

const KIND_LABEL = { stripe: 'Stripe', coupon: 'Coupon', owner: 'Owner' };

function accountRow(a) {
  const tr = el('tr', 'adm-acct');
  tr.append(el('td', 'adm-mono', a.id.slice(0, 12)),
    el('td', null, a.kind ? KIND_LABEL[a.kind] ?? a.kind : '—'));
  const state = el('td');
  if (a.suspended) state.append(badge('suspended', 'bad'));
  else if (a.active) state.append(badge('live', 'good'));
  else state.append(badge(a.kind ? 'inactive' : 'none', 'dim'));
  tr.append(state, el('td', null, String(a.devices)), el('td', null, String(a.used)),
    el('td', null, dd(a.validUntil)), el('td', null, dt(a.lastSeenAt)));
  tr.addEventListener('click', () => openAccount(a.id));
  return tr;
}

async function loadAccounts(reset) {
  if (reset) { accountOffset = 0; els.accountDetail.hidden = true; }
  try {
    const data = await api(`/v1/admin/accounts?q=${encodeURIComponent(accountQuery)}&offset=${accountOffset}&limit=25`);
    const rows = data.accounts.map(accountRow);
    if (reset) els.accountRows.replaceChildren(...rows);
    else els.accountRows.append(...rows);
    els.accountsEmpty.hidden = !(reset && !data.accounts.length);
    els.accountsMore.hidden = data.next === null;
    accountOffset = data.next ?? accountOffset;
    setAlert();
  } catch (error) { failout(error); }
}

els.acctSearch.addEventListener('click', () => { accountQuery = els.acctQ.value.trim(); loadAccounts(true); });
els.acctQ.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); accountQuery = els.acctQ.value.trim(); loadAccounts(true); } });
els.accountsMore.addEventListener('click', () => loadAccounts(false));

async function openAccount(id) {
  try {
    const a = await api(`/v1/admin/accounts/${id}`);
    renderAccount(a);
    els.accountDetail.hidden = false;
    els.accountDetail.scrollIntoView({ block: 'nearest' });
    setAlert();
  } catch (error) { failout(error); }
}

function field(label, value) {
  const row = el('div', 'adm-kv');
  row.append(el('span', 'adm-k', label), el('span', 'adm-v', value));
  return row;
}

function renderAccount(a) {
  const box = els.accountDetail;
  box.replaceChildren();
  const head = el('div', 'adm-detail__head');
  head.append(el('code', null, a.id),
    field('Created', dt(a.createdAt)),
    a.subscription
      ? field('Access', `${KIND_LABEL[a.subscription.kind] ?? a.subscription.kind} · ${a.subscription.status}${a.subscription.suspended ? ' · suspended' : ''}${a.subscription.active ? ' · live' : ''}`)
      : field('Access', 'none'),
    a.subscription ? field('Valid until', dt(a.subscription.validUntil)) : '',
    a.subscription?.stripeCustomer ? field('Stripe customer', a.subscription.stripeCustomer) : '',
    a.checkout ? field('Checkout', a.checkout.completed ? 'completed' : a.checkout.started ? 'started' : 'none') : '');
  box.append(head);

  const macTitle = el('h3', null, `Macs (${a.devices.length})`);
  const macList = el('ul', 'adm-devices');
  for (const d of a.devices) {
    const item = el('li');
    item.append(el('code', null, d.device.slice(0, 8)),
      el('span', 'adm-note', ` ${d.active ? 'active' : 'off'} · seen ${dt(d.lastSeenAt)}`));
    if (d.active) item.append(confirmButton('Deactivate', true, async () => {
      try {
        await api(`/v1/admin/accounts/${a.id}/deactivate-devices`, { method: 'POST', body: { device: d.device } });
        setNote('Mac deactivated.');
        await openAccount(a.id);
      } catch (error) { failout(error); }
    }));
    macList.append(item);
  }
  if (!a.devices.length) macList.append(el('li', 'adm-note', 'No Macs registered.'));

  const usageTitle = el('h3', null, 'Usage');
  const usage = el('p', 'adm-note', a.usage.length
    ? a.usage.map(u => `${u.period.slice(0, 7)}: ${u.used}`).join('   ·   ')
    : 'No usage recorded.');

  const redTitle = el('h3', null, `Coupon redemptions (${a.redemptions.length})`);
  const reds = el('ul', 'adm-uses');
  for (const r of a.redemptions) {
    const item = el('li');
    item.append(el('code', null, r.coupon), el('span', 'adm-note', ` · ${dt(r.redeemedAt)}`));
    reds.append(item);
  }
  if (!a.redemptions.length) reds.append(el('li', 'adm-note', 'None.'));

  const actions = el('div', 'adm-ops');
  const grantRow = el('div', 'adm-op');
  const grantDays = el('input');
  grantDays.type = 'number'; grantDays.min = '1'; grantDays.max = '3650'; grantDays.value = '30';
  grantRow.append(el('span', 'adm-op__label', 'Grant free days'),
    grantDays,
    confirmButton('Grant', false, async () => {
      try {
        const result = await api(`/v1/admin/accounts/${a.id}/grant`, { method: 'POST', body: { days: Number(grantDays.value) } });
        setNote(`Granted — access now runs to ${dd(result.validUntil)}.`);
        await openAccount(a.id);
      } catch (error) { failout(error); }
    }));
  const suspended = a.subscription?.suspended;
  const suspendRow = el('div', 'adm-op');
  suspendRow.append(el('span', 'adm-op__label', suspended ? 'Suspended' : 'Suspension'),
    confirmButton(suspended ? 'Unsuspend' : 'Suspend account', true, async () => {
      try {
        await api(`/v1/admin/accounts/${a.id}/${suspended ? 'unsuspend' : 'suspend'}`, { method: 'POST', body: {} });
        setNote(suspended ? 'Account unsuspended.' : 'Account suspended.');
        await openAccount(a.id);
      } catch (error) { failout(error); }
    }));
  const quotaRow = el('div', 'adm-op');
  const quotaUsed = el('input');
  quotaUsed.type = 'number'; quotaUsed.min = '0'; quotaUsed.max = '100000';
  quotaUsed.value = String(a.usage.find(u => u.period === new Date().toISOString().slice(0, 7) + '-01')?.used ?? a.usage[0]?.used ?? 0);
  quotaRow.append(el('span', 'adm-op__label', 'Checks used this month'),
    quotaUsed,
    confirmButton('Set', false, async () => {
      try {
        await api(`/v1/admin/accounts/${a.id}/quota`, { method: 'POST', body: { used: Number(quotaUsed.value) } });
        setNote('Usage updated.');
        await openAccount(a.id);
      } catch (error) { failout(error); }
    }));
  const macsRow = el('div', 'adm-op');
  macsRow.append(el('span', 'adm-op__label', 'All Macs'),
    confirmButton('Deactivate all', true, async () => {
      try {
        await api(`/v1/admin/accounts/${a.id}/deactivate-devices`, { method: 'POST', body: { device: 'all' } });
        setNote('Every Mac deactivated.');
        await openAccount(a.id);
      } catch (error) { failout(error); }
    }));
  actions.append(grantRow, suspendRow, quotaRow, macsRow);
  box.append(macTitle, macList, usageTitle, usage, redTitle, reds, el('h3', null, 'Actions'), actions);
}

// Audit ------------------------------------------------------------------------

async function loadAudit() {
  try {
    const data = await api('/v1/admin/audit');
    els.auditEmpty.hidden = data.audit.length !== 0;
    els.auditRows.replaceChildren(...data.audit.map(entry => {
      const tr = el('tr');
      const detail = Object.keys(entry.detail ?? {}).length
        ? JSON.stringify(entry.detail) : '';
      tr.append(el('td', 'adm-nowrap', dt(entry.at)), el('td', 'adm-mono', entry.action),
        el('td', 'adm-mono adm-target', entry.target.slice(0, 16)), el('td', 'adm-note', detail));
      return tr;
    }));
    setAlert();
  } catch (error) { failout(error); }
}

// Boot -------------------------------------------------------------------------

function render() {
  const signedIn = Boolean(token) && (!tokenExpiry || new Date(tokenExpiry) > new Date());
  if (!signedIn && token) dropSession();
  els.loginView.hidden = Boolean(token);
  els.dash.hidden = !token;
  if (token) {
    els.session.textContent = tokenExpiry ? `until ${dt(tokenExpiry)}` : '';
  }
}

if (token && tokenExpiry && new Date(tokenExpiry) <= new Date()) dropSession();
render();
if (token) show('overview');
