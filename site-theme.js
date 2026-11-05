(() => {
  const key = 'afterhours-site-theme';
  const media = window.matchMedia('(prefers-color-scheme: light)');
  function preference() {
    try { return localStorage.getItem(key) || 'current'; }
    catch { return 'current'; }
  }
  function apply() {
    const selected = preference();
    const mode = selected === 'current' ? (media.matches ? 'light' : 'dark') : selected;
    document.documentElement.dataset.siteTheme = mode;
    document.documentElement.dataset.siteThemePreference = selected;
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', mode === 'light' ? '#f4f6f2' : '#0b0f0e');
  }
  window.setAfterhoursSiteTheme = (selected) => {
    if (!['current', 'light', 'dark'].includes(selected)) return;
    try { localStorage.setItem(key, selected); }
    catch { /* The choice still applies for this page if storage is unavailable. */ }
    apply();
  };
  apply();
  media.addEventListener?.('change', () => { if (preference() === 'current') apply(); });
  window.addEventListener('storage', (event) => { if (event.key === key) apply(); });
})();
