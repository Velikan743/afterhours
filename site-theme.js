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
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', selected === 'light' ? '#f4f6f2' : selected === 'dark' ? '#000000' : '#242a31');
    const iconTheme = selected === 'light' ? 'light' : selected === 'dark' ? 'dark' : 'default';
    const iconPath = `assets/afterhours-favicon-${iconTheme}.png?v=2`;
    document.querySelector('#siteFavicon')?.setAttribute('href', iconPath);
    document.querySelectorAll('.brand-mark img').forEach((image) => image.setAttribute('src', iconPath));
  }
  window.setAfterhoursSiteTheme = (selected) => {
    if (!['current', 'light', 'dark'].includes(selected)) return;
    try { localStorage.setItem(key, selected); }
    catch { /* The choice still applies for this page if storage is unavailable. */ }
    apply();
  };
  apply();
  document.addEventListener('DOMContentLoaded', apply, { once: true });
  window.addEventListener('storage', (event) => { if (event.key === key) apply(); });
})();
