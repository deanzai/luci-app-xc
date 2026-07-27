# luci-app-xc Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and publish `deanzai/luci-app-xc`, an Xray-only LuCI node manager that replaces the current `xc` script with safe CRUD, import, SSR Plus-style quick probes, validated switching, and rollback on OpenWrt/ImmortalWrt 21.02–24.10.

**Architecture:** Use legacy-compatible Lua controller/CBI/templates over a focused pure-Lua backend. Persist settings and nodes in UCI, generate runtime Xray JSON under `/var/etc/xc`, supervise Xray with procd, and keep `/usr/bin/xc` as the shared CLI. Keep parsing and generation pure for host tests; inject UCI, filesystem, process, clock, network, and JSON adapters into stateful runtime code.

**Tech Stack:** OpenWrt `luci.mk`, Lua 5.1, LuCI controller/CBI/templates, UCI, procd, Xray Core, nixio sockets, curl, POSIX shell, GitHub Actions.

---

## File map

- `Makefile`: OpenWrt package metadata, dependencies, conffiles, and pre-install legacy backup.
- `root/usr/lib/lua/xc/schema.lua`: node normalization, validation, safe identifiers, and duplicate fingerprints.
- `root/usr/lib/lua/xc/importer.lua`: old `nodes.json`, share URI, and raw outbound parsing.
- `root/usr/lib/lua/xc/generator.lua`: pure Lua-table Xray configuration generation.
- `root/usr/lib/lua/xc/runtime.lua`: UCI/files/process adapters, atomic render, switch, health check, rollback, migration, and logging.
- `root/usr/bin/xc`: stable CLI over the runtime module.
- `root/etc/init.d/xc`: procd service; `root/etc/config/xc`: defaults; hotplug and uci-default scripts complete lifecycle integration.
- `luasrc/controller/xc.lua`: authenticated JSON/action routes and SSR Plus-style quick-probe endpoint.
- `luasrc/model/cbi/xc/*.lua`: settings, node table, node editor, and logs.
- `luasrc/view/xc/*.htm`: status, probe queue, import preview, row latency, and log UI.
- `po/templates/xc.pot`, `po/zh_Hans/xc.po`: translations.
- `tests/*.lua`: host-side unit and adapter tests; `scripts/bootstrap-lua.sh` provides an unprivileged Lua 5.1 runtime in WSL.
- `.github/workflows/build.yml`: 21.02 and 24.10 package-build matrix.

### Task 1: Package skeleton and host test harness

**Files:**
- Create: `.gitignore`
- Create: `Makefile`
- Create: `root/etc/config/xc`
- Create: `scripts/bootstrap-lua.sh`
- Create: `tests/testlib.lua`
- Create: `tests/run.lua`
- Create: `tests/test_layout.lua`

- [ ] **Step 1: Add the failing package-layout test**

Create `tests/test_layout.lua`:

```lua
local t = require "testlib"

t.test("required package files exist", function()
  for _, path in ipairs({
    "Makefile", "root/etc/config/xc", "root/etc/init.d/xc",
    "root/usr/bin/xc", "luasrc/controller/xc.lua"
  }) do
    t.truthy(io.open(path, "r"), path .. " is missing")
  end
end)
```

Add `tests/run.lua` so it prepends `tests/?.lua;root/usr/lib/lua/?.lua;root/usr/lib/lua/?/init.lua` to `package.path`, requires every `tests/test_*.lua`, and exits nonzero when `testlib` records a failure. `tests/testlib.lua` must expose `test`, `eq`, `truthy`, `contains`, and `finish` with failure messages that name the test.

- [ ] **Step 2: Bootstrap Lua 5.1 and confirm the test fails**

Create `scripts/bootstrap-lua.sh`:

