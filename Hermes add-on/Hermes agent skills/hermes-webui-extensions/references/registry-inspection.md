# Inspecting the Hermes WebUI extension registry

Use when you need to answer "does any extension do X?" / "does it store anything
server-side?" without installing anything.

## Fetch

```bash
curl -sL --max-time 25 \
  https://hermes-webui.github.io/hermes-webui-extensions/registry.json \
  -o /tmp/registry.json
```

Then read `/tmp/registry.json` with `read_file` (it is large; it may need paging).
Avoid `python3 -c "..."` one-liners for parsing: the shell security scan flags `-c`
execution and auto-approval is not guaranteed. Use `execute_code` to parse, or read
the file and scan it.

For the live entry list (registry snapshots lag), fetch:

```
https://raw.githubusercontent.com/hermes-webui/hermes-webui-extensions/main/extensions/README.md
```

## Shape

Top level: `{ version, generated_at, extensions: [ ... ] }`.

Per entry, the fields that answer storage/sync questions:

| Field | Meaning |
|---|---|
| `capabilities` | list; `manifest-bundle`, and `loopback-sidecar` for sidecar-backed entries |
| `sidecar` | present only for sidecar entries: `origin`, `health_path`, `proxy_auth`, `runtime` |
| `permissions.storage.owned` | localStorage keys it may write — **browser-local** |
| `permissions.webui_api.write` | server API paths it may call; `settings` = core server prefs |
| `permissions.dom` | `owned` / `mutates_core_views` |
| `settings_schema` | declarative fields shown in Settings → Extensions (browser-persisted) |
| `permissions.filesystem` | `arbitrary` / `serves_bundled_assets` |
| `download`, `sha256` | artifact URL and integrity hash for install |

## Reading it

- **Server-backed state** requires `loopback-sidecar` in `capabilities` plus a `sidecar`
  block. Nothing else in the library persists server-side.
- `webui_api.write` containing `settings` means the extension can change core
  `settings.json` (and therefore sync).
- `permissions.storage.owned` non-empty with no sidecar means the data is browser-local
  and will not follow the user to another device.
- The installed package's `extension.json` mirrors these permissions — read it on disk
  to confirm what actually landed.
