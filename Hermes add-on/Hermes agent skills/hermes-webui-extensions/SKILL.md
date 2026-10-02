---
name: hermes-webui-extensions
description: "Hermes WebUI extensions: create, enable, sync, diagnose."
version: 2.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [hermes, webui, extensions, plugins, create, manifests, sync, branding, sidecar]
---

# Hermes WebUI Extensions

## When to Use

Load this skill when the user asks to **create a new Hermes WebUI extension/plugin**, to **enable or modify an installed one**, to find out **why a WebUI change does not show on another device**, or to diagnose an installed extension. It is the WebUI counterpart to the bundled hermes-agent skill, which does not cover `webui/extensions`.

Hermes WebUI (`hermes dashboard`, state under `$HERMES_HOME/webui/`, repo often at `/root/hermes-webui`) is a Python + vanilla-JS app with **no build step**. Extensions are **same-origin static assets** (JS/CSS) injected into the app shell and served by the WebUI itself; they run with full session authority, so review them like application code. This is a **different system** from Hermes agent plugins (`plugin-catalog`, `~/.hermes/plugins/`) and from desktop-app UI plugins.

Auth docs: `/root/hermes-webui/docs/EXTENSIONS.md`. Impl: `/root/hermes-webui/api/extensions.py`.

## Key paths

```
$HERMES_HOME/webui/extensions/<id>/                  installed pkg: extension.json, manifest.json, assets/
$HERMES_HOME/webui/extension-install-manifest.json   WHAT THE SERVER ACTUALLY LOADS (gallery installs)
$HERMES_HOME/webui/extension-overrides.json          enable/disable overrides
$HERMES_HOME/webui/settings.json                     core prefs — server-side, shared by all browsers
WEBUI_REPO/static/index.html                         app shell: favicon <link>s, titlebar + empty-state SVGs
WEBUI_REPO/api/extensions.py                         loader; _REGISTRY_URL points at the gallery registry
WEBUI_REPO/api/config.py                             STATE_DIR, SETTINGS_FILE resolution
WEBUI_REPO/static/extension_settings.js              extension settings/storage bridge
WEBUI_REPO/docs/EXTENSIONS.md                        authoritative contract
```

Resolve `$HERMES_HOME` profile-aware; never hardcode `~/.hermes`. STATE_DIR = `HERMES_WEBUI_STATE_DIR` env or `$HERMES_HOME/webui`; extensions dir = `HERMES_WEBUI_EXTENSION_DIR` env or `$STATE_DIR/extensions`. Server: `python3 server.py`, port `HERMES_WEBUI_PORT` (default 8787).

## Part 1 — CREATE a new extension

### Anatomy

```
$STATE_DIR/extensions/<ext-id>/
├── extension.json   # metadata + permissions (gallery schema)
├── manifest.json    # runtime: what scripts/styles to inject
└── assets/          # everything else, served at /extensions/<ext-id>/...
```

`extension.json` key fields:
```json
{
  "id": "my-ext", "name": "...", "description": "...", "version": "0.1.0",
  "assets": { "scripts": ["assets/ext.js"], "stylesheets": ["assets/ext.css"] },
  "capabilities": ["manifest-bundle"],          // add "loopback-sidecar" for a sidecar
  "lifecycle": { "webui_restart_required": false, "sidecar_start_required": false, "native_host_start_required": false, "native_host_autostart": "none" },
  "permissions": {
    "webui_api": { "read": [], "write": [] },  // API endpoints the ext may call
    "webui_navigation": false,
    "dom": { "owned": true, "mutates_core_views": true },
    "storage": { "owned": ["my-key"], "shared_webui_keys": [] },  // localStorage keys
    "loopback_sidecar": false, "native_host": false,
    "filesystem": { "arbitrary": false, "serves_bundled_assets": true },
    "network_external": false,
    "registers_skin": false                       // true: appears in Settings → Appearance
  }
}
```
`manifest.json` (gallery-installed runtime form): `{ "extensions": [ { "id": "my-ext", "name": "...", "description": "...", "scripts": ["assets/ext.js"], "stylesheets": ["assets/ext.css"] } ] }`

