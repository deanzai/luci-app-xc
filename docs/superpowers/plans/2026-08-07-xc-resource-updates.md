# XC 内核资源更新 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Xray core 页签提供 Xray、GeoIP、GeoSite 的内置多源下载、直接替换和默认快照回滚入口。

**Architecture:** `xc.assetmanager` 维护固定资源源、受管路径、默认快照和更新/回滚状态；`xc.routing` 优先使用插件受管 Geo 目录，再回退系统资源目录；`xc.platform` 提供固定参数的下载、Xray 压缩包提取和原子文件操作。控制器只接受资源类型与固定源 ID，页面只渲染后端返回的源选项。

**Tech Stack:** Lua 5.1、LuCI、OpenWrt `curl`/BusyBox、现有 Xray core manager、Node 静态 UI 测试、`testlib`。

---

### Task 1: Add managed asset paths and source selections

**Files:**
- Modify: `root/usr/lib/lua/xc/routing.lua`
- Modify: `root/usr/lib/lua/xc/platform.lua`
- Modify: `root/etc/init.d/xc`
- Modify: `root/etc/config/xc`
- Test: `tests/test_routing.lua`
- Test: `tests/test_platform_static.lua`

- [ ] **Step 1: Write the failing tests**

Add routing assertions for `M.MANAGED_ASSET_DIR == "/etc/xc/xray/assets"`, `asset_dir(fs)` preferring the managed directory when both files exist, and falling back to `/usr/share/xray` then `/usr/share/v2ray`. Add static assertions that `ensure_layout` creates `/etc/xc/xray/assets` and `/etc/xc/xray/assets/default`, and that init exports a managed asset directory before starting Xray.

