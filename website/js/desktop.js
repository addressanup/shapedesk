// The hero playground: pretend desktop icons driven by the same shape math
// and status messages as the app's menu bar panel (ViewModel.swift).

import { SHAPES, shapePoints, fit, medianSpacing, gridPoints } from './geometry.js';
import { textPoints } from './text-shape.js';

const NAMES = [
  'Screenshots', 'Invoices', 'Recipes', 'taxes 2025', 'untitled folder', 'untitled folder 2',
  'Old Desktop', 'side project', 'final', 'final FINAL', 'Receipts', 'design refs', 'memes',
  'Resume', 'Projects', 'To sort', 'Music stems', 'Keynote assets', 'Travel', 'Fonts',
  'Client work', 'Archive', 'Drafts', 'Misc', 'School', 'Logos', 'Mockups', 'Podcast', 'Notes',
  'Videos', 'Backups', '3D prints', 'Wallpapers', 'Sketches', 'Reading', 'Photos 2024',
  'Wedding', 'Inbox', 'Budget', 'Plants',
].sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' }));

// FinderBridge animates 14 smoothstep frames in about 1.2 s.
const DURATION = 1200;
const TITLES = Object.fromEntries(SHAPES.map((s) => [s.id, s.title]));

export function initDesktop() {
  const desktop = document.getElementById('top');
  const stage = document.getElementById('stage');
  const layer = document.getElementById('icons');
  const panel = document.getElementById('panel');
  const status = document.getElementById('status');
  const countLabel = document.getElementById('icon-count');
  const noteCount = document.getElementById('note-count');
  const sizeInput = document.getElementById('size');
  const animateInput = document.getElementById('animate');
  const spellForm = document.getElementById('spell-form');
  const spellInput = document.getElementById('spell-input');
  const actions = panel.querySelectorAll('[data-shape], #spell-form button, #reset');

  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
  if (reduceMotion.matches) animateInput.checked = false;

  let icons = [];
  let arrangement = { type: 'grid' };
  let busy = false;
  let frame = 0;
  let finishAnimation = null;
  let introTimer = 0;
  const textCache = new Map();

  const setStatus = (text) => { status.textContent = text; };

  const setBusy = (value) => {
    busy = value;
    actions.forEach((b) => { b.disabled = value; });
  };

  function metrics() {
    const d = desktop.getBoundingClientRect();
    const s = stage.getBoundingClientRect();
    // Measured rather than read from --icon, which is a clamp() expression.
    const first = icons[0]?.el;
    const art = first?.firstElementChild;
    return {
      rect: { x: s.left - d.left, y: s.top - d.top, width: s.width, height: s.height },
      bounds: { width: d.width, height: d.height },
      icon: art ? art.getBoundingClientRect().width - 4 : 32,
      cell: first ? first.getBoundingClientRect().width : 68,
    };
  }

  function place(icon, m) {
    const artCenter = 2 + (m.icon * 0.8125) / 2;
    icon.el.style.transform = `translate3d(${icon.x - m.cell / 2}px, ${icon.y - artCenter}px, 0)`;
  }

  function makeIcon(name) {
    const el = document.createElement('div');
    el.className = 'icon';
    el.innerHTML = '<svg class="icon__art" viewBox="0 0 64 52"><use href="#folder"/></svg><span class="icon__label"></span>';
    el.lastElementChild.textContent = name;
    return { el, name, x: 0, y: 0 };
  }

  /** Narrow desktops get fewer icons so shapes don't turn into a pile. */
  function syncIconCount() {
    const n = stage.getBoundingClientRect().width < 520 ? 30 : 40;
    if (icons.length === n) return false;
    layer.replaceChildren();
    icons = NAMES.slice(0, n).map(makeIcon);
    icons.forEach((icon) => layer.append(icon.el));
    countLabel.textContent = `${n} icons`;
    noteCount.textContent = String(n);
    return true;
  }

  function targetsFor(arr, m) {
    const n = icons.length;
    const fill = parseFloat(sizeInput.value);
    switch (arr.type) {
      case 'grid':
        return gridPoints(icons.map((i) => i.name), m.rect, m.cell * 1.08, {
          x: m.cell / 2,
          y: m.icon * 0.42 + 4,
        });
      case 'shape':
        return shapePoints(arr.kind, n, m.rect, fill);
      case 'text': {
        const aspect = m.rect.width / Math.max(m.rect.height, 1);
        const key = `${arr.text}|${n}|${aspect.toFixed(2)}`;
        if (!textCache.has(key)) textCache.set(key, textPoints(arr.text, n, aspect));
        return fit(textCache.get(key), m.rect, fill);
      }
      default:
        return icons.map((i) => ({ x: i.x, y: i.y }));
    }
  }

  function labelFor(arr) {
    if (arr.type === 'grid') return 'a tidy grid';
    if (arr.type === 'text') return `"${arr.text}"`;
    return TITLES[arr.kind];
  }

  function summary(arr, targets, m) {
    const n = icons.length;
    let text = `Arranged ${n} icons into ${labelFor(arr)}.`;
    if (arr.type === 'text') {
      const letters = Array.from(arr.text).filter((c) => !/\s/.test(c)).length;
      const perLetter = Math.floor(n / Math.max(letters, 1));
      if (perLetter < 7) {
        text += ` That's only about ${perLetter} icons per letter, so a shorter word will read better.`;
      }
    }
    if (arr.type !== 'grid' && medianSpacing(targets) < m.icon) {
      text += ' Some icons may overlap — try a bigger Size.';
    }
    return text;
  }

  function arrange(arr, { animated = animateInput.checked && !reduceMotion.matches } = {}) {
    if (busy) return;
    const m = metrics();
    const targets = targetsFor(arr, m);
    if (targets.length !== icons.length) {
      setStatus(`Couldn't build enough points for ${icons.length} icons.`);
      return;
    }
    arrangement = arr;
    const message = summary(arr, targets, m);

    if (!animated) {
      icons.forEach((icon, k) => { icon.x = targets[k].x; icon.y = targets[k].y; place(icon, m); });
      setStatus(message);
      return;
    }

    setBusy(true);
    setStatus(`Moving ${icons.length} icons…`);
    const from = icons.map((i) => ({ x: i.x, y: i.y }));
    const start = performance.now();
    finishAnimation = () => {
      cancelAnimationFrame(frame);
      finishAnimation = null;
      setBusy(false);
      setStatus(message);
    };
    const step = (now) => {
      const t = Math.min((now - start) / DURATION, 1);
      const eased = t * t * (3 - 2 * t); // smoothstep
      icons.forEach((icon, k) => {
        icon.x = from[k].x + (targets[k].x - from[k].x) * eased;
        icon.y = from[k].y + (targets[k].y - from[k].y) * eased;
        place(icon, m);
      });
      if (t < 1) frame = requestAnimationFrame(step);
      else finishAnimation?.();
    };
    frame = requestAnimationFrame(step);
  }

  /** Re-fits the current arrangement without animating (resize, Size slider). */
  function refit({ announce = false } = {}) {
    finishAnimation?.();
    if (arrangement.type === 'free') {
      // Keep dragged icons on screen after the desktop shrinks.
      const m = metrics();
      icons.forEach((icon) => {
        icon.x = Math.min(Math.max(icon.x, m.cell / 2), m.bounds.width - m.cell / 2);
        icon.y = Math.min(Math.max(icon.y, m.icon), m.bounds.height - m.icon);
        place(icon, m);
      });
      return;
    }
    const previous = status.textContent;
    arrange(arrangement, { animated: false });
    if (!announce) setStatus(previous);
  }

  // Panel ------------------------------------------------------------------

  // Anything the visitor does takes over from the intro.
  panel.addEventListener('pointerdown', () => clearTimeout(introTimer));
  panel.addEventListener('keydown', () => clearTimeout(introTimer));

  panel.querySelectorAll('[data-shape]').forEach((button) => {
    button.addEventListener('click', () => arrange({ type: 'shape', kind: button.dataset.shape }));
  });

  spellForm.addEventListener('submit', (e) => {
    e.preventDefault();
    clearTimeout(introTimer);
    if (busy) return;
    const text = spellInput.value;
    if (!text.trim()) {
      setStatus('Type something first.');
      return;
    }
    setStatus(`Rendering "${text}"…`);
    // Let the status paint before the (brief) text rasterizing work.
    setTimeout(() => arrange({ type: 'text', text }), 30);
  });

  document.getElementById('reset').addEventListener('click', () => arrange({ type: 'grid' }));

  document.getElementById('refresh').addEventListener('click', () => {
    if (!busy) setStatus(`Found ${icons.length} desktop icons.`);
  });

  sizeInput.addEventListener('input', () => {
    if (!busy) refit({ announce: true });
  });

  // Selecting and dragging icons -------------------------------------------

  let selected = null;
  const select = (icon) => {
    selected?.el.classList.remove('is-selected');
    selected = icon;
    icon?.el.classList.add('is-selected');
  };

  desktop.addEventListener('pointerdown', (e) => {
    if (!e.target.closest('.icon, .panel')) select(null);
  });

  layer.addEventListener('pointerdown', (e) => {
    const el = e.target.closest('.icon');
    if (!el) return;
    const icon = icons.find((i) => i.el === el);
    select(icon);
    clearTimeout(introTimer);
    if (e.pointerType === 'touch' || busy || e.button !== 0) return;

    e.preventDefault();
    el.setPointerCapture(e.pointerId);
    el.classList.add('is-dragging');
    const m = metrics();
    const dx = e.clientX - icon.x;
    const dy = e.clientY - icon.y;
    const move = (ev) => {
      icon.x = Math.min(Math.max(ev.clientX - dx, m.cell / 2), m.bounds.width - m.cell / 2);
      icon.y = Math.min(Math.max(ev.clientY - dy, m.icon), m.bounds.height - m.icon);
      place(icon, m);
      arrangement = { type: 'free' };
    };
    const end = () => {
      el.classList.remove('is-dragging');
      el.removeEventListener('pointermove', move);
      el.removeEventListener('pointerup', end);
      el.removeEventListener('pointercancel', end);
    };
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerup', end);
    el.addEventListener('pointercancel', end);
  });

  // Layout -----------------------------------------------------------------

  let resizeQueued = false;
  const resizes = new ResizeObserver(() => {
    if (resizeQueued) return;
    resizeQueued = true;
    requestAnimationFrame(() => {
      resizeQueued = false;
      if (syncIconCount() && arrangement.type === 'free') arrangement = { type: 'grid' };
      refit();
    });
  });
  // The stage can change size on its own, e.g. when the headline font loads.
  resizes.observe(desktop);
  resizes.observe(stage);

  syncIconCount();
  arrange({ type: 'grid' }, { animated: false });
  setStatus('Click a shape to arrange your desktop.');

  // Start in Finder's grid, then show what the app does.
  introTimer = setTimeout(() => arrange({ type: 'shape', kind: 'heart' }), 900);
}
