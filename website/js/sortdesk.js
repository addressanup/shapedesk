// Pretend AI Sort: a second desktop of loose files plus a replica of the app's
// "ShapeDesk — AI Sort" window (AISortView.swift). Everything happens in-page;
// the files, scores and check counts are all pretend.

const CATEGORIES = ['Screenshots', 'Recordings', 'Videos', 'Audio', 'Images', 'Docs', 'Code', 'Other'];
const EMBLEM = {
  Screenshots: 'em-screenshots', Recordings: 'em-recordings', Videos: 'em-videos', Audio: 'em-audio',
  Images: 'em-images', Docs: 'em-docs', Code: 'em-code', Other: 'em-other',
};

const FILES = [
  { name: 'Screenshot 2026-10-06 at 09.41.12.png', kind: 'screenshot', cat: 'Screenshots', conf: 0.97, x: 0.00, y: 0.05 },
  { name: 'Invoice-0423.pdf', kind: 'doc', badge: 'PDF', color: '#c94f43', cat: 'Docs', conf: 0.96, x: 0.24, y: 0.01 },
  { name: 'moodboard-02.jpg', kind: 'image', cat: 'Images', conf: 0.93, x: 0.46, y: 0.08 },
  { name: 'ContentView.swift', kind: 'doc', badge: 'SWIFT', color: '#d96a45', cat: 'Code', conf: 0.97, x: 0.68, y: 0.02 },
  { name: 'drone-beach-4k.mp4', kind: 'video', cat: 'Videos', conf: 0.96, x: 0.90, y: 0.10 },
  { name: 'untitled', kind: 'blank', cat: 'Other', conf: 0.41, x: 0.09, y: 0.30 },
  { name: 'budget-2026.xlsx', kind: 'doc', badge: 'XLSX', color: '#3f8f57', cat: 'Docs', conf: 0.92, x: 0.32, y: 0.25 },
  { name: 'IMG_2041.HEIC', kind: 'image', cat: 'Images', conf: 0.95, x: 0.56, y: 0.31 },
  { name: 'deploy.sh', kind: 'doc', badge: 'SH', color: '#5f6b7d', cat: 'Code', conf: 0.91, x: 0.78, y: 0.27 },
  { name: 'Screen Recording 2026-10-05 at 14.02.11.mov', kind: 'screenrec', cat: 'Recordings', conf: 0.93, x: 0.97, y: 0.34 },
  { name: 'meeting notes.txt', kind: 'doc', badge: 'TXT', color: '#7d8590', cat: 'Docs', conf: 0.88, x: 0.03, y: 0.55 },
  { name: 'fetch_weather.py', kind: 'doc', badge: 'PY', color: '#4f7fa8', cat: 'Code', conf: 0.94, x: 0.27, y: 0.50 },
  { name: 'Screenshot 2026-10-03 at 11.27.40.png', kind: 'screenshot', cat: 'Screenshots', conf: 0.95, x: 0.49, y: 0.56 },
  { name: 'podcast-intro.mp3', kind: 'audio', cat: 'Audio', conf: 0.92, x: 0.71, y: 0.50 },
  { name: 'lease agreement (signed).pdf', kind: 'doc', badge: 'PDF', color: '#c94f43', cat: 'Docs', conf: 0.94, x: 0.91, y: 0.59 },
  { name: 'lofi-loop-90bpm.wav', kind: 'audio', cat: 'Audio', conf: 0.9, x: 0.16, y: 0.77 },
  { name: 'fonts-backup.zip', kind: 'zip', cat: 'Other', conf: 0.89, x: 0.42, y: 0.79 },
  { name: 'export (3)', kind: 'blank', cat: 'Docs', conf: 0.57, x: 0.68, y: 0.74 },
];

