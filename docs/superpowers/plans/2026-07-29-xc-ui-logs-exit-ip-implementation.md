# XC UI, Logging, and Exit IP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a fully translated XC interface, accurately named latency tests, a safe unified XC/Xray runtime log viewer, and a reliable cached proxy exit IP.

**Architecture:** Keep XC operational JSON in its existing private bounded file and obtain Xray runtime-only messages from the bounded OpenWrt `logd` ring through fixed argv. Normalize both sources in a focused pure Lua module, return structured entries to an ES5 DOM renderer, and leave Xray access logging disabled. Give exit-IP observation its own five-second deadline and a node-keyed 60-second private cache so five-second LuCI status polling does not repeatedly call the public health URL.

**Tech Stack:** Lua 5.1, LuCI legacy CBI templates, OpenWrt procd/logd/UCI, Xray JSON configuration, ES5 browser JavaScript, Node DOM/XHR tests, WSL host tests.

---

## File responsibility map

- `root/usr/lib/lua/xc/logview.lua`: pure parsing, redaction, normalization, sorting, and level filtering for XC and Xray runtime records.
- `root/usr/lib/lua/xc/platform.lua`: fixed-argv bounded `logread` capture and wall-clock adapter.
- `root/usr/lib/lua/xc/runtime.lua`: XC operational event writer and node-keyed exit-IP cache.
- `root/usr/lib/lua/xc/generator.lua`: explicit Xray runtime log level with access logging disabled.
- `root/usr/bin/xc` and `root/etc/init.d/xc`: fixed allowlisted service lifecycle log events.
- `luasrc/controller/xc.lua`: authenticated structured log endpoint and probe/import event logging.
- `luasrc/model/cbi/xc/log.lua`: permission-independent `SimpleForm` that attaches the log template.
- `luasrc/model/cbi/xc/settings.lua`: Xray runtime log-level selector.
- `luasrc/view/xc/log.htm`: safe unified log DOM renderer and level selector.
- `luasrc/view/xc/node_table.htm`: approved Chinese latency-test terminology source.
- `po/templates/xc.pot` and `po/zh_Hans/xc.po`: unique complete translation catalogs.
- `tests/test_logview.lua`, `tests/test_log_ui.js`, and existing Lua/Node suites: behavioral regression coverage.

### Task 1: Restore the log page shell and latency-test terminology

**Files:**
- Modify: `luasrc/model/cbi/xc/log.lua`
- Modify: `luasrc/view/xc/node_table.htm`
- Modify: `tests/test_cbi_static.lua`
- Modify: `tests/test_task9_ui.js`

- [ ] **Step 1: Write failing CBI and terminology tests**

Require the log model to contain `SimpleForm`, create one `SimpleSection`, attach `xc/log`, and contain no `Map("xc")`. Change the Node fixture expectations so the single button receives the translated source string `Test`, the batch source is `Test all`, and the stop source is `Stop testing`.

```lua
local model = read_file("luasrc/model/cbi/xc/log.lua")
t.contains(model, 'SimpleForm("xc_log"')
t.contains(model, "m:section(SimpleSection)")
t.contains(model, 'section.template = "xc/log"')
t.eq(model:find('Map("xc")', 1, true), nil)
```

```js
assert.strictEqual(row.button.value, "Test");
assert.strictEqual(h.controls["xc-probe-all"].value, "Test all");
assert.strictEqual(h.controls["xc-probe-stop"].value, "Stop testing");
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```powershell
node tests/test_task9_ui.js
wsl --cd '/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）/.worktrees/implement-luci-app-xc' ./.tools/lua5.1 -e 'package.path="tests/?.lua;root/usr/lib/lua/?.lua;root/usr/lib/lua/?/init.lua;"..package.path;require"test_cbi_static";os.exit(require("testlib").finish() and 0 or 1)'
```

Expected: terminology assertions fail and the log model lacks an attached `SimpleSection`.

- [ ] **Step 3: Implement the minimal CBI shell and source labels**

Use the existing uncommitted `SimpleForm` conversion as input, but finish it explicitly:

```lua
local m = SimpleForm("xc_log", translate("Log"),
  translate("XC runtime and Xray core logs are shown here. Sensitive values are redacted."))
m.submit, m.reset, m.cancel = false, false, false

