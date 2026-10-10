// ShapeDesk Pro account page. The recovery key lives only in this module's
// memory: never storage, the URL, console, or analytics. Sign out clears it.

const DEFAULT_API = 'https://api.shapedesk.space';
const API = (() => {
  const override = new URLSearchParams(location.search).get('api');
  if (!override || !['localhost', '127.0.0.1'].includes(location.hostname)) return DEFAULT_API;
  try { return new URL(override).origin; } catch { return DEFAULT_API; }
})();

let licenseKey = null;
let summary = null;

const $ = (id) => document.getElementById(id);
const els = {
  signin: $('view-signin'), account: $('view-account'), form: $('signin-form'),
  keyInput: $('key-input'), keyToggle: $('key-toggle'), signinBtn: $('signin-btn'),
  title: $('acct-title'), sub: $('acct-sub'), idNote: $('acct-idnote'), accountId: $('acct-id'),
  remaining: $('acct-remaining'),
  used: $('acct-used'), meter: $('acct-meter'), reset: $('acct-reset'),
  manage: $('manage-billing'), billingNote: $('billing-note'),
  macsCount: $('macs-count'), macList: $('mac-list'), macsEmpty: $('macs-empty'),
  refresh: $('refresh'), signout: $('signout'),
  alert: $('acct-alert'), note: $('acct-note-line'),
};

const MESSAGES = {
  invalid_license: "That key didn't match a ShapeDesk Pro account. Copy it again from ShapeDesk → AI Sort → Account.",
  rate_limited: 'Too many tries. Wait a minute, then try again.',
  device_not_found: 'That Mac was already deactivated.',
  billing_unavailable: 'This account has no Stripe billing to manage.',
};
const GENERIC = "Couldn't reach ShapeDesk. Check your connection and try again.";

function setAlert(message) {
  els.alert.hidden = !message;
  els.alert.textContent = message ?? '';
}
function setNote(message) {
  els.note.hidden = !message;
  els.note.textContent = message ?? '';
}
function showError(error) {
  setAlert(MESSAGES[error] ?? GENERIC);
}

async function request(path, extra = {}) {
  let res;
  try {
    res = await fetch(API + path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ licenseKey, ...extra }),
      credentials: 'omit',
      cache: 'no-store',
      referrerPolicy: 'no-referrer',
    });
  } catch {
    throw 'network';
  }
  let data = {};
  try { data = await res.json(); } catch { /* non-JSON error page */ }
  if (!res.ok) throw (typeof data.code === 'string' ? data.code : 'network');
  return data;
}

// Dates ---------------------------------------------------------------------

const dateFmt = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' });
const dateTimeFmt = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const utcFmt = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeZone: 'UTC' });
const relFmt = new Intl.RelativeTimeFormat(undefined, { numeric: 'auto' });

const localDate = (iso) => dateFmt.format(new Date(iso));
const localDateTime = (iso) => dateTimeFmt.format(new Date(iso));
const utcDate = (iso) => utcFmt.format(new Date(iso));

function lastSeen(iso) {
  if (!iso) return 'No activity since activation';
  const days = Math.floor((Date.now() - new Date(iso).getTime()) / 86400000);
  if (days >= 7) return `Last used ${localDate(iso)}`;
  if (days <= 0) return 'Last used today';
  return `Last used ${relFmt.format(-days, 'day')}`;
}

// Rendering -------------------------------------------------------------------

function titleFor(s) {
  if (s.accessType === 'coupon') {
    return s.active
      ? ['Pro active', `Free access through ${localDate(s.renewsAt)}. Redeem more coupons in the app to add days.`]
      : ['Coupon ended', 'Redeem another coupon or subscribe to turn AI Sort and Storage back on. Undo remains available.'];
  }
  if (s.accessType === 'owner') {
    return s.active
      ? ['Owner access', `Includes AI Sort and Storage until ${localDate(s.renewsAt)}.`]
      : ['Owner access ended', 'AI Sort and Storage are off. Undo remains available.'];
  }
  if (s.active) return ['Pro active', `Paid through ${localDate(s.renewsAt)}.`];
  switch (s.subscriptionStatus) {
    case 'past_due':
    case 'unpaid': return ['Payment needed', 'Update your payment method in Manage billing to turn AI Sort and Storage back on.'];
    case 'canceled':
    case 'incomplete_expired': return ['Subscription ended', 'AI Sort and Storage are off; undo remains available. To subscribe again, start from AI Sort → Account in the app.'];
    case 'paused': return ['Subscription paused', 'AI Sort and Storage are paused. Open Manage billing to review it.'];
    default: return ['Pro inactive', 'AI Sort and Storage are off for this subscription right now. Open Manage billing, or refresh to check again.'];
  }
}

