# XC 预设分流与 Geo 资源 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将旧 XC 预设分流接入当前 Xray 配置生成流程，并在 Geo 资源缺失时安全阻止启动。

**Architecture:** `xc.routing` 保存无状态的预设规则；`xc.generator` 组合规则和当前选中出站；`xc.runtime` 在渲染/切换前通过平台 FS 适配器检查固定 Geo 文件。Shell 入口和 procd 服务统一导出 Xray 资源目录。

**Tech Stack:** Lua 5.1、LuCI JSONC、OpenWrt procd、现有 Lua testlib。

---

### Task 1: 预设规则模块与生成器接入

**Files:**
- Create: `root/usr/lib/lua/xc/routing.lua`
- Modify: `root/usr/lib/lua/xc/generator.lua:1-35,472-477`
- Test: `tests/test_generator.lua`

- [x] **Step 1: Write the failing tests**

Add tests that assert the generated table contains the ad-block, private, custom direct, selected-service, non-CN and CN rules, that `reality-uk` never appears as a tag, and that `routing_enabled="0"` returns only the private CIDR rule.

- [x] **Step 2: Run the focused generator test and verify RED**

Run `./.tools/lua5.1 tests/run.lua` and confirm the new routing assertions fail because the generator currently returns one private-CIDR rule.

- [x] **Step 3: Implement the smallest routing module**

Expose `M.private_cidrs`, `M.required_assets`, `M.preset_rules`, and `M.build(global)`; deep-copy every array/table and map all legacy `reality-uk` uses to `proxy-selected`. Make `generator.build()` append these rules while preserving the existing direct/private behavior.

- [x] **Step 4: Run the focused generator tests and verify GREEN**

Run `./.tools/lua5.1 tests/run.lua`; all generator assertions must pass and no existing outbound tests may regress.

- [x] **Step 5: Commit the isolated routing change**

```sh
git add root/usr/lib/lua/xc/routing.lua root/usr/lib/lua/xc/generator.lua tests/test_generator.lua
git commit -m "feat: apply preset geo routing rules"
```

### Task 2: Runtime Geo resource guard

**Files:**
- Modify: `root/usr/lib/lua/xc/runtime.lua:1-125,316-323`
- Test: `tests/test_runtime.lua`

- [x] **Step 1: Write the failing runtime tests**

Add one test with both `/usr/share/xray/geosite.dat` and `/usr/share/xray/geoip.dat` present and one test with each file missing. Assert the missing case returns `{ ok=false, code="routing_assets_missing" }` before `exec.run` is called.

- [x] **Step 2: Run the focused runtime test and verify RED**

Run `./.tools/lua5.1 tests/test_runtime.lua`; the missing-resource case must currently proceed to the mocked Xray path or return the wrong code.

- [x] **Step 3: Implement the guard and stable message**

Require `xc.routing`, check `routing.required_assets(global)` through `self.fs.exists()` at the start of `_encode()`, and return `result(false, "routing_assets_missing")` when enabled resources are absent. Add the code to the existing message map without logging file contents.

- [x] **Step 4: Run focused runtime tests and verify GREEN**

Run `./.tools/lua5.1 tests/test_runtime.lua` and confirm both missing-file cases short-circuit before Xray validation.

- [x] **Step 5: Commit the runtime guard**

```sh
git add root/usr/lib/lua/xc/runtime.lua tests/test_runtime.lua
git commit -m "feat: guard geo routing resources"
```

### Task 3: Export the Xray asset directory

**Files:**
- Modify: `root/usr/bin/xc`
- Modify: `root/etc/init.d/xc`
- Test: `tests/test_migration.lua` or a new static assertion in `tests/test_controller_static.lua`

- [x] **Step 1: Add a failing static assertion**

Assert both shell entry points contain `XRAY_LOCATION_ASSET=/usr/share/xray` and export it before invoking Xray or Lua runtime operations.

- [x] **Step 2: Run the static test and verify RED**

Run the relevant test file and confirm the assertion fails on the current scripts.

- [x] **Step 3: Add the export without changing service ordering**

Set and export the variable at the top of `root/usr/bin/xc`; set it before `procd_open_instance` in `root/etc/init.d/xc` so both `run -test` and the long-running process inherit the same path.

- [x] **Step 4: Run static and package checks**

Run `./.tools/lua5.1 tests/run.lua` and `sh scripts/check-package.sh`.

- [x] **Step 5: Commit the environment change**

```sh
git add root/usr/bin/xc root/etc/init.d/xc tests
git commit -m "fix: set Xray asset directory for geo rules"
```

### Task 4: Integration verification and device rollout

**Files:**
- No source changes unless a verification failure identifies a root cause.

- [x] **Step 1: Run the complete host suite**

Run `sh tests/run-host.sh`; require exit code 0 and no translation/package failures.

- [x] **Step 2: Build the package**

Use the existing OpenWrt SDK workflow to build the package and Chinese translation package for the target platform; do not commit IPKs.

- [x] **Step 3: Back up device configuration**

On `192.168.13.1`, create a timestamped copy of `/etc/config/xc` before installation and copy `geoip.dat` from the verified old device to `/usr/share/xray/geoip.dat` with mode 0644.

- [x] **Step 4: Install and verify generated routing**

Install the new IPK over SSH, restart XC, then assert both assets exist, `XRAY_LOCATION_ASSET` is present in the service environment, `/var/etc/xc/config.json` contains all preset route families, and `xray run -test -c /var/etc/xc/config.json` exits 0.

- [x] **Step 5: Commit only after evidence**

Run `git status`, inspect the final diff, then push the implementation branch to `origin/main` only after all host and device checks pass.