local section = m:section(SimpleSection)
section.template = "xc/log"

return m
```

In `node_table.htm`, use `translate("Test")`, `<%:Test all%>`, and `<%:Stop testing%>` without altering the queue behavior.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the commands from Step 2. Expected: the Node test and all `test_cbi_static` assertions pass.

- [ ] **Step 5: Commit Task 1**

```powershell
git add luasrc/model/cbi/xc/log.lua luasrc/view/xc/node_table.htm tests/test_cbi_static.lua tests/test_task9_ui.js
git commit -m "fix: restore XC log page shell"
```

### Task 2: Add the configurable Xray runtime log level

**Files:**
- Modify: `root/etc/config/xc`
- Modify: `luasrc/model/cbi/xc/settings.lua`
- Modify: `root/usr/lib/lua/xc/generator.lua`
- Modify: `tests/test_cbi_static.lua`
- Modify: `tests/test_generator.lua`

- [ ] **Step 1: Write failing settings and generator tests**

Add cases that require the UCI default `xray_log_level=warning`, a LuCI `ListValue` with exactly error/warning/info/debug, and generated Xray configuration like:

```lua
t.eq(config.log.access, "none")
t.eq(config.log.loglevel, "warning")
t.eq(config.log.dnsLog, false)
```

For each accepted configured level, assert exact preservation. Assert an unknown value fails generation instead of entering Xray JSON.

- [ ] **Step 2: Run the focused suites and verify RED**

Run:

```powershell
wsl --cd '/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）/.worktrees/implement-luci-app-xc' ./.tools/lua5.1 -e 'package.path="tests/?.lua;root/usr/lib/lua/?.lua;root/usr/lib/lua/?/init.lua;"..package.path;require"test_generator";require"test_cbi_static";os.exit(require("testlib").finish() and 0 or 1)'
```

Expected: missing global option and missing `config.log` assertions fail.

- [ ] **Step 3: Implement the allowlisted setting and Xray log block**

Add this CBI option and matching UCI default:

```lua
local xray_log_level = global:option(ListValue, "xray_log_level", translate("Xray log level"))
for _, level in ipairs({ "error", "warning", "info", "debug" }) do
  xray_log_level:value(level, translate(level == "error" and "Error" or level == "warning" and "Warning" or level == "info" and "Info" or "Debug"))
end
xray_log_level.default = "warning"
xray_log_level.rmempty = false
```

In `generator.build`, validate with a fixed table and emit:

```lua
log = { access = "none", loglevel = level, dnsLog = false }
```

- [ ] **Step 4: Run focused tests and representative Xray validation**

Run the Step 2 suites and the existing representative Xray config test. Expected: all focused tests pass and the bundled Xray accepts the generated log block.

- [ ] **Step 5: Commit Task 2**

```powershell
git add root/etc/config/xc luasrc/model/cbi/xc/settings.lua root/usr/lib/lua/xc/generator.lua tests/test_cbi_static.lua tests/test_generator.lua
git commit -m "feat: configure Xray runtime logging"
```

### Task 3: Normalize and filter XC plus Xray runtime logs

**Files:**
- Create: `root/usr/lib/lua/xc/logview.lua`
- Create: `tests/test_logview.lua`
- Modify: `root/usr/lib/lua/xc/platform.lua`
- Modify: `luasrc/controller/xc.lua`
- Modify: `tests/test_platform_static.lua`
- Modify: `tests/test_controller_actions.lua`

- [ ] **Step 1: Write failing pure normalization tests**

Define the wished-for interface:

```lua
local entries, err = logview.collect({
  xc = xc_json_lines,
  xray = logread_lines,
  level = "warning",
  json = json_adapter,
  wall_time = 1785326400,
  uptime = 7200
})
```

Test all/error/warning/info/debug filtering; XC epoch and legacy uptime conversion; Xray lines tagged `xray[PID]`; chronological merge; malformed-line isolation; maximum input/entry/message counts; and representative UUID, password, URI, raw JSON, and token redaction. Reject invalid levels with `nil, "invalid_level"`.

- [ ] **Step 2: Run `test_logview.lua` and verify RED**

```powershell
wsl --cd '/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）/.worktrees/implement-luci-app-xc' ./.tools/lua5.1 -e 'package.path="tests/?.lua;root/usr/lib/lua/?.lua;root/usr/lib/lua/?/init.lua;"..package.path;require"test_logview";os.exit(require("testlib").finish() and 0 or 1)'
```

Expected: module `xc.logview` is absent.

- [ ] **Step 3: Implement `logview.collect` as a pure bounded module**

Return entries shaped exactly as:

```lua
{ time = 1785326395, display_time = "2026-07-29 20:26:35", level = "warning", source = "xray", message = "..." }
```

Use fixed allowlists, no shell calls, a maximum of 512 normalized entries, and a 1024-byte sanitized message. Preserve safe malformed Xray text as `warning` only when it matches the exact `xray[PID]:` process tag.

- [ ] **Step 4: Add fixed-argv `logread` capture and wall clock**

Expose from the platform adapter:

```lua
wall_time = function() return os.time() end
exec.xray_logs = function(deadline)
  return capture_process({ "/sbin/logread", "-e", "xray[" }, deadline, 262144)