function docInner(kind) {
  switch (kind) {
    case 'screenshot':
      return `<rect x="9" y="10.5" width="26" height="19" rx="2.5" fill="#26242e"/>
        <circle cx="12.3" cy="13.6" r=".9" fill="#ff5f57"/><circle cx="15" cy="13.6" r=".9" fill="#febc2e"/><circle cx="17.7" cy="13.6" r=".9" fill="#28c840"/>
        <rect x="11.5" y="17.5" width="13" height="1.9" rx=".9" fill="#7ec8f0"/>
        <rect x="11.5" y="21.5" width="19" height="1.9" rx=".9" fill="#554e68"/>
        <rect x="11.5" y="25.5" width="15" height="1.9" rx=".9" fill="#554e68"/>`;
    case 'screenrec':
      return `<rect x="9" y="10.5" width="26" height="19" rx="2.5" fill="#26242e"/>
        <circle cx="12.3" cy="13.6" r=".9" fill="#ff5f57"/><circle cx="15" cy="13.6" r=".9" fill="#febc2e"/><circle cx="17.7" cy="13.6" r=".9" fill="#28c840"/>
        <rect x="11.5" y="17.5" width="16" height="1.9" rx=".9" fill="#554e68"/>
        <rect x="11.5" y="21.5" width="19" height="1.9" rx=".9" fill="#554e68"/>
        <circle cx="30.5" cy="26" r="2" fill="#d94444"/>`;
    case 'image':
      return `<rect x="9" y="10.5" width="26" height="22" rx="2.5" fill="url(#photo-sky)"/>
        <circle cx="15.5" cy="16.5" r="2.6" fill="#ffe3a0"/>
        <path d="M9 32.5v-1.6l8.5-7.6 5 5.3 4.5-4.3 8 7.7v.5H9z" fill="#37557c"/>`;
    case 'video':
      return `<rect x="9" y="11.5" width="26" height="19" rx="2.5" fill="#211f2a"/>
        <path d="m19.5 16.5 7.5 4.5-7.5 4.5z" fill="#f4eef8"/>
        <rect x="12" y="28" width="20" height="1.4" rx=".7" fill="#453f58"/>
        <rect x="12" y="28" width="7" height="1.4" rx=".7" fill="#7ec8f0"/>`;
    case 'audio':
      return `<g fill="#4ba8f0">
          <rect x="10.5" y="18" width="3" height="9" rx="1.5"/>
          <rect x="15.5" y="13" width="3" height="18" rx="1.5"/>
          <rect x="20.5" y="16" width="3" height="13" rx="1.5"/>
          <rect x="25.5" y="11.5" width="3" height="21" rx="1.5"/>
          <rect x="30.5" y="17" width="3" height="11" rx="1.5"/>
        </g>`;
    case 'zip':
      return `<g fill="#93a0b0">
          <rect x="20" y="12" width="4" height="2.6" rx=".8"/>
          <rect x="20" y="16.6" width="4" height="2.6" rx=".8"/>
          <rect x="20" y="21.2" width="4" height="2.6" rx=".8"/>
        </g>
        <rect x="18.8" y="24.6" width="6.4" height="9.5" rx="2.2" fill="#7d8794"/>
        <rect x="20.6" y="28" width="2.8" height="5.5" rx="1.4" fill="#5c6570"/>`;
    case 'doc':
      return `<g fill="#a8b2c2">
          <rect x="11" y="15" width="20" height="2.2" rx="1.1"/>
          <rect x="11" y="20" width="16" height="2.2" rx="1.1"/>
          <rect x="11" y="25" width="21" height="2.2" rx="1.1"/>
          <rect x="11" y="30" width="13" height="2.2" rx="1.1"/>
        </g>`;
    default:
      return '';
  }
}

function fileArt(file) {
  const badge = file.badge
    ? `<rect x="7" y="41" width="30" height="11.5" rx="2.8" fill="${file.color}"/>
       <text class="ficon__badge" x="22" y="49.6" text-anchor="middle">${file.badge}</text>`
    : '';
  return `<svg viewBox="0 0 44 56"><use href="#doc"/>${docInner(file.kind)}${badge}</svg>`;
}