```sh
#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
version=5.1.5
archive="$root/.tools/lua-$version.tar.gz"
src="$root/.tools/lua-$version"
mkdir -p "$root/.tools"
[ -f "$archive" ] || curl -fL "https://www.lua.org/ftp/lua-$version.tar.gz" -o "$archive"
if [ ! -x "$root/.tools/lua5.1" ]; then
  rm -rf "$src"
  tar -xzf "$archive" -C "$root/.tools"
  make -C "$src" generic
  cp "$src/src/lua" "$root/.tools/lua5.1"
fi
"$root/.tools/lua5.1" -v
```

Run:

```sh
wsl sh -lc 'cd "/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）" && sh scripts/bootstrap-lua.sh && .tools/lua5.1 tests/run.lua'
```

Expected: FAIL listing the service, CLI, and controller as missing.

- [ ] **Step 3: Add minimal package metadata and defaults**

Use this dependency contract in `Makefile`:

```make
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-xc
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=deanzai <sd423498566@gmail.com>

LUCI_TITLE:=LuCI support for Xray node switching
LUCI_DEPENDS:=+luci-compat +lua +libuci-lua +luci-lib-jsonc +curl +ca-bundle +xray-core
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/xc
/etc/xc/
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
```

Create `root/etc/config/xc`:

```uci
config global 'global'
	option enabled '0'
	option active_node ''
	option listen_mode 'lan'
	option listen_address ''
	option socks_port '7890'
	option http_port '10809'
	option probe_concurrency '3'
	option probe_timeout '3'
	option probe_url 'https://www.gstatic.com/generate_204'
	option health_url 'https://api.ipify.org'
	option health_timeout '15'
```

Add `.tools/`, `bin/`, `*.ipk`, and test temporary files to `.gitignore`. Create these minimal valid files so the scaffold has executable entry points without claiming functionality:

```sh
# root/etc/init.d/xc
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
start_service() { return 0; }
```

```lua
#!/usr/bin/lua
-- root/usr/bin/xc
io.stderr:write("luci-app-xc backend is not implemented\n")
os.exit(2)
```

```lua
-- luasrc/controller/xc.lua
module("luci.controller.xc", package.seeall)
function index() end
```

- [ ] **Step 4: Run the harness and package static checks**

Run:

```sh
wsl sh -lc 'cd "/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）" && .tools/lua5.1 tests/run.lua && .tools/lua5.1 -e "assert(loadfile([[root/usr/bin/xc]]))" && sh -n root/etc/init.d/xc'
```

Expected: all layout tests PASS and both shell syntax checks exit 0.

- [ ] **Step 5: Commit the scaffold**

```sh
git add .gitignore Makefile root scripts tests luasrc/controller/xc.lua
git commit -m "chore: scaffold luci-app-xc package"
```

### Task 2: Node schema and validation

**Files:**
- Create: `root/usr/lib/lua/xc/schema.lua`
- Create: `tests/test_schema.lua`

- [ ] **Step 1: Write schema tests**

Cover these exact contracts:

```lua
local schema = require "xc.schema"

t.test("normalizes a VLESS Reality node", function()
  local node = assert(schema.normalize({
    id="node_1", name="UK", protocol="vless", server="host.example",
    port="443", uuid="11111111-1111-1111-1111-111111111111",
    security="reality", public_key="pub", short_id="ab", sni="www.example.com"
  }))
  t.eq(node.port, 443)
  t.eq(node.protocol, "vless")
end)

t.test("rejects unsafe section ids and ports", function()
  local _, err = schema.normalize({ id="node;reboot", protocol="socks", server="127.0.0.1", port=70000 })
  t.contains(err, "section")
end)

t.test("fingerprint ignores display name", function()
  local a = assert(schema.normalize({id="a",name="A",protocol="socks",server="h",port=1}))
  local b = assert(schema.normalize({id="b",name="B",protocol="socks",server="h",port=1}))
  t.eq(schema.fingerprint(a), schema.fingerprint(b))
end)
```

Also test required credentials for VLESS, VMess, Trojan, Shadowsocks, optional SOCKS username/password pairing, raw outbound JSON selection, supported transports, TLS/Reality required fields, IPv6/domain acceptance, and rejection of newline/control characters.

- [ ] **Step 2: Verify the schema tests fail**