### Enable — THE critical step

Creating files is NOT enough: the server builds its runtime list from `extension-install-manifest.json` (`_gallery_installed_runtime_manifest()` in `api/extensions.py`). To enable:
1. Create the folder + both manifests + assets.
2. Add to `$STATE_DIR/extension-install-manifest.json`:
   `installed["<ext-id>"] = { "version": "0.1.0", "files": ["extension.json", "manifest.json", ...], "installed_at": "<ISO>" }`
3. Manifest is read fresh every request (no cache) → **no server restart needed**; a page refresh picks it up.
4. Alternative: `HERMES_WEBUI_EXTENSION_DIR` + `HERMES_WEBUI_EXTENSION_MANIFEST` env vars.

### Static serving + CSP

- Any file in the extension dir is served at `/extensions/<ext-id>/<path>` (`serve_extension_static()`).
- MIME map (`_EXTENSION_MIME`): css, js, html, svg, png, jpg/jpeg, ico, gif, webp, woff/woff2, ttf, otf, wasm.
- Responses are `Cache-Control: no-store` → file replacement is picked up immediately (still add `?v=` to favicon/logo URLs).
- CSP (`api/helpers.py`): `img-src 'self' data: https: blob:`, `connect-src 'self' http://127.0.0.1:* http://localhost:* ...`. Same-origin `/extensions/` images/JS are fine; external `https:` images allowed.
- `/extensions/` REQUIRES an authenticated session (not in the public path list) → unauthenticated curl gets 302 → `/login`. That is normal, not a bug.

### Making an appearance change apply to EVERY device

1. **Server-side core setting** — if the knob exists in `settings.json` (tabs, skin name, theme, composer controls), it already syncs; set it once on the server.
2. **Static files in the extension folder** (simplest server-side pattern, no process): the extension reads a server config file (the `brand.json` pattern) via `fetch('/extensions/<id>/brand.json', {cache:'no-store'})` and references images by relative path from the same folder. Admin replaces files/JSON on the server → every client sees it. Zero localStorage, no sidecar.
3. **Loopback sidecar** (the `profile-avatars` pattern): vendored python process on `127.0.0.1:<port>` declared in extension.json; the browser reaches it via the fixed proxy path `/api/extensions/<id>/sidecar/<path>` after `sidecar-proxy-consent`. Use when the extension needs a real backend (storage, external APIs, filesystem).
4. **Patch core static files** — replace favicon `<link>`s and SVGs in `WEBUI_REPO/static/index.html`. Global, but **overwritten on WebUI upgrade** — state the caveat.

### Client-side JS essentials (learned from custom-branding + peai-su)

- **Guard double injection**: `if (window.__myExtLoaded) return; window.__myExtLoaded = true;`
- **UI re-renders constantly**: observe `document.body` with a MutationObserver (childList+subtree), re-apply on rAF-coalesced callback.
- **Theme flips**: core toggles `.dark` on `<html>`; observe `documentElement` class to re-swap dark/light assets. Skins set `data-skin` on the root.
- **Never clear state in a boot/refresh timer.** Old peai-su bug: on `load`, a timer set `appliedUrl = null` → logo flashed in then reverted. Refresh = recompute the URL and re-apply; never null it first.
- **Favicon swap**: neutralize core links (`rel=icon/shortcut icon/apple-touch-icon` → `rel="<ext>-disabled-icon"`, remember original rel in a dataset attr), inject `<link rel="icon" sizes="any" type=...>`; browsers cache favicons hard — on href change, clone + `replaceWith` a fresh node.
- **Logo sizing**: match native marks (titlebar svg 16×16, `.empty-logo` svg 88×88). Inject `<img>` with `object-fit: contain` at fixed px so ANY source dimension fits.
- **Error resilience**: `img.onerror` → remove img, un-hide native svg (never show broken-image glyph).
- **Path safety on server config**: reject absolute/protocol-relative URLs and `..`/`.` segments for asset paths read from a server JSON.
- **Expose a debug API**: `window.MyExt = { version, refresh(), config() }`.

## Part 2 — Storage tiers (what users actually ask about)