```lua
t.test("managed assets take precedence over package assets", function()
  local fs = { exists = function(path)
    return path == "/etc/xc/xray/assets/geosite.dat"
      or path == "/etc/xc/xray/assets/geoip.dat"
      or path == "/usr/share/xray/geosite.dat"
      or path == "/usr/share/xray/geoip.dat"
  end }
  t.eq(routing.asset_dir(fs), "/etc/xc/xray/assets")
end)
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run `./.tools/lua5.1 tests/test_routing.lua` and the relevant static test command. They must fail because the managed path and layout do not exist yet.

- [ ] **Step 3: Implement the path precedence and layout**

Add managed path constants and include them first in `routing.asset_dir`, `asset_status`, and `required_assets`. Extend the platform asset-directory whitelist and `ensure_layout` directory list. Update init `resolve_asset_dir` to select `/etc/xc/xray/assets` when it contains both files, without deleting or overwriting package directories. Add empty UCI source options with `official` defaults.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run `./.tools/lua5.1 tests/test_routing.lua`, `./.tools/lua5.1 tests/test_platform_static.lua`, and `bash.exe scripts/check-package.sh`; all path and layout assertions must pass.

### Task 2: Implement the fixed source and update manager

**Files:**
- Create: `root/usr/lib/lua/xc/assetmanager.lua`
- Test: `tests/test_assetmanager.lua`

- [ ] **Step 1: Write failing manager tests**

Cover: only `xray`, `geoip`, and `geosite` are accepted; only built-in source IDs are accepted; an invalid source falls back to `official`; an update downloads to a temporary path and atomically replaces the managed resource; the first update copies the current package resource into `default`; later updates do not overwrite that snapshot; rollback restores the snapshot; missing snapshot returns `asset_no_default` without deleting the active file.

```lua
t.test("asset update keeps one immutable default snapshot", function()
  local manager, state = fixture({
    files = {
      ["/usr/share/xray/geoip.dat"] = "package-old",
      ["/etc/xc/xray/assets/geoip.dat"] = nil
    }, downloaded = "downloaded-new"
  })
  t.truthy(manager:update("geoip", "official").ok)
  t.eq(state.files["/etc/xc/xray/assets/default/geoip.dat"], "package-old")
  state.downloaded = "downloaded-later"
  t.truthy(manager:update("geoip", "mirror").ok)
  t.eq(state.files["/etc/xc/xray/assets/default/geoip.dat"], "package-old")
  t.truthy(manager:rollback("geoip").ok)
  t.eq(state.files["/etc/xc/xray/assets/geoip.dat"], "package-old")
end)
```

- [ ] **Step 2: Run `./.tools/lua5.1 tests/test_assetmanager.lua` and verify RED**

The test must fail because `xc.assetmanager` is not present.

- [ ] **Step 3: Implement the manager**

Define fixed source records with display name, source ID, URL template, and resource format. Resolve only whitelisted resource/source pairs, derive architecture from the injected adapter for Xray, and never accept a URL parameter. Use injected `download`, `extract_xray`, `copy_file`, `rename`, `remove`, `exists`, `mkdir`, `stat`, and `write_file` functions. Do not inspect downloaded bytes. For Xray, use the fixed release format to extract the `xray` member, derive the manifest metadata required by the existing core manager, and install it as an inactive version; do not activate it. For Geo files, copy the first existing package asset to the immutable default directory, then atomically replace the managed active file. Return bounded stable codes such as `asset_invalid`, `asset_download_failed`, `asset_install_failed`, `asset_no_default`, and `asset_updated`.

- [ ] **Step 4: Run the manager tests and verify GREEN**

Run `./.tools/lua5.1 tests/test_assetmanager.lua` and the full Lua suite `./.tools/lua5.1 tests/run.lua`.

### Task 3: Add bounded platform download and extraction adapters

**Files:**
- Modify: `root/usr/lib/lua/xc/platform.lua`
- Test: `tests/test_platform_static.lua`
- Test: `tests/test_platform_process.lua`

- [ ] **Step 1: Add failing adapter assertions**

Assert the platform exposes `exec.download` and `exec.extract_xray`, uses a fixed `curl` argument shape, writes only to a protected temporary path, and invokes `unzip`/BusyBox with the fixed member name `xray`. Assert unsafe paths and non-fixed source URLs are rejected before spawning.

- [ ] **Step 2: Run the focused tests and verify RED**

Run `./.tools/lua5.1 tests/test_platform_process.lua` and `./.tools/lua5.1 tests/test_platform_static.lua`; the new adapter assertions must fail.

- [ ] **Step 3: Implement the adapters**

Add a bounded download helper using fixed `curl` flags (`--fail`, `--location`, bounded connect/overall timeout, `--output` to a reserved temp file) and a fixed extractor that captures the `xray` member into a reserved temp file. Keep source URL expansion inside `xc.assetmanager`; platform only accepts URLs matching the manager’s fixed source records. Reuse existing `spawn_process`/`capture_process` and no shell interpolation.

- [ ] **Step 4: Run adapter and regression tests**

Run both focused platform tests plus `./.tools/lua5.1 tests/run.lua`; no process-safety or existing UCI tests may regress.

### Task 4: Add controller endpoints and UCI source persistence

**Files:**
- Modify: `luasrc/controller/xc.lua`
- Modify: `root/usr/lib/lua/xc/platform.lua`
- Modify: `root/usr/lib/lua/xc/assetmanager.lua`
- Test: `tests/test_controller_core.lua`
- Test: `tests/test_controller_asset.lua`

- [ ] **Step 1: Write failing controller tests**

Assert the controller registers POST-only `core-resource-update` and `core-resource-rollback`, accepts only `kind` and `source`, never reads a URL field, returns fixed source options in `core-status`, persists only valid source IDs, and emits secret-safe error envelopes.

```lua
t.test("resource update is POST-only and URL-free", function()
  local source = read_file("luasrc/controller/xc.lua")
  t.contains(source, 'post_entry({ "admin", "services", "xc", "core-resource-update" }, "action_core_resource_update")')
  t.contains(source, 'post_entry({ "admin", "services", "xc", "core-resource-rollback" }, "action_core_resource_rollback")')
  t.contains(source, "assetmanager_module")
  t.eq(source:find('formvalue("url")', 1, true), nil)
end)
```

- [ ] **Step 2: Run the focused controller tests and verify RED**

Run `./.tools/lua5.1 tests/run.lua` and confirm the new route and handler assertions fail while the existing controller assertions continue to run.

- [ ] **Step 3: Implement the routes and handlers**

Extend `new_backend()` with the asset manager. Add stable messages/status mappings, include `resources.sources` and default-snapshot state in `action_core_status`, and implement POST handlers that call `update(kind, source)` or `rollback(kind)`, stage/commit only the source ID, and return the manager’s bounded public result. Keep the existing core upload and activation paths unchanged.

- [ ] **Step 4: Run controller and full Lua tests**

Run `./.tools/lua5.1 tests/run.lua` and confirm all controller, manager, runtime, and secret-redaction tests pass.

### Task 5: Add independent core-page update controls

**Files:**
- Modify: `luasrc/view/xc/core.htm`
- Modify: `tests/test_core_ui.js`
- Modify: `tests/test_controller_core.lua`
- Modify: `po/templates/xc.pot`
- Modify: `po/zh_Hans/xc.po`

- [ ] **Step 1: Add failing UI tests**

Assert the view contains three resource rows, a source `<select>` for each, independent update and rollback controls, the two new endpoint attributes, and no URL input. Extend the DOM harness with source data and assert clicking one update disables only its row and calls the fixed endpoint.

- [ ] **Step 2: Run `node tests/test_core_ui.js` and verify RED**

The new resource control assertions must fail against the current core page.

- [ ] **Step 3: Implement the UI**

Render the resource section below current core information. Use text nodes for labels/status, populate only validated source records from `core-status`, submit `kind` and `source` as form data, and expose separate update/rollback buttons. Lock only the active row, display the result message, then call `loadStatus()`.

- [ ] **Step 4: Synchronize translations and run UI tests**

Add every new visible string to both catalogs with Chinese translations, run `node tests/test_core_ui.js`, `node tests/test_access_ui.js`, and `bash.exe scripts/check-package.sh`.

### Task 6: Update documentation and release checks

**Files:**
- Modify: `README.md`
- Modify: `README_EN.md`
- Modify: `tests/test_layout.lua`
- Modify: `scripts/check-package.sh`

- [ ] **Step 1: Add documentation assertions**

Extend layout/package tests to require the managed asset directory, fixed-source behavior, and the Xray core page instructions; assert the docs do not describe user-editable update URLs. Add `root/usr/lib/lua/xc/assetmanager.lua` to the package file manifest and LF/translation checks where the existing script enumerates Lua production files.

- [ ] **Step 2: Update docs and checks**

Document the three independent buttons, built-in source selection, direct-download semantics, immutable default snapshot rollback, and the need to manually activate/restart as applicable. Keep the existing warning that downloaded content is not semantically validated.

- [ ] **Step 3: Run package and documentation checks**

Run `bash.exe scripts/check-package.sh` and `git diff --check`.

### Task 7: Full verification and delivery

**Files:**
- No source changes unless a verification failure identifies a concrete defect.

- [ ] **Step 1: Run the complete host suite**

Run `bash.exe tests/run-host.sh`; require all Lua tests, all Node UI tests, gettext, package, workflow, and build-matrix checks to pass.

- [ ] **Step 2: Inspect the final diff and sensitive data**

Run `git status --short --branch`, `git diff --check`, `git diff --stat`, and scan staged/source files for hard-coded credentials or user-supplied URLs. Keep `.artifacts/` and `.xray-26.6.27-test/` untracked.

- [ ] **Step 3: Commit and push**

```sh
git add root/etc/config/xc root/etc/init.d/xc root/usr/lib/lua/xc/assetmanager.lua root/usr/lib/lua/xc/platform.lua root/usr/lib/lua/xc/routing.lua luasrc/controller/xc.lua luasrc/view/xc/core.htm tests po README.md README_EN.md scripts/check-package.sh
git commit -m "feat: add built-in core resource updates"
git push -u origin fast_select_api
```