Run `.tools/lua5.1 tests/run.lua` in WSL.

Expected: FAIL with `module 'xc.schema' not found`.

- [ ] **Step 3: Implement the schema API**

`xc.schema` must export:

```lua
normalize(node) -> normalized_node | nil, error
validate(node) -> true | nil, error
fingerprint(node) -> stable_lowercase_string
safe_section_id(value) -> boolean
supported_protocols -> { vless=true, vmess=true, trojan=true, shadowsocks=true, socks=true, raw=true }
```

Normalize protocol and host casing where safe, convert numeric fields, preserve secrets byte-for-byte after rejecting controls, and build duplicate fingerprints from protocol, lowercased server, port, and the protocol identity field (`uuid`, password/method tuple, SOCKS username, or canonical raw JSON hash input). Never include `name`, UCI section ID, or enabled state in the fingerprint.

- [ ] **Step 4: Run schema tests**

Run `.tools/lua5.1 tests/run.lua`.

Expected: all schema tests PASS.

- [ ] **Step 5: Commit**

```sh
git add root/usr/lib/lua/xc/schema.lua tests/test_schema.lua
git commit -m "feat: add Xray node schema validation"
```

### Task 3: Local import parsers

**Files:**
- Create: `root/usr/lib/lua/xc/importer.lua`
- Create: `tests/test_importer.lua`
- Create: `tests/fixtures/legacy-nodes.json`

- [ ] **Step 1: Write failing parser tests**

Define `importer.parse(text, json_adapter)` to return `{ nodes = {...}, warnings = {...} }` or `nil, error`. Test:

- VLESS Reality query mapping (`security`, `sni`, `pbk`, `sid`, `fp`, `flow`, `type`, `host`, `path`, `serviceName`);
- VMess base64 JSON mapping;
- Trojan, SIP002 Shadowsocks, `socks://`, and `socks5://` userinfo parsing;
- newline-separated mixed links;
- old `nodes.json` mapping `VLESS REALITY` and `NaiveProxy SOCKS5` without retaining `reality_uk_id`;
- a raw Xray outbound object;
- all-or-nothing failure for one malformed item;
- duplicate detection through `schema.fingerprint`.

Use a fake `json_adapter.parse` that returns fixture Lua tables so tests do not depend on host json-c.

- [ ] **Step 2: Verify parser tests fail**

Run `.tools/lua5.1 tests/run.lua`.

Expected: FAIL with `module 'xc.importer' not found`.

- [ ] **Step 3: Implement parsing without shelling out**

Implement pure-Lua percent decoding, URL authority parsing, query parsing, and base64 decoding. Export:

```lua
parse(text, json_adapter)
parse_uri(uri, json_adapter)
parse_legacy(table_value)
parse_outbound(table_value)
deduplicate(new_nodes, existing_nodes)
```

Limit input to 512 KiB, a maximum of 500 candidate nodes, and individual names to 128 UTF-8 bytes. Return warnings for skipped duplicates, never echo full source links in errors, and pass every result through `schema.normalize`.

- [ ] **Step 4: Run parser and full unit tests**

Run `.tools/lua5.1 tests/run.lua`.

Expected: parser fixtures and all prior tests PASS.

- [ ] **Step 5: Commit**

```sh
git add root/usr/lib/lua/xc/importer.lua tests/test_importer.lua tests/fixtures
git commit -m "feat: parse local Xray node imports"
```

### Task 4: Xray configuration generator

**Files:**
- Create: `root/usr/lib/lua/xc/generator.lua`
- Create: `tests/test_generator.lua`

- [ ] **Step 1: Write failing table-generation tests**

Tests must call `generator.build(global, node)` and assert Lua tables, not serialized JSON. Include:

```lua
t.test("builds compatible SOCKS and HTTP inbounds", function()
  local cfg = assert(generator.build({listen_address="192.168.6.1",socks_port=7890,http_port=10809}, vless))
  t.eq(cfg.inbounds[1].listen, "192.168.6.1")
  t.eq(cfg.inbounds[1].protocol, "socks")
  t.eq(cfg.inbounds[2].protocol, "http")
  t.eq(cfg.outbounds[1].tag, "proxy-selected")
end)
```