export function initSortDesk() {
  const field = document.getElementById('sortdesk-field');
  const layer = document.getElementById('sortdesk-icons');
  if (!field || !layer) return;

  const win = layer.closest('.sortdesk').querySelector('.aiwin');
  const runBtn = document.getElementById('sort-run');
  const stopBtn = document.getElementById('sort-stop');
  const undoBtn = document.getElementById('sort-undo');
  const statusEl = document.getElementById('aiwin-status');
  const countsEl = document.getElementById('aiwin-counts');
  const progressEl = document.getElementById('aiwin-progress');
  const progressBar = document.getElementById('aiwin-progress-bar');
  const foldersTitle = document.getElementById('folders-title');
  const catsEl = document.getElementById('aiwin-cats');
  const tableEl = document.getElementById('aiwin-table');
  const checksEl = document.getElementById('checks-left');
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');

  const setStatus = (text) => { statusEl.textContent = text; };
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, reduceMotion.matches ? 0 : ms));

  // File icons ---------------------------------------------------------------

  const files = FILES.map((f) => {
    const el = document.createElement('div');
    el.className = 'ficon';
    el.innerHTML = `<div class="ficon__art">${fileArt(f)}</div><span class="ficon__label"></span>`;
    el.lastElementChild.textContent = f.name;
    layer.append(el);
    return { ...f, el, home: null, sorted: false };
  });
  const sortOrder = files.slice().sort((a, b) =>
    a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' }));
  const folders = new Map(); // category -> { el, slot }
  let folderSlots = [];
  let movedOrder = [];

  function folderArt(cat) {
    return `<svg viewBox="0 0 64 52"><use href="#folder"/><use href="#${EMBLEM[cat]}" x="22" y="20" width="20" height="20"/></svg>`;
  }

  function makeFolder(cat) {
    const slot = folderSlots[folders.size];
    const el = document.createElement('div');
    el.className = 'ficon ficon--folder';
    el.innerHTML = `<div class="ficon__art">${folderArt(cat)}</div><span class="ficon__label"></span>`;
    el.lastElementChild.textContent = cat;
    el.style.left = `${slot.x}px`;
    el.style.top = `${slot.y}px`;
    layer.append(el);
    const folder = { el, slot };
    folders.set(cat, folder);
    return folder;
  }

  // Layout -------------------------------------------------------------------

  function layout() {
    // Wide = the window overlays the field; below 1240px it stacks underneath.
    const wide = !matchMedia('(max-width: 1240px)').matches;
    const fieldW = field.clientWidth;
    const fieldH = field.clientHeight;
    const labelsHidden = matchMedia('(max-width: 860px)').matches;
    const cellW = labelsHidden ? 72 : 92;
    const slotW = labelsHidden ? 74 : 96;
    const slotH = labelsHidden ? 66 : 96;

    // Where loose files may sit: right of the window on wide layouts.
    const zoneX = wide ? win.offsetLeft + win.offsetWidth + 18 : 12;
    const zoneW = Math.max(fieldW - zoneX - 14, 160);

    // Folder slots fill the bottom rows right to left, like Finder's free slots.
    folderSlots = [];
    const perRow = Math.max(1, Math.floor((zoneW - 20) / slotW));
    const rowsNeeded = Math.ceil(CATEGORIES.length / perRow);
    for (let r = 0; r < rowsNeeded; r++) {
      for (let c = 0; c < perRow; c++) {
        folderSlots.push({
          x: fieldW - 12 - slotW * (c + 1),
          y: fieldH - 14 - slotH - r * slotH + 6,
        });
      }
    }
    const reserve = rowsNeeded * slotH + 18;
    const zoneH = Math.max(fieldH - reserve - 20, 80);

    files.forEach((f) => {
      if (!f.home) f.home = {};
      f.home.x = zoneX + 30 + f.x * (zoneW - 60) - cellW / 2;
      f.home.y = 10 + f.y * (zoneH - 20);
      if (!f.sorted) { f.el.style.left = `${f.home.x}px`; f.el.style.top = `${f.home.y}px`; }
      f.el.style.width = `${cellW}px`;
    });
    [...folders.values()].forEach((folder, i) => {
      const slot = folderSlots[i] ?? folderSlots[folderSlots.length - 1];
      folder.slot = slot;
      folder.el.style.left = `${slot.x}px`;
      folder.el.style.top = `${slot.y}px`;
      folder.el.style.width = `${cellW}px`;
    });
  }

  // Breakdown table ------------------------------------------------------------

  const counts = Object.fromEntries(CATEGORIES.map((c) => [c, { moved: 0, kept: 0 }]));
  const tableRows = new Map();

  function buildTable() {
    tableEl.replaceChildren();
    const head = document.createElement('div');
    head.className = 'aiwin__tr aiwin__tr--head';
    head.innerHTML = '<span>Folder</span><span>Moved</span><span>Kept</span>';
    tableEl.append(head);
    tableRows.clear();
    for (const cat of CATEGORIES) {
      const row = document.createElement('div');
      row.className = 'aiwin__tr';
      row.innerHTML = `<span class="aiwin__cat"><svg viewBox="0 0 20 20"><use href="#${EMBLEM[cat]}"/></svg>${cat}</span><span>0</span><span>0</span>`;
      tableEl.append(row);
      tableRows.set(cat, row);
    }
    const tail = document.createElement('div');
    tail.className = 'aiwin__tr';
    tail.innerHTML = '<span class="aiwin__cat">Unclassified</span><span>—</span><span>0</span>';
    tableEl.append(tail);
    tableRows.set('Unclassified', tail);
  }

  function bumpTable(cat, kind) {
    counts[cat][kind] += 1;
    const row = tableRows.get(cat);
    row.children[1].textContent = String(counts[cat].moved);
    row.children[2].textContent = String(counts[cat].kept);
  }

  // Sorting -------------------------------------------------------------------

  const counters = { scanned: 0, moved: 0, kept: 0 };
  let checks = Number(checksEl.textContent) || 863;
  let running = false;
  let undoing = false;
  let stopRequested = false;
  let canUndo = false;

  const el = (id) => document.getElementById(id);
  function updateCounters() {
    el('count-scanned').textContent = String(counters.scanned);
    el('count-moved').textContent = String(counters.moved);
    el('count-kept').textContent = String(counters.kept);
  }
  function spendCheck() {
    checks -= 1;
    checksEl.textContent = String(checks);
  }

  async function fly(el, from, to, { shrink = false } = {}) {
    if (reduceMotion.matches) return;
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    el.classList.add('is-moving');
    const anim = el.animate([
      { transform: 'translate(0px, 0px) scale(1)', opacity: 1 },
      { transform: `translate(${dx * 0.55}px, ${dy * 0.55 - 30}px) scale(.92)`, opacity: 1, offset: 0.55 },
      { transform: `translate(${dx}px, ${dy}px) scale(${shrink ? 0.5 : 1})`, opacity: shrink ? 0 : 1 },
    ], { duration: 400, easing: 'cubic-bezier(0.4, 0.65, 0.35, 1)' });
    await anim.finished.catch(() => {});
    el.classList.remove('is-moving');
  }

  const centerOf = (elm, within) => {
    const a = elm.getBoundingClientRect();
    const b = within.getBoundingClientRect();
    return { x: a.left - b.left + a.width / 2, y: a.top - b.top + a.height / 2 };
  };

  function setButtons() {
    runBtn.hidden = running;
    stopBtn.hidden = !running;
    runBtn.disabled = running || undoing;
    undoBtn.disabled = !canUndo || running || undoing;
  }

  async function runSort() {
    if (running || undoing) return;
    const loose = sortOrder.filter((f) => !f.sorted);
    if (!loose.length) {
      setStatus('No loose files on this desktop.');
      return;
    }
    running = true;
    stopRequested = false;
    canUndo = false;
    counters.scanned = 0;
    counters.moved = 0;
    counters.kept = 0;
    movedOrder = [];
    updateCounters();
    countsEl.hidden = false;
    progressEl.hidden = false;
    catsEl.hidden = true;
    tableEl.hidden = false;
    foldersTitle.textContent = 'This sort';
    setButtons();
    setStatus('Scanning files…');
    progressBar.style.transform = 'scaleX(0)';
    await wait(450);

    for (const file of loose) {
      if (stopRequested) break;
      setStatus(`Classifying ${file.name}…`);
      await wait(200);
      counters.scanned += 1;
      spendCheck();
      if (file.conf > 0.8) {
        const folder = folders.get(file.cat) ?? makeFolder(file.cat);
        bumpTable(file.cat, 'moved');
        const from = centerOf(file.el.querySelector('.ficon__art'), field);
        const to = centerOf(folder.el.querySelector('.ficon__art'), field);
        counters.moved += 1;
        movedOrder.push(file);
        setStatus(`Moved ${file.name} to ${file.cat}.`);
        await fly(file.el, from, to, { shrink: true });
        file.el.style.transform = '';
        file.sorted = true;
        file.el.classList.add('is-sorted');
        folder.el.classList.remove('is-bump');
        void folder.el.offsetWidth;
        folder.el.classList.add('is-bump');
      } else {
        counters.kept += 1;
        bumpTable(file.cat, 'kept');
        setStatus(`Left ${file.name} in place: confidence must exceed 80%.`);
        file.el.classList.remove('is-kept');
        void file.el.offsetWidth;
        file.el.classList.add('is-kept');
        setTimeout(() => file.el.classList.remove('is-kept'), 700);
        await wait(160);
      }
      updateCounters();
      progressBar.style.transform = `scaleX(${counters.scanned / loose.length})`;
    }

    if (stopRequested) {
      setStatus(`Stopped. ${counters.moved} files moved; ${counters.kept} left in place.`);
    } else {
      setStatus(`Sorted ${counters.moved} of ${counters.scanned} files; ${counters.kept} left in place.`);
    }
    canUndo = movedOrder.length > 0;
    running = false;
    setButtons();
  }

  async function runUndo() {
    if (running || undoing || !canUndo) return;
    undoing = true;
    setButtons();
    const restoring = movedOrder.slice().reverse();
    setStatus('Restoring files…');
    progressBar.style.transform = 'scaleX(0)';
    progressEl.hidden = false;
    let restored = 0;
    for (const file of restoring) {
      file.el.classList.remove('is-sorted');
      const folder = folders.get(file.cat);
      const to = centerOf(folder.el.querySelector('.ficon__art'), field);
      const home = { x: file.home.x + file.el.offsetWidth / 2, y: file.home.y + file.el.offsetHeight / 2 };
      if (reduceMotion.matches) {
        file.el.style.transform = '';
      } else {
        const dx = to.x - home.x;
        const dy = to.y - home.y;
        file.el.style.transform = `translate(${dx}px, ${dy}px) scale(.5)`;
        file.el.style.opacity = '0';
        await new Promise((resolve) => requestAnimationFrame(resolve));
        const anim = file.el.animate([
          { transform: `translate(${dx}px, ${dy}px) scale(.5)`, opacity: 0 },
          { transform: `translate(${dx * 0.4}px, ${dy * 0.4 - 26}px) scale(.95)`, opacity: 1, offset: 0.6 },
          { transform: 'translate(0px, 0px) scale(1)', opacity: 1 },
        ], { duration: 380, easing: 'cubic-bezier(0.35, 0.7, 0.35, 1)' });
        await anim.finished.catch(() => {});
      }
      file.el.style.transform = '';
      file.el.style.opacity = '';
      file.sorted = false;
      restored += 1;
      setStatus(`Restored ${file.name}.`);
      progressBar.style.transform = `scaleX(${restored / restoring.length})`;
      await wait(120);
    }
    movedOrder = [];
    counters.moved = 0;
    updateCounters();
    setStatus(`Restored ${restored} files; 0 could not be restored.`);
    canUndo = false;
    undoing = false;
    setButtons();
  }

  runBtn.addEventListener('click', runSort);
  stopBtn.addEventListener('click', () => {
    if (running) {
      stopRequested = true;
      setStatus('Stopping after the current file operation…');
    }
  });
  undoBtn.addEventListener('click', runUndo);

  buildTable();
  tableEl.hidden = true;
  layout();
  let resizeQueued = false;
  new ResizeObserver(() => {
    if (resizeQueued) return;
    resizeQueued = true;
    requestAnimationFrame(() => {
      resizeQueued = false;
      layout();
    });
  }).observe(field);
}