function renderSummary() {
  const s = summary;
  const [title, sub] = titleFor(s);
  els.title.textContent = title;
  els.sub.textContent = sub;
  els.idNote.hidden = !s.account;
  if (s.account) els.accountId.textContent = s.account;

  const remaining = Math.max(0, s.limit - s.used);
  els.remaining.textContent = new Intl.NumberFormat().format(remaining);
  els.used.textContent = `${new Intl.NumberFormat().format(s.used)} of ${new Intl.NumberFormat().format(s.limit)} used`;
  els.meter.style.transform = `scaleX(${Math.min(1, s.used / Math.max(1, s.limit))})`;
  els.reset.textContent = `resets ${utcDate(s.resetsAt)} (UTC)`;

  els.manage.hidden = s.canManageBilling !== true;
  els.billingNote.textContent = s.canManageBilling === true
    ? 'Opens Stripe in a new tab for invoices, payment method or canceling.'
    : s.accessType === 'owner'
      ? "There's no billing to manage for owner access."
      : s.accessType === 'coupon'
        ? "There's no billing to manage for coupon access."
        : '';

  els.macsCount.textContent = `${s.devices.length} of ${s.deviceLimit} in use`;
  els.macsEmpty.hidden = s.devices.length !== 0;
  els.macList.replaceChildren(...s.devices.map(macRow));
}

function macRow(device) {
  const li = document.createElement('li');
  li.className = 'acct-mac';
  const text = document.createElement('div');
  text.className = 'acct-mac__text';
  const name = document.createElement('span');
  name.className = 'acct-mac__name';
  name.textContent = `Mac activated ${localDateTime(device.activatedAt)}`;
  const dates = document.createElement('span');
  dates.className = 'acct-mac__dates';
  dates.textContent = lastSeen(device.lastSeenAt);
  text.append(name, dates);
  const button = document.createElement('button');
  button.className = 'btn';
  button.type = 'button';
  button.textContent = 'Deactivate';
  button.addEventListener('click', () => confirmMac(li, device));
  li.append(text, button);
  return li;
}

/** Inline two-step confirm; no window.confirm. */
function confirmMac(li, device) {
  const box = document.createElement('div');
  box.className = 'acct-confirm';
  const prompt = document.createElement('p');
  prompt.textContent = "Deactivate this Mac? It stops using AI Sort until it's activated again. Undo still works on it.";
  const go = document.createElement('button');
  go.className = 'btn btn--danger';
  go.type = 'button';
  go.textContent = 'Deactivate';
  const keep = document.createElement('button');
  keep.className = 'btn';
  keep.type = 'button';
  keep.textContent = 'Keep';
  box.append(prompt, go, keep);
  li.replaceChildren(box);
  keep.addEventListener('click', renderSummary);
  go.addEventListener('click', async () => {
    go.disabled = true;
    keep.disabled = true;
    try {
      summary = await request('/v1/account/deactivate', { device: device.id });
      setAlert();
      setNote('Mac deactivated.');
      renderSummary();
    } catch (error) {
      if (error === 'device_not_found') {
        await load().catch(() => {});
        setAlert(MESSAGES.device_not_found);
      } else {
        showError(error);
        renderSummary();
      }
    }
  });
}

function render() {
  els.signin.hidden = summary !== null;
  els.account.hidden = summary === null;
  if (summary) renderSummary();
}

// Actions ---------------------------------------------------------------------

async function load() {
  summary = await request('/v1/account');
  setAlert();
  render();
}

els.form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const key = els.keyInput.value.trim();
  if (!key) return;
  setAlert();
  setNote();
  els.signinBtn.disabled = true;
  els.signinBtn.textContent = 'Signing in…';
  licenseKey = key;
  try {
    await load();
    els.keyInput.value = '';
    els.title.focus();
  } catch (error) {
    licenseKey = null;
    summary = null;
    render();
    showError(error);
  } finally {
    els.signinBtn.disabled = false;
    els.signinBtn.textContent = 'Sign in';
  }
});

els.keyToggle.addEventListener('click', () => {
  const show = els.keyInput.type === 'password';
  els.keyInput.type = show ? 'text' : 'password';
  els.keyToggle.textContent = show ? 'Hide' : 'Show';
  els.keyToggle.setAttribute('aria-pressed', String(show));
  els.keyInput.focus();
});

els.manage.addEventListener('click', async () => {
  // A blank tab opened synchronously survives popup blockers; it's closed on failure.
  const tab = window.open('about:blank', '_blank');
  els.manage.disabled = true;
  try {
    const { url } = await request('/v1/account/portal');
    const target = new URL(url);
    if (target.protocol !== 'https:' || target.hostname !== 'billing.stripe.com') throw 'billing_unavailable';
    if (tab) {
      tab.opener = null;
      tab.location = target.href;
    } else {
      location.href = target.href;
    }
  } catch (error) {
    tab?.close();
    showError(error);
  } finally {
    els.manage.disabled = false;
  }
});

els.refresh.addEventListener('click', async () => {
  els.refresh.disabled = true;
  try {
    await load();
    setNote('Up to date.');
  } catch (error) {
    showError(error);
  } finally {
    els.refresh.disabled = false;
  }
});

els.signout.addEventListener('click', () => {
  licenseKey = null;
  summary = null;
  setAlert();
  setNote();
  render();
  els.keyInput.focus();
});

render();