Add tests for VLESS/Reality, VLESS/TLS, VMess, Trojan, Shadowsocks, authenticated/unauthenticated SOCKS, raw outbound tag overriding, TCP/WS/gRPC transport fields, literal private-CIDR direct routing, and absence of any `reality_uk` or dedicated-domain outbound.

- [ ] **Step 2: Verify generator tests fail**

Run `.tools/lua5.1 tests/run.lua`.

Expected: FAIL with `module 'xc.generator' not found`.

- [ ] **Step 3: Implement deterministic generation**

Export `build(global, node)` and `build_outbound(node, tag)`. Always use tags `proxy-selected`, `direct`, and `block`; make selected outbound first so unmatched traffic uses it. Add SOCKS/HTTP inbounds with sniffing and no inbound authentication in v1. Direct only literal private/link-local CIDRs (`0.0.0.0/8`, `10.0.0.0/8`, `127.0.0.0/8`, `169.254.0.0/16`, `172.16.0.0/12`, `192.168.0.0/16`, `224.0.0.0/4`, `::1/128`, `fc00::/7`, `fe80::/10`) so generation does not depend on geo data; do not add ad blocking or special-node routing. For protocol/transport combinations not expressible by the structured schema, require `protocol=raw` and clone the supplied outbound table after replacing its tag.

- [ ] **Step 4: Run generator tests**

Run `.tools/lua5.1 tests/run.lua`.

Expected: all generator tests PASS.

- [ ] **Step 5: Commit**

```sh
git add root/usr/lib/lua/xc/generator.lua tests/test_generator.lua
git commit -m "feat: generate Xray runtime configurations"
```

### Task 5: Runtime switching, rollback, status, and logging

**Files:**
- Create: `root/usr/lib/lua/xc/runtime.lua`
- Create: `tests/test_runtime.lua`

- [ ] **Step 1: Define adapter fakes and failing state-machine tests**

Construct the runtime as:

```lua
local rt = runtime.new({
  uci=fake_uci, fs=fake_fs, exec=fake_exec, json=fake_json,
  network=function() return "192.168.6.1" end,
  now=function() return 123 end, sleep=function() end
})
```

Test exact transitions: render rejects missing/disabled active node; a sole enabled node is auto-selected; candidate config is JSON-encoded to a temporary path; `xray run -test` precedes restart; UCI `active_node` commits only after both SOCKS and HTTP health checks pass; failed validation never restarts; failed listener/health check restores the previous runtime config and UCI node; lock contention returns `busy`; rollback with no snapshot returns `no rollback state`; logs redact UUID/password/link content.

- [ ] **Step 2: Run and observe failure**

Run `.tools/lua5.1 tests/run.lua`.

Expected: FAIL with `module 'xc.runtime' not found`.

- [ ] **Step 3: Implement the injected runtime**

Export:

```lua
new(adapters) -> runtime_instance
runtime_instance:render(section_id, output_path)
runtime_instance:switch(section_id)
runtime_instance:rollback()
runtime_instance:status()
runtime_instance:test_current()
runtime_instance:log(message, fields)
```

Use `/var/lock/xc.lock`, `/var/etc/xc/config.json`, `/etc/xc/rollback/config.json`, `/etc/xc/rollback/active_node`, and `/var/log/xc.log`. Implement atomic writes as same-directory temporary write, mode `0600`, fsync/close, rename. Execute only constant command templates with shell-quoted paths/IDs. Switch order must match the approved design and return machine-readable `{ok, code, message}` tables.

- [ ] **Step 4: Run state-machine tests**

Run `.tools/lua5.1 tests/run.lua`.

Expected: all runtime and prior tests PASS.

- [ ] **Step 5: Commit**

```sh
git add root/usr/lib/lua/xc/runtime.lua tests/test_runtime.lua
git commit -m "feat: add safe Xray switching and rollback"
```