end
```

Tests must assert exact argv, finite deadline, bounded output, and no shell interpolation.

- [ ] **Step 5: Change `action_get_log` to a structured authenticated endpoint**

Read the bounded XC tail and bounded Xray capture, validate `http.formvalue("level")`, call `logview.collect`, and return:

```lua
success({ entries = entries, clear_scope = "xc" })
```

Invalid levels return the stable `invalid_request` envelope. Capture failure returns XC entries rather than failing the whole page; XC read faults still fail closed.

- [ ] **Step 6: Run normalization, controller, and platform tests**

Run `test_logview`, `test_controller_actions`, and `test_platform_static` with Lua 5.1. Expected: all new backend tests pass and `test_logview` confirms no representative secret appears in normalized output.

- [ ] **Step 7: Commit Task 3**

```powershell
git add root/usr/lib/lua/xc/logview.lua root/usr/lib/lua/xc/platform.lua luasrc/controller/xc.lua tests/test_logview.lua tests/test_platform_static.lua tests/test_controller_actions.lua
git commit -m "feat: merge XC and Xray runtime logs"
```

### Task 4: Render the unified log safely in LuCI

**Files:**
- Modify: `luasrc/view/xc/log.htm`
- Create: `tests/test_log_ui.js`

- [ ] **Step 1: Write a failing DOM/XHR test**

Build a small DOM harness with the level selector, refresh, clear, notice, state, and entry container. Feed mixed structured entries and assert:

```js
assert.deepStrictEqual(renderedLevels, ["error", "warning", "info", "debug"]);
assert.deepStrictEqual(renderedSources, ["XC", "Xray", "XC", "Xray"]);
assert.strictEqual(container.querySelectorAll("script").length, 0);
```

Verify level changes request only the allowlisted query; malformed responses show the translated failure; empty output uses an injected translated string; clear empties only the displayed XC content and renders the translated shared-system-log notice.

- [ ] **Step 2: Run the Node test and verify RED**

```powershell
node tests/test_log_ui.js
```

Expected: the current raw-string/`innerHTML` renderer does not satisfy structured DOM assertions.

- [ ] **Step 3: Implement an ES5 text-only renderer**

Replace log-derived `innerHTML` with `document.createElement`, `createTextNode`, and `textContent`. Render source, level, display time, and message as separate spans. Use CSS classes `xc-log-error`, `xc-log-warning`, `xc-log-info`, and `xc-log-debug`. Inject all stable visible strings through server-side `translate()` serialization; never call an undefined browser `translate()` function.

- [ ] **Step 4: Run the Node security and behavior test**

Run `node tests/test_log_ui.js`. Expected: all assertions pass, including literal `<script>` and credential-shaped messages rendered only as text.

- [ ] **Step 5: Commit Task 4**

```powershell
git add luasrc/view/xc/log.htm tests/test_log_ui.js
git commit -m "fix: render unified logs safely"
```

### Task 5: Expand sanitized XC operational event coverage

**Files:**
- Modify: `root/usr/lib/lua/xc/runtime.lua`
- Modify: `root/usr/lib/lua/xc/platform.lua`
- Modify: `root/usr/bin/xc`
- Modify: `root/etc/init.d/xc`
- Modify: `luasrc/controller/xc.lua`
- Modify: `tests/test_runtime.lua`
- Modify: `tests/test_controller_actions.lua`
- Modify: `tests/test_layout.lua`

- [ ] **Step 1: Write failing wall-clock and event tests**

Inject `wall_time=function() return 1785326400 end` and require new XC records to use that epoch rather than monotonic deadline time. Assert info events for service start/stop, switch, successful import, and rollback; debug events for render and successful probes; error events for failed probes/imports/switches/rollbacks. Assert every event passes only section IDs, outcome codes, counts, and other fixed safe fields. Make the runtime fixture record lock identity as `fs:unlock:<path>` so the existing migration-exclusive test distinguishes the nested XC log lock from the main runtime lock and proves the main lock remains held through the marker write.

- [ ] **Step 2: Run focused tests and verify RED**

Run `test_runtime`, `test_controller_actions`, and `test_layout`. Expected: wall-clock and missing event assertions fail; the strengthened migration lock assertion initially fails until fixture and event ordering are corrected.

- [ ] **Step 3: Use the wall clock in `Runtime:log`**

Store `self.wall_time = adapters.wall_time or adapters.now` in `M.new` and create records with:

```lua
local entry = { time = self.wall_time(), level = level, message = sanitize_text(message, 512), fields = safe_fields }
```

- [ ] **Step 4: Add fixed lifecycle and controller events**

Add an allowlisted CLI command `log-event service_started|service_stopped`; the init script invokes only those constants. Probe and import controllers call `Runtime:log` with fixed messages and safe outcome/count fields. Runtime switch and rollback paths emit success or fixed error-code events. Logging failures never replace the primary action result.

- [ ] **Step 5: Run focused event and secret tests**

Expected: all focused suites pass, their representative-secret assertions remain green, the migration main-lock ordering is explicit, and logging adapter faults do not break switch/probe/import/rollback behavior.

- [ ] **Step 6: Commit Task 5**

```powershell
git add root/usr/lib/lua/xc/runtime.lua root/usr/lib/lua/xc/platform.lua root/usr/bin/xc root/etc/init.d/xc luasrc/controller/xc.lua tests/test_runtime.lua tests/test_controller_actions.lua tests/test_layout.lua
git commit -m "feat: record XC operational events"
```

### Task 6: Give Exit IP a separate deadline and node-keyed cache

**Files:**
- Modify: `root/usr/lib/lua/xc/runtime.lua`
- Modify: `tests/test_runtime.lua`
- Modify: `tests/test_status.js`

- [ ] **Step 1: Write failing deadline and cache tests**

Cover:

- two listener checks use the existing listener deadline;
- exit observation receives a newly computed deadline no more than five seconds ahead;
- a valid same-node cache younger than 60 seconds skips observation;
- a cache for another node, an age of 60 seconds or more, malformed time, invalid IP, or unsafe section is ignored;
- a successful observation writes a private atomic cache containing only node, epoch, and IP;
- failure with no fresh cache returns no `exit_ip` and exposes no curl body.

- [ ] **Step 2: Run focused runtime/status tests and verify RED**

Run focused `test_runtime.lua` plus `node tests/test_status.js`. Expected: the observer still receives the consumed two-second listener deadline and no cache exists.

- [ ] **Step 3: Implement the strict cache**

Add `/tmp/xc-exit-ip` to `runtime.paths`. Store a line format with strict parsing:

```text
node=node_safe_id
observed_at=1785326400
ip=203.0.113.10
```

Read only a bounded 512 bytes, require the active node to match, require `0 <= wall_now-observed_at < 60`, validate IPv4/IPv6 with the existing strict validator, and atomically write mode `0600` after a successful observation. Compute the observation deadline as `self.now() + 5` after listener checks finish.

- [ ] **Step 4: Run focused runtime/status tests and verify GREEN**

Expected: cache and deadline cases pass; status still omits observation unless service and SOCKS listener are healthy.

- [ ] **Step 5: Commit Task 6**

```powershell
git add root/usr/lib/lua/xc/runtime.lua tests/test_runtime.lua tests/test_status.js
git commit -m "fix: cache XC exit IP observations"
```

### Task 7: Rebuild complete unique translations and verify the package

**Files:**
- Modify: `po/templates/xc.pot`
- Modify: `po/zh_Hans/xc.po`
- Modify: `tests/test_secrets.lua`
- Modify: `scripts/check-package.sh`

- [ ] **Step 1: Strengthen translation tests before editing catalogs**

Parse catalogs and fail on duplicate non-header `msgid`, missing visible strings, empty Chinese `msgstr`, and unapproved terminology. Require translations for `Test`, `Test all`, `Stop testing`, all log levels/notices, `Xray log level`, `XC`, `Xray`, and exit-IP states.

- [ ] **Step 2: Run translation tests and verify RED**

Expected: current duplicate PO entries and missing POT additions fail.

- [ ] **Step 3: Regenerate canonical catalogs**

Create one POT entry per visible message and one non-empty Simplified Chinese translation. Use `测试` only for generic health actions and `测速` for node latency actions. Preserve technical protocol names and translate all settings/status/log descriptions.

- [ ] **Step 4: Run the complete host verification**

Run:

```powershell
node tests/test_task9_ui.js
node tests/test_log_ui.js
node tests/test_status.js
wsl --cd '/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）/.worktrees/implement-luci-app-xc' ./.tools/lua5.1 tests/run.lua
wsl --cd '/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）/.worktrees/implement-luci-app-xc' sh scripts/check-package.sh
git diff --check
```

Also parse `root/usr/bin/xc` with Lua 5.1 and run `sh -n` on the init, hotplug, and uci-default scripts. Expected: zero failures.

- [ ] **Step 5: Commit Task 7 locally without pushing**

```powershell
git add po/templates/xc.pot po/zh_Hans/xc.po tests/test_secrets.lua scripts/check-package.sh
git commit -m "i18n: complete XC interface translations"
```

### Task 8: Deploy first, perform device acceptance, then push

**Files:**
- No source edits unless device verification exposes a defect; any defect follows a new RED/GREEN cycle and focused local commit.

- [ ] **Step 1: Build the installable package and translation artifact**

Build `luci-app-xc` for the device-compatible 24.10 target so `xc.zh-cn.lmo` is generated by the LuCI build tooling. Verify the IPK contains the expected Lua, templates, runtime modules, init/config files, ACL, and translation artifact, and contains no live `/etc/config/xc` data.

- [ ] **Step 2: Back up exact live targets**

Create a timestamped `/tmp/xc-ui-logs-backup-*` directory on `192.168.6.1` and copy only files that will be replaced. Record checksums and modes without printing UCI nodes, runtime configuration, or credentials.

- [ ] **Step 3: Install/deploy and refresh LuCI**

Deploy the verified package or exact built files, preserve the live `/etc/config/xc`, add the new `xray_log_level=warning` only when absent, clear `/tmp/luci-indexcache`, restart rpcd/uhttpd as required, and restart XC so Xray receives the runtime-log configuration.

- [ ] **Step 4: Perform browser and router acceptance before any push**

Verify on the installed Argon theme:

- Settings, Nodes, Runtime Status, and Log are fully Simplified Chinese;
- node controls read `测速`, `全部测速`, and `停止测速` and still update the correct 11 rows;
- the unified log page shows `[XC]` and `[Xray]`, readable times, safe text, and all five filters;
- service lifecycle, render, switch, probe, import, rollback, and fixed failures produce the expected XC levels;
- Xray access logging remains disabled and its selected runtime level is honored;
- Clear removes XC entries and leaves the shared system/Xray history with an accurate notice;
- Exit IP shows the actual proxy egress IP, cache suppresses repeated curl calls for 60 seconds, and changing nodes cannot show the previous node's cached IP;
- browser console, LuCI dispatcher, service, and runtime logs contain no new errors or secrets.

- [ ] **Step 5: Run post-device regression and inspect the complete diff**

Repeat all Task 7 commands. Compare local HEAD, device checksums, and intended source list. Expected: zero failures, no unrelated dirty file, and no credential-bearing remote URL.

- [ ] **Step 6: Push only after acceptance is green**

```powershell
$env:HTTPS_PROXY='socks5://192.168.6.1:7890'
$env:HTTP_PROXY='socks5://192.168.6.1:7890'
git push origin main
Remove-Item Env:HTTPS_PROXY
Remove-Item Env:HTTP_PROXY
```

Verify `git rev-parse HEAD` equals `git rev-parse origin/main`. Do not tag or publish a new release unless separately requested.