/** Live availability: the plan card mirrors GET /v1/plans. On failure, nothing changes. */
export function initProPlan() {
  const price = document.getElementById('plan-price');
  if (!price) return;
  const checks = document.getElementById('plan-checks');
  const macs = document.getElementById('plan-macs');
  const status = document.getElementById('plan-status');
  const note = document.getElementById('plan-note');
  let base = 'https://api.shapedesk.space';
  if (['localhost', '127.0.0.1'].includes(location.hostname)) {
    const override = new URLSearchParams(location.search).get('api');
    if (!override) return;
    try { base = new URL(override).origin; } catch { return; }
  }
  fetch(`${base}/v1/plans`, {
    credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer',
    signal: AbortSignal.timeout(4000),
  }).then((res) => (res.ok ? res.json() : Promise.reject(new Error(res.status))))
    .then((plan) => {
      const money = new Intl.NumberFormat(undefined, { style: 'currency', currency: plan.currency ?? 'USD', minimumFractionDigits: 0, maximumFractionDigits: 2 });
      const num = new Intl.NumberFormat();
      if (Number.isFinite(plan.unitAmount)) price.textContent = money.format(plan.unitAmount / 100);
      if (Number.isFinite(plan.monthlyLimit)) checks.textContent = num.format(plan.monthlyLimit);
      if (Number.isFinite(plan.deviceLimit)) macs.textContent = num.format(plan.deviceLimit);
      if (plan.checkoutEnabled === false) {
        status.hidden = false;
        note.textContent = 'Pro subscriptions open soon. Shapes, words and undo work today.';
      }
    })
    .catch(() => {});
}
