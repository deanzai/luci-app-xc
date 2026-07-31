# AGENTS.md — luci-app-xc

## Project

OpenWrt/ImmortalWrt LuCI plugin for managing and switching self-hosted Xray nodes. Targets 21.02–24.10. Lua 5.1 only.

## Architecture

```
root/usr/lib/lua/xc/     — Core runtime modules (pure Lua 5.1)
  schema.lua              — Node validation, normalization, protocol registry
  platform.lua            — FS/ UCI/ exec/ JSON adapters (injectable for tests)
  runtime.lua             — Node switch, rollback, transaction, health check
  generator.lua           — Xray config.json renderer
  importer.lua            — Share-link / JSON import parser
  probe.lua               — Per-node TCP/TLS/WS latency probe
  logview.lua             — XC + Xray log merge and level filter
  cli.lua                 — /usr/bin/xc CLI entrypoint
luasrc/controller/xc.lua  — LuCI controller (actions, JSON API)
luasrc/model/cbi/xc/      — CBI models: settings, nodes, node, log
luasrc/view/xc/           — CBI view templates (.htm)
root/etc/init.d/xc        — procd init script
root/usr/bin/xc           — CLI wrapper (calls xc.cli)
tests/                    — Host-run test suite
scripts/                  — bootstrap-lua.sh, check-package.sh
po/                       — gettext catalogs (en + zh_Hans)
```

Controller delegates to `platform.new()` → `runtime_module.new(adapters)`. All IO goes through the platform adapter so runtime logic stays testable.

## Development Commands

```sh
# One-time: build local Lua 5.1.5 binary
sh scripts/bootstrap-lua.sh

# Full host verification (Lua tests + Node UI tests + package check)
sh tests/run-host.sh

# Run only Lua tests
./.tools/lua5.1 tests/run.lua

# Run a single Lua test file
./.tools/lua5.1 tests/test_runtime.lua

# Package structure + translation + CRLF check
sh scripts/check-package.sh

# Build IPK (inside OpenWrt SDK/Buildroot)
make package/luci-app-xc/compile V=s
```

`run-host.sh` requires `lua5.1` (or `.tools/lua5.1`) and `node`. It runs Lua tests, three Node.js UI tests, the package check, and a po2lmo build check.

## Testing

- Lua tests use `testlib` (in `tests/testlib.lua`): `M.test(name, fn)`, `M.eq`, `M.truthy`, `M.contains`, then `M.finish()`.
- Test files must match `tests/test_*.lua` to be auto-discovered by `run.lua`.
- Node.js tests use DOM emulation for LuCI page behavior (XHR, button state, log rendering).
- Platform adapter functions are injected — tests pass mock `nixio`, `uci`, `jsonc` instead of real syscalls.
- `scripts/check-package.sh` enforces: no CRLF, every `_(...)` string appears in `po/templates/xc.pot` and `po/zh_Hans/xc.po`, no empty/untranslated zh entries, build matrix covers both 21.02 and 24.10.

## Constraints

- **Lua 5.1 only** — no `//` integer division, no `goto`, no `continue`, no `#` length on tables, no generics. Use `unpack` (or `table.unpack` fallback).
- **No implicit global `call()`** in controllers — ucode bridge doesn't provide it. Use `call(action_fn)` via `entry()` which returns a callable.
- **No CRLF** anywhere in source — `check-package.sh` rejects it.
- **CBI datatype** — 21.02 lacks `url` token; use custom `validate()` for complex inputs.
- **Config save ≠ node switch** — "Save & Apply" is CBI config management. The "Switch" button triggers a separate runtime transaction (validate → render → restart → health check → commit/rollback).
- **File permissions** — `/etc/config/xc` 0600, `/etc/xc` 0700, `/etc/xc/rollback` 0700. Enforced in init script and UCI commit.
- **No secrets in logs** — never log UUIDs, passwords, tokens, raw outbound JSON, or full share links. Log only node internal ID, outcome, stable error codes, and timing.
- **Translation sync** — every user-visible string uses `_()`. The pot/po catalogs must exactly match the source strings (enforced by check-package.sh). Regenerate after UI text changes.

## Build & Release

- CI: GitHub Actions runs `test` → `build-21_02` + `build-24_10` (sequential).
- IPKs are artifacts, not committed (`*.ipk` in `.gitignore`).
- Version: `PKG_VERSION` + `PKG_RELEASE` in Makefile. PO version is `$(PKG_VERSION)-r$(PKG_RELEASE)`.
- 21.02 build compat: old `luci.mk` may ignore `PKG_RELEASE`; build copies may temporarily inline the full version string but this must not be committed.

## Current Work

Active development in the `implement-luci-app-xc` worktree: adding Xray-core manual replacement (upload → validate → activate → rollback) without overwriting `/usr/bin/xray`. See `docs/superpowers/plans/2026-07-31-xray-core-replacement-plan.md`.
