(() => {
  'use strict';

  // ── Peai-SU: server-side branding for Hermes WebUI ─────────────────────────
  // Reads brand.json from the SERVER (the extension's own folder), and applies
  // the referenced logo/favicon files, which are also served by the server at
  // /extensions/peai-su/... . No localStorage, no upload UI: replace the image
  // files on the server (or edit brand.json) to rebrand for every client.
  //
  // Replaces:
  //   - the app titlebar logo (.app-titlebar-icon > svg; native 16x16)
  //   - the empty-state hero logo (.empty-logo > svg; native 88x88)
  //   - the browser favicon (<link rel="icon"> nodes in <head>)
  //
  // ANY image size is adapted automatically: the injected <img> is sized by CSS
  // to exactly match the native mark it replaces and uses object-fit: contain,
  // so arbitrary dimensions never distort or break the layout.
  //
  // Theme awareness: the active logo follows the .dark class on <html> (the
  // core theme mechanism). When no dark variant is configured, the light logo
  // is used on both themes, so branding NEVER disappears on dark mode. The
  // boot/"load" path only ever refreshes the logo URL — it never clears it —
  // which fixes the old "logo flashes for a second then reverts to the default
  // mark on dark theme" bug.

  const EXT_ID = 'peai-su';
  if (window.__peaiSuBrandingLoaded) return;
  window.__peaiSuBrandingLoaded = true;

  const BASE = '/extensions/' + EXT_ID + '/';
  const CONFIG_URL = BASE + 'brand.json';

  // Core favicon <link> nodes we neutralize while a custom favicon is active.
  const FAVICON_SELECTOR = 'link[rel="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]';
  const LOGO_CONTAINERS = [
    { sel: '.app-titlebar-icon', size: 'titlebar' },
    { sel: '.empty-logo', size: 'hero' }
  ];

  let cfg = null;           // parsed brand.json
  let appliedUrl = null;    // URL of the logo currently shown in the DOM
  let observer = null;

  // ── brand.json loading ─────────────────────────────────────────────────────
  // No-store: the server sends Cache-Control: no-store for /extensions/ files,
  // so replacing brand.json or the images is picked up without cache busting.
  function loadConfig(cb) {
    try {
      fetch(CONFIG_URL, { cache: 'no-store' })
        .then((r) => (r.ok ? r.json() : Promise.reject(new Error('HTTP ' + r.status))))
        .then((data) => { cb(validateConfig(data)); })
        .catch(() => cb(null));
    } catch (_) { cb(null); }
  }

  // Path safety: only accept relative paths that point INSIDE our own assets/
  // folder. Reject absolute URLs, protocol-relative URLs, and any traversal.
  function isSafeAssetPath(p) {
    if (typeof p !== 'string' || !p) return false;
    if (/^[a-z][a-z0-9+.-]*:/i.test(p) || p.startsWith('//')) return false;
    const parts = p.split('/');
    if (parts.some((seg) => seg === '..' || seg === '.')) return false;
    return true;
  }

  function validateConfig(raw) {
    if (!raw || typeof raw !== 'object') return null;
    if (raw.enabled === false) return null;
    const out = { light: null, dark: null, favicon: null, version: 0 };
    const apply = Array.isArray(raw.apply_to) ? raw.apply_to : [];
    const wantLogo = apply.length === 0 || apply.includes('titlebar') || apply.includes('empty_state');
    const wantFav = apply.length === 0 || apply.includes('favicon');

    if (raw.logo && wantLogo) {
      if (raw.logo.light && isSafeAssetPath(raw.logo.light)) out.light = raw.logo.light;
      if (raw.logo.dark && isSafeAssetPath(raw.logo.dark)) out.dark = raw.logo.dark;
      if (!out.light && typeof raw.logo === 'string' && isSafeAssetPath(raw.logo)) out.light = raw.logo;
    }
    if (raw.favicon && wantFav && isSafeAssetPath(raw.favicon)) out.favicon = raw.favicon;
    out.version = parseInt(raw.version, 10) || Date.now();
    if (!out.light && !out.favicon) return null; // nothing to apply
    return out;
  }

  // ── logo swap ───────────────────────────────────────────────────────────────
  function isDark() {
    try { return document.documentElement.classList.contains('dark'); } catch (_) { return false; }
  }

  // Dark variant when configured; the light logo is the universal fallback so
  // branding is preserved on BOTH themes even without a dark upload.
  function currentLogoPath() {
    if (!cfg) return null;
    if (cfg.dark && isDark()) return cfg.dark;
    return cfg.light;
  }

  function assetUrl(p) {
    return BASE + p + '?v=' + cfg.version;
  }

  function applyLogoToContainer(container, size) {
    if (!container) return;
    const nativeSvg = container.querySelector(':scope > svg');
    let img = container.querySelector(':scope > img.peai-su-logo-img');

    if (!appliedUrl) {
      // No configured logo → restore the native mark.
      if (img) { img.remove(); img = null; }
      if (nativeSvg && nativeSvg.style.display === 'none') nativeSvg.style.display = '';
      container.classList.remove('peai-su-logo-set');
      return;
    }

    if (!img || img.getAttribute('src') !== appliedUrl) {
      if (nativeSvg && nativeSvg.style.display !== 'none') nativeSvg.style.display = 'none';
      if (!img) {
        img = document.createElement('img');
        img.className = 'peai-su-logo-img peai-su-logo-' + size;
        img.alt = '';
        img.loading = 'eager';
        img.decoding = 'sync';
        // If an image fails to load (missing file, bad format), fall back to the
        // native mark instead of showing a broken-image glyph.
        img.addEventListener('error', () => {
          try { img.remove(); } catch (_) {}
          if (nativeSvg) nativeSvg.style.display = '';
          container.classList.remove('peai-su-logo-set');
        }, { once: true });
        container.appendChild(img);
      }
      img.src = appliedUrl;
      container.classList.add('peai-su-logo-set');
    }
  }

  function applyLogos() {
    if (!cfg || !cfg.light) return;
    LOGO_CONTAINERS.forEach(({ sel, size }) => {
      document.querySelectorAll(sel).forEach((container) => applyLogoToContainer(container, size));
    });
  }

  // ── favicon swap ───────────────────────────────────────────────────────────
  function faviconType(p) {
    if (/\.ico$/i.test(p)) return 'image/x-icon';
    if (/\.svg$/i.test(p)) return 'image/svg+xml';
    if (/\.jpe?g$/i.test(p)) return 'image/jpeg';
    if (/\.webp$/i.test(p)) return 'image/webp';
    if (/\.gif$/i.test(p)) return 'image/gif';
    return 'image/png';
  }

  function coreFaviconLinks() {
    return Array.from(document.querySelectorAll(FAVICON_SELECTOR))
      .filter((l) => l.dataset.peaiSuFavicon !== '1');
  }

  function applyFavicon() {
    const head = document.head || document.getElementsByTagName('head')[0];
    if (!head) return;
    let injected = head.querySelector('link[data-peai-su-favicon="1"]');

    if (cfg && cfg.favicon) {
      const href = assetUrl(cfg.favicon);
      const type = faviconType(cfg.favicon);
      // Neutralize core favicon <link>s (remember their rel so we can restore).
      coreFaviconLinks().forEach((l) => {
        if (l.dataset.peaiSuOrigRel === undefined) l.dataset.peaiSuOrigRel = l.getAttribute('rel') || '';
        l.setAttribute('rel', 'peai-su-disabled-icon');
      });
      if (!injected) {
        injected = document.createElement('link');
        injected.setAttribute('rel', 'icon');
        // sizes="any" lets the browser scale the image to whatever the tab/bar
        // needs, so a favicon of any dimensions adapts automatically.
        injected.setAttribute('sizes', 'any');
        injected.dataset.peaiSuFavicon = '1';
        head.appendChild(injected);
      }
      if (injected.getAttribute('href') !== href) {
        // Remove + re-add a fresh node so the browser refreshes the tab icon.
        const fresh = injected.cloneNode(false);
        fresh.setAttribute('href', href);
        fresh.setAttribute('type', type);
        injected.replaceWith(fresh);
        injected = fresh;
      }
    } else {
      if (injected) injected.remove();
      document.querySelectorAll('link[data-peai-su-orig-rel]').forEach((l) => {
        l.setAttribute('rel', l.dataset.peaiSuOrigRel || 'icon');
        delete l.dataset.peaiSuOrigRel;
      });
    }
  }

  function applyAll() {
    applyLogos();
    applyFavicon();
  }

  // Recompute the active logo file (theme may have changed / boot may have
  // finished) and re-apply. NEVER clears the logo — the old code nulled the URL
  // here, which is exactly what made the logo revert to the default mark.
  function refreshAndApply() {
    if (!cfg || !cfg.light) return;
    const next = assetUrl(currentLogoPath());
    if (next !== appliedUrl) appliedUrl = next;
    applyAll();
  }

  // ── theme / re-render observation ───────────────────────────────────────────
  let raf = false;
  function schedule() {
    if (raf) return;
    raf = true;
    requestAnimationFrame(() => { raf = false; try { applyAll(); } catch (_) {} });
  }

  function startObserver() {
    if (observer) return;
    try {
      observer = new MutationObserver(schedule);
      observer.observe(document.body, { childList: true, subtree: true });
    } catch (_) {}
  }

  function install() {
    loadConfig((valid) => {
      cfg = valid;
      if (!cfg) return; // disabled or misconfigured → leave the UI untouched
      appliedUrl = assetUrl(currentLogoPath());
      startObserver();
      applyAll();
      window.PeaiSuBranding = {
        version: '0.2.0',
        refresh: () => { if (cfg) { appliedUrl = assetUrl(currentLogoPath()); applyAll(); } },
        config: () => (cfg ? { ...cfg } : null)
      };
    });
  }

  // Core toggles .dark on <html>; watch it directly so the theme-correct logo is
  // applied the moment the theme flips (light <-> dark), with no revert.
  try {
    new MutationObserver(() => {
      if (!cfg || !cfg.light) return;
      const next = assetUrl(currentLogoPath());
      if (next !== appliedUrl) {
        appliedUrl = next;
        applyAll();
      }
    }).observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
  } catch (_) {}

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', install, { once: true });
  } else {
    install();
  }

  // Boot reconciliation: core applies theme/skin shortly after first paint.
  // Re-run once everything has settled so the theme-correct logo (dark or light)
  // is the one on screen. This only REFRESHES — it never resets to the default.
  window.addEventListener('load', () => {
    requestAnimationFrame(() => requestAnimationFrame(() => {
      try { refreshAndApply(); } catch (_) {}
    }));
    // Second pass: some boots settle the appearance slightly later.
    setTimeout(() => { try { refreshAndApply(); } catch (_) {} }, 600);
  }, { once: true });

  // Extra safety net for late re-renders of the app shell.
  setTimeout(() => { try { refreshAndApply(); } catch (_) {} }, 1500);
})();