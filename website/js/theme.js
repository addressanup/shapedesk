// Apply the theme before first paint. Only a color preference is persisted;
// account credentials are managed separately and never enter storage.
(() => {
  const key = 'shapedesk.theme';
  const root = document.documentElement;
  const system = window.matchMedia('(prefers-color-scheme: dark)');
  const normalize = value => value === 'light' || value === 'dark' ? value : 'system';
  let preference = 'system';
  try { preference = normalize(localStorage.getItem(key)); } catch { /* Storage may be blocked. */ }

  function apply() {
    const theme = preference === 'system' ? (system.matches ? 'dark' : 'light') : preference;
    root.dataset.theme = theme;
    root.dataset.themePreference = preference;
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', theme === 'dark' ? '#171816' : '#f5f5f3');
    document.querySelectorAll('[data-theme-select]').forEach(select => {
      select.value = preference;
      select.title = `Color theme: ${preference === 'system' ? `System (${theme})` : theme}`;
    });
  }

  apply();
  document.addEventListener('DOMContentLoaded', () => {
    document.querySelectorAll('[data-theme-select]').forEach(select => {
      select.addEventListener('change', () => {
        preference = normalize(select.value);
        try {
          if (preference === 'system') localStorage.removeItem(key);
          else localStorage.setItem(key, preference);
        } catch { /* The control still works for this page. */ }
        apply();
      });
    });
    apply();
  }, { once: true });
  system.addEventListener('change', () => { if (preference === 'system') apply(); });
  window.addEventListener('storage', event => {
    if (event.key === key || event.key === null) {
      preference = normalize(event.newValue);
      apply();
    }
  });
  window.addEventListener('pageshow', () => {
    try { preference = normalize(localStorage.getItem(key)); } catch { /* Keep the in-memory choice. */ }
    apply();
    // History can restore form values after pageshow, including on a fresh load.
    // Resync the selector after that restoration without changing the page theme.
    window.requestAnimationFrame(apply);
  });
})();
