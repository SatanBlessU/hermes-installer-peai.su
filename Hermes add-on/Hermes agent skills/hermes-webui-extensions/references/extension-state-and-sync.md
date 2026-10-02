# Extension state and cross-device sync

Condensed model for answering "why doesn't this change appear on my other device?".

## The three stores

| Store | Path / mechanism | Syncs across devices? |
|---|---|---|
| Core WebUI prefs | `$HERMES_HOME/webui/settings.json` via `/api/settings` | Yes — per server |
| Extension settings/storage | browser localStorage (`hermes.ext.settings.<id>`, `hermes.ext.storage.<id>`, or custom keys) | No — per browser |
| Sidecar-held data | loopback process at `/api/extensions/<id>/sidecar/...` | Yes — per server |

`docs/EXTENSIONS.md` states the backend does not store extension settings or expose a
generic settings write route. That is why localStorage is the default and why a sidecar
is the only server-backed option.

## Deciding where a given change belongs

- Sidebar/tab visibility, tab order, theme, skin **name**, language, composer toggles
  → core `settings.json`; already global.
- Logo, favicon, per-user avatars, pinned items, favorites, custom theme definitions
  → localStorage in the shipped extensions; per-browser unless you patch core statics
  or add a sidecar.
- Anything that must be identical for every visitor and survive upgrades → an extension
  with a loopback sidecar, or a core static patch (accepting upgrade loss).

## Verifying what an install actually does

1. `extension.json` → `permissions`.
2. `assets/*.js` → grep `localStorage`, `fetch(`, `/sidecar/`.
3. Core boot reads `/api/settings` and reconciles with localStorage: the server is
   authoritative for empty first-visit state, localStorage wins for explicit user
   choices. So a browser with an explicit local choice can diverge from the server by
   design — expected, not a bug.