### Task 6: CLI, procd service, legacy migration, and lifecycle files

**Files:**
- Replace: `root/usr/bin/xc`
- Replace: `root/etc/init.d/xc`
- Create: `root/etc/hotplug.d/iface/95-xc`
- Create: `root/etc/uci-defaults/luci-xc`
- Modify: `Makefile`
- Create: `tests/test_migration.lua`

- [ ] **Step 1: Write migration and CLI contract tests**

Test conversion of the captured legacy shape: IDs `1..11`, VLESS Reality fields, SOCKS nodes, and `current=1`. Assert migration is idempotent, ignores `reality_uk_id`, creates a sole global section, and does not disable `xc-xray` when generated configuration validation fails.

Define CLI JSON output contracts for `status`, `switch <section>`, `rollback`, `test`, `render --output <path>`, `import-preview <path>`, `import <path>`, and `migrate-legacy <backup-dir>`. Invalid commands exit 2; runtime failures exit 1; success exits 0.

- [ ] **Step 2: Verify tests fail**

Run `.tools/lua5.1 tests/run.lua` and shell syntax checks.

Expected: migration tests FAIL because the minimal CLI does not implement migration.

- [ ] **Step 3: Implement lifecycle scripts**

The procd service must use this behavior:

```sh
start_service() {
	[ "$(uci -q get xc.global.enabled)" = "1" ] || return 0
	mkdir -p /var/etc/xc /var/log
	/usr/bin/xc render --output /var/etc/xc/config.json || return 1
	procd_open_instance
	procd_set_param command /usr/bin/xray run -c /var/etc/xc/config.json
	procd_set_param respawn 3600 5 5
	procd_set_param file /etc/config/xc
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}

service_triggers() {
	procd_add_reload_trigger xc network
}
```

The hotplug script only reloads `/etc/init.d/xc` when `ACTION` is `ifup`/`ifupdate`, `INTERFACE=lan`, and the plugin is enabled. The uci-default script locates the newest complete legacy backup, calls migration, validates/render-tests it, and only then disables `xc-xray`, enables `xc`, and starts the new service.

Add a `Package/luci-app-xc/preinst` block that creates `/etc/xc/legacy-backup-$(date +%s)`, copies only `/etc/xc/nodes.json`, `current`, `config.json`, `config.previous`, and `current.previous` plus `/usr/bin/xc` and `/etc/init.d/xc-xray` before unpack, writes a `complete` marker last, and exits without stopping the old service. Do not recursively copy `/etc/xc` into its own backup directory.

- [ ] **Step 4: Run tests and shell checks**

Run:

```sh
wsl sh -lc 'cd "/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）" && .tools/lua5.1 tests/run.lua && .tools/lua5.1 -e "assert(loadfile([[root/usr/bin/xc]]))" && for f in root/etc/init.d/xc root/etc/hotplug.d/iface/95-xc root/etc/uci-defaults/luci-xc; do sh -n "$f"; done'
```

Expected: all tests PASS and all scripts parse.

- [ ] **Step 5: Commit**

```sh
git add Makefile root tests/test_migration.lua
git commit -m "feat: integrate xc service and legacy migration"
```

### Task 7: Authenticated LuCI controller and action API

**Files:**
- Replace: `luasrc/controller/xc.lua`
- Create: `tests/test_controller_static.lua`

- [ ] **Step 1: Write static controller-contract tests**

Assert that the controller registers `admin/services/xc` plus settings, nodes, node editor, log, status, probe, switch, rollback, import-preview, import-commit, get-log, and clear-log routes. Mutation routes must be POST-only, inherit authenticated `admin` dispatch, validate section IDs with `schema.safe_section_id`, cap request bodies, and never concatenate `formvalue` into a shell command.

- [ ] **Step 2: Verify controller tests fail**

Run `.tools/lua5.1 tests/run.lua`.

Expected: FAIL because routes are absent.

- [ ] **Step 3: Implement stable JSON response shapes**

Use these response contracts:

```json
{"ok":true,"data":{}}
{"ok":false,"code":"validation_failed","message":"redacted user-facing text"}
```

Read node details by section ID from UCI inside the controller. Call Lua modules directly for import preview/commit and runtime actions. Write upload/paste content to a 0600 nixio temporary file only when needed and always remove it. Import commit stages all new sections on one UCI cursor, validates every staged node, commits once, and calls `revert("xc")` on any pre-commit failure; duplicate skips are reported but are not failures. Status responses may include service state, active section/name/protocol, resolved listen IP, ports, exit IP, lock state, and last error; they must omit credentials and raw outbound content.

- [ ] **Step 4: Run controller tests**

Run `.tools/lua5.1 tests/run.lua`.

Expected: controller static/security tests PASS.

- [ ] **Step 5: Commit**

```sh
git add luasrc/controller/xc.lua tests/test_controller_static.lua
git commit -m "feat: expose authenticated xc LuCI actions"
```

### Task 8: Settings and protocol-aware node editor

**Files:**
- Create: `luasrc/model/cbi/xc/settings.lua`
- Create: `luasrc/model/cbi/xc/nodes.lua`
- Create: `luasrc/model/cbi/xc/node.lua`
- Create: `luasrc/view/xc/status.htm`
- Create: `tests/test_cbi_static.lua`

- [ ] **Step 1: Write CBI contract tests**

Assert settings ranges/defaults exactly match the spec, only enabled node sections populate `active_node`, and node forms provide conditional fields for VLESS, VMess, Trojan, Shadowsocks, SOCKS, and raw outbound. Test that secrets use password inputs, list pages never render secret UCI keys, ports use `port` validation, concurrency uses `range(1,5)`, and raw JSON requires JSON-object validation.

- [ ] **Step 2: Verify tests fail**

Run `.tools/lua5.1 tests/run.lua`.

Expected: FAIL because CBI files are absent.

- [ ] **Step 3: Implement settings and editor forms**

Use `Map("xc")`, a named `global` section, and anonymous `node` typed sections with `extedit`. Add protocol-dependent options for identity, encryption/method, transport (`tcp`, `ws`, `grpc`), TLS, Reality, SNI, fingerprint, public key, short ID, WS host/path, and gRPC service name. Put uncommon Xray combinations behind `protocol=raw`; do not silently serialize unsupported structured combinations. Override node removal so the active node cannot be deleted while the plugin is enabled; require the user to switch first, and prevent removal of the sole enabled node unless the plugin is disabled.

The status template polls the status route every five seconds and renders stopped/running/error, active node, listener endpoints, and exit IP. It includes authenticated restart, current-node health test, and manual rollback buttons. It must stop polling when the page is hidden and resume when visible.

- [ ] **Step 4: Run CBI tests**

Run `.tools/lua5.1 tests/run.lua`.

Expected: all form/static tests PASS.

- [ ] **Step 5: Commit**

```sh
git add luasrc/model/cbi/xc luasrc/view/xc/status.htm tests/test_cbi_static.lua
git commit -m "feat: add xc settings and node editor"
```

### Task 9: SSR Plus-style quick probes, node table, and local import UI

**Files:**
- Create: `luasrc/view/xc/node_table.htm`
- Create: `luasrc/view/xc/ping.htm`
- Create: `luasrc/view/xc/import.htm`
- Modify: `luasrc/model/cbi/xc/nodes.lua`
- Modify: `luasrc/controller/xc.lua`
- Create: `tests/test_probe_static.lua`

- [ ] **Step 1: Write probe and UI contract tests**

Verify the controller probe reads target/transport/security from UCI, applies a 1–10 second bounded timeout, uses nixio TCP connect first, performs TLS/WS handshake when appropriate, and returns `{socket, ping, time}`. Verify the UI reads `probe_concurrency`, clamps it to `1–5`, uses a worker queue shared by single/all test, updates each row, and “停止测速” invalidates the run ID so no new work starts.

- [ ] **Step 2: Verify tests fail**