Every "my change doesn't show up on my other computer" question is one of three tiers:

1. **Server-side core settings** — `webui/settings.json` via `/api/settings`. Sidebar tab visibility (`hidden_tabs`), `tab_order`, composer flags, `theme`, `skin`, `language`. Shared automatically by every browser on that server. If the sidebar differs across devices, the devices are probably pointed at *different servers*.
2. **Browser localStorage** — the default for extensions. Schema-driven settings are namespaced `hermes.ext.settings.<id>` / `hermes.ext.storage.<id>`; extensions may also write free-form keys. By design the backend stores no extension settings and exposes no generic settings write route. Per-browser only — this is why custom-branding, theme-creator, custom-avatar etc. never sync between computers.
3. **Loopback sidecar** — the only server-backed pattern in the library. Data held by the sidecar process syncs across devices.

**Pointer-vs-payload trap:** an extension can persist a *reference* server-side without the payload. A custom skin is the canonical case — only the skin *name* goes to `settings.json`; the definition lives in localStorage, so on a fresh device the name resolves to the default.

## Diagnose a storage/sync question

Answer from the code, never from the extension's description:
1. Read `$HERMES_HOME/webui/extensions/<id>/extension.json` for `permissions`, and `assets/*.js` for behavior. Grep the JS for `localStorage`, `fetch(`, `/sidecar/`.
   - `localStorage` only → per-browser, no cross-device.
   - `permissions.loopback_sidecar: true` + sidecar writes → cross-device.
   - `permissions.webui_api.write` containing `settings` → writes core server settings.
2. To judge before installing, read the registry entry's `permissions.storage.owned`, `permissions.webui_api.write`, `capabilities`.

## Registry / gallery

- Registry JSON: `https://hermes-webui.github.io/hermes-webui-extensions/registry.json`
- Library repo: `hermes-webui/hermes-webui-extensions`; live list in `extensions/README.md`.
- Snapshots lag the repo — check `extensions/README.md` before concluding an extension does or does not exist.
- See `references/registry-inspection.md` for the fetch/parse recipe and field meanings.
- Appearance entries (custom-branding, theme-creator, typography, skin-pack, e-ink-skin, custom-avatar...) are ALL client-side/localStorage; only `profile-avatars` is server-synced (sidecar). Server-side branding was deliberately deferred to the extension model (PR #3307 closed as scope decision) — don't promise core changes.

## Verification WITHOUT an isolated instance (operator preference)

Do NOT spin up a second WebUI instance (STATE_DIR/PORT) to test — slow and noisy. Server-side readiness is checked headless: import `api.extensions` in a python shell, inspect `_load_manifest_with_status(_extension_root())`, `get_extension_config()`, `inject_extension_tags(html)`; `curl` assets (expect 302 unauthenticated). To verify client behavior on the live server, **ask the user to authenticate via the browser vault flow** (`browser_vault_list` / `browser_vault_fill` — credentials never pass through chat), then inspect the DOM (img src/present, computed sizes, favicon link, `.dark` swaps).

## Pitfalls

- Do not conflate Hermes agent plugins (plugin-catalog, `~/.hermes/plugins/`) with WebUI extensions (`~/.hermes/webui/`).
- Do not promise a "server-side appearance extension" exists — check the registry; appearance entries are predominantly localStorage-backed.
- Before saying settings "should already match" across devices, verify both hit the same server URL.
- Extension settings are not secrets and are not backend-stored; never route them through `.env`, never claim server persistence without a sidecar.
- Core WebUI has no server-side keys for logo/favicon; branding extensions are client-side by design.
- Creating extension files without updating `extension-install-manifest.json` = extension silently not loaded. Check there first.

## Checklist

1. extension.json + manifest.json in `$STATE_DIR/extensions/<id>/`
2. Entry added to `extension-install-manifest.json`
3. `extension.json` lint passes; JS passes `node --check`
4. Headless: `_load_manifest_with_status()` shows the ext; `inject_extension_tags()` emits its tags
5. Client: vault-authenticated browser check; `.dark` dark/light swap; reload keeps branding (no flash-revert)
