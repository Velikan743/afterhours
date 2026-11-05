(() => {
  const key = 'afterhours-site-theme';
  function preference() {
    try { return localStorage.getItem(key) || 'current'; }
    catch { return 'current'; }
  }
  function apply() {
    const selected = preference();
    document.documentElement.dataset.siteTheme = selected;
    document.documentElement.dataset.siteThemePreference = selected;
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', selected === 'light' ? '#f4f6f2' : selected === 'dark' ? '#313338' : '#242a31');
  }
  window.setAfterhoursSiteTheme = (selected) => {
    if (!['current', 'light', 'dark'].includes(selected)) return;
    try { localStorage.setItem(key, selected); }
    catch { /* The choice still applies for this page if storage is unavailable. */ }
    apply();
  };
  apply();
  window.addEventListener('storage', (event) => { if (event.key === key) apply(); });
})();