Run `.tools/lua5.1 tests/run.lua`.

Expected: FAIL because probe templates and endpoint behavior are absent.

- [ ] **Step 3: Adapt the SSR Plus pattern**

Port the queue/promise pattern from `fw876/helloworld` `server_list.htm`, replacing its fixed concurrency 10 with the validated UCI value. Port the controller’s safe socket/TLS/WS timing behavior without its SSR firewall/ipset mutations. Cache per-section results in `/tmp/xc-probe-cache.json` under a lock and display green `<100 ms`, amber `<200 ms`, orange `<300 ms`, red otherwise, plus explicit `ok/fail` socket status.

The import template uses browser `FileReader` for local files, a paste textarea, preview table, duplicate warnings, and a separate confirmed POST. It never uploads until the user presses preview, never stores subscription URLs, and clears the textarea after successful commit.

- [ ] **Step 4: Run probe/UI tests**

Run `.tools/lua5.1 tests/run.lua`.

Expected: all probe and static UI tests PASS.

- [ ] **Step 5: Commit**

```sh
git add luasrc tests/test_probe_static.lua
git commit -m "feat: add fast node probes and local imports"
```

### Task 10: Logs, translations, permissions, and polish

**Files:**
- Create: `luasrc/model/cbi/xc/log.lua`
- Create: `luasrc/view/xc/log.htm`
- Create: `po/templates/xc.pot`
- Create: `po/zh_Hans/xc.po`
- Create: `root/usr/share/rpcd/acl.d/luci-app-xc.json`
- Create: `root/usr/share/ucitrack/luci-app-xc.json`
- Create: `tests/test_secrets.lua`

- [ ] **Step 1: Write redaction and packaging tests**

Feed log/error helpers UUIDs, passwords, share links, and raw outbound JSON; assert none appear in output. Assert installed scripts have intended executable modes in the package tree, UCI ACL covers only `xc`, and translations include every visible menu/button/status string.

- [ ] **Step 2: Verify tests fail**

Run `.tools/lua5.1 tests/run.lua`.

Expected: missing log/translation/ACL failures.

- [ ] **Step 3: Implement log UI and translations**

The log endpoint reads at most the final 256 KiB, clear truncates only `/var/log/xc.log`, and both are authenticated. The page provides refresh and clear with confirmation. Generate the POT from Lua/templates where tooling permits, then add complete Simplified Chinese translations; English source strings remain meaningful fallbacks.

- [ ] **Step 4: Run full unit/static suite**

Run `.tools/lua5.1 tests/run.lua`, parse `root/usr/bin/xc` with `assert(loadfile(...))`, and run `sh -n` for the service, hotplug, and uci-default scripts.

Expected: zero failures.

- [ ] **Step 5: Commit**

```sh
git add luasrc po root/usr/share tests/test_secrets.lua
git commit -m "feat: finish xc logging and translations"
```

### Task 11: Documentation and reproducible package builds

**Files:**
- Create: `README.md`
- Create: `README_EN.md`
- Create: `LICENSE`
- Create: `.github/workflows/build.yml`
- Create: `scripts/check-package.sh`

- [ ] **Step 1: Write documentation/build acceptance checks**

`scripts/check-package.sh` must fail unless README documents feed/source installation, SDK build, migration backup location, SOCKS/HTTP defaults, CRUD/import/probe/switch/rollback behavior, supported versions, absence of transparent proxy/subscriptions/sing-box, and recovery commands. It must also verify workflow matrix entries for `21.02` and `24.10`.

- [ ] **Step 2: Confirm the check fails**

Run `wsl sh scripts/check-package.sh`.

Expected: missing documentation and workflow failures.

- [ ] **Step 3: Add docs, license, and CI**

