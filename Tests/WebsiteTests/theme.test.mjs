import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../website/js/theme.js', import.meta.url), 'utf8');
const key = 'shapedesk.theme';

function page({ storage = new Map(), dark = false, blocked = false } = {}) {
  const events = {};
  const dataset = {};
  const meta = {};
  const select = { value: 'system', addEventListener: (_, fn) => { select.change = fn; } };
  const media = { matches: dark, addEventListener: (_, fn) => { media.change = fn; } };
  let paint = () => {};
  let ready = false;
  const listen = (name, fn) => { events[name] = fn; };
  vm.runInNewContext(source, {
    window: { matchMedia: () => media, addEventListener: listen, requestAnimationFrame: fn => { paint = fn; } },
    document: {
      documentElement: { dataset },
      querySelector: () => ({ setAttribute: (name, value) => { meta[name] = value; } }),
      querySelectorAll: () => ready ? [select] : [],
      addEventListener: listen,
    },
    localStorage: {
      getItem: k => { if (blocked) throw new Error('Blocked'); return storage.get(k) ?? null; },
      setItem: (k, value) => { if (blocked) throw new Error('Blocked'); storage.set(k, value); },
      removeItem: k => { if (blocked) throw new Error('Blocked'); storage.delete(k); },
    },
  });
  return {
    dataset, meta, select, events,
    ready() { ready = true; events.DOMContentLoaded(); },
    choose(value) { select.value = value; select.change(); },
    system(value) { media.matches = value; media.change(); },
    paint() { paint(); },
  };
}

test('saved choices apply before controls mount and persist into the next page', () => {
  const storage = new Map([[key, 'dark']]);
  const first = page({ storage });
  assert.equal(first.dataset.theme, 'dark');
  assert.equal(first.meta.content, '#171816');
  first.ready();
  assert.equal(first.select.value, 'dark');
  first.choose('light');
  const next = page({ storage, dark: true });
  assert.equal(next.dataset.theme, 'light');
  assert.deepEqual([...storage], [[key, 'light']]);
});

test('System follows OS changes, explicit choices override them, and System resets the override', () => {
  const storage = new Map();
  const view = page({ storage, dark: true });
  view.ready();
  assert.equal(view.dataset.theme, 'dark');
  view.system(false);
  assert.equal(view.dataset.theme, 'light');
  view.choose('dark');
  view.system(false);
  assert.equal(view.dataset.theme, 'dark');
  view.choose('system');
  assert.equal(storage.has(key), false);
  assert.equal(view.dataset.theme, 'light');
  view.system(true);
  assert.equal(view.dataset.theme, 'dark');
  assert.equal(view.select.value, 'system');
});

test('theme changes still work when browser storage is unavailable', () => {
  const view = page({ blocked: true });
  view.ready();
  view.choose('dark');
  view.events.pageshow({ persisted: true });
  assert.equal(view.dataset.theme, 'dark');
  assert.equal(view.select.value, 'dark');
});

test('tabs and restored pages synchronize preferences without accepting invalid values', () => {
  const storage = new Map([[key, 'invalid']]);
  const view = page({ storage });
  view.ready();
  assert.equal(view.dataset.themePreference, 'system');
  view.events.storage({ key: 'unrelated', newValue: 'dark' });
  assert.equal(view.dataset.theme, 'light');
  view.events.storage({ key, newValue: 'dark' });
  assert.equal(view.select.value, 'dark');
  view.events.storage({ key: null, newValue: null });
  assert.equal(view.dataset.themePreference, 'system');
  storage.set(key, 'dark');
  view.events.pageshow({ persisted: true });
  assert.equal(view.dataset.theme, 'dark');
});

test('browser Back cannot leave a restored select value out of sync with the theme', () => {
  const storage = new Map([[key, 'light']]);
  const view = page({ storage });
  view.ready();
  view.events.pageshow({ persisted: false });
  view.select.value = 'dark'; // The browser restores the previous form value.
  view.paint();
  assert.equal(view.select.value, 'light');
  assert.equal(view.dataset.theme, 'light');
});