Use GPL-3.0-only text. The workflow uses `actions/checkout@v4`, `actions/upload-artifact@v4`, and `openwrt/gh-action-sdk@797d0e3d0eb13b355c3447f60d0179d4b43089e2`. Its matrix `ARCH` values are `x86_64-openwrt-21.02` and `x86_64-24.10.8`, with `PACKAGES=luci-app-xc`, `BUILD_LOG=1`, and `V=s`. Run host tests before the SDK action and upload `.ipk` artifacts without embedding `/etc/config/xc` from any live device. Do not use a `latest` container tag.

- [ ] **Step 4: Run documentation and repository checks**

Run:

```sh
wsl sh -lc 'cd "/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）" && sh scripts/check-package.sh && .tools/lua5.1 tests/run.lua'
git diff --check
```

Expected: all checks PASS and no whitespace errors.

- [ ] **Step 5: Commit**

```sh
git add README.md README_EN.md LICENSE .github scripts/check-package.sh
git commit -m "docs: add build and installation guidance"
```

### Task 12: Device migration and end-to-end verification

**Files:**
- Modify only if defects are found in package sources/tests/docs.
- Produce: `bin/packages/*/luci/luci-app-xc_0.1.0-1_all.ipk`

- [ ] **Step 1: Build the package in a supported SDK**

Use the 24.10 SDK workflow/container locally or download the matching official SDK in WSL, add this repository as `package/luci-app-xc`, install feeds, and run:

```sh
make package/luci-app-xc/compile V=s
```

Expected: one `luci-app-xc_0.1.0-1_all.ipk` and no compile errors.

- [ ] **Step 2: Back up and inspect the target immediately before install**

Through the authorized router terminal, record checksums/permissions for `/usr/bin/xc`, `/etc/init.d/xc-xray`, and `/etc/xc`, plus current node/service/ports. Do not print node secrets. Confirm at action time before installing because package installation changes the live router.

- [ ] **Step 3: Install and verify migration without data loss**

Copy the IPK to `/tmp`, run `opkg install`, and verify: a complete legacy backup exists; 11 nodes migrated; current node maps correctly; old service is disabled only after new config validates; new `/etc/init.d/xc` is enabled/running; `/var/etc/xc/config.json` mode is 0600; ports 7890/10809 listen on LAN.

- [ ] **Step 4: Exercise acceptance scenarios**

From LuCI, verify add/edit/delete protection, old JSON import preview, duplicate skip, each supported share format, single probe, all probe at concurrency 1/3/5, stop queue, successful switch, forced health failure rollback, manual rollback, service reboot persistence, LAN hotplug reload, log redaction, and browser behavior under the installed Argon theme.

- [ ] **Step 5: Re-run regression checks and commit fixes**

Run host tests, shell checks, package build, and `git diff --check` again. If device verification required source changes, add a regression test first, fix, rebuild, retest, and commit with a focused `fix:` message. Expected: clean working tree and all checks PASS.

### Task 13: Publish repository and first release

**Files:**
- No source changes unless publication metadata exposes a defect.

- [ ] **Step 1: Verify publication state**

Run `git status --short --branch`, `git log --oneline --decorate -10`, the full test suite, and package build. Expected: clean tree, tests/build PASS, branch contains all implementation commits.

- [ ] **Step 2: Create the public GitHub repository**

Using the authenticated `deanzai` GitHub account, create public `deanzai/luci-app-xc` with no auto-generated README/license/gitignore because they already exist locally. This external action is authorized by the original request; if authentication is absent, pause for the user to sign in without requesting credentials.

- [ ] **Step 3: Push the default branch**

Add `https://github.com/deanzai/luci-app-xc.git` as `origin`, rename the local default branch to `main`, and push with upstream tracking. Expected: GitHub shows the same commit tip as local.

- [ ] **Step 4: Verify CI and create release**

Wait for both 21.02 and 24.10 workflow jobs. Only after both pass, tag `v0.1.0`, push the tag, create a release describing migration/limitations, and attach the verified `.ipk` artifacts. Do not publish any live router backup or node configuration.

- [ ] **Step 5: Final verification**

Verify repository visibility, README rendering, workflow status, release assets, tag/commit identity, and clone/install instructions from an unauthenticated view. Record the public URL and exact release asset names in the handoff.
