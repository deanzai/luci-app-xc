# XC 快速切换 API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不重启 Xray 的情况下，通过仅绑定 loopback 的 Routing API 快速切换 balancer 节点，同时保留现有安全切换、真实连接检查和回滚能力。

**Architecture:** 生成器新增动态配置渲染入口，生成所有启用节点、`xc-balancer` 和 `127.0.0.1:10085` API 入站；平台层以固定 argv 封装 `xray api bo/bi`；runtime 在锁内执行 `bo → bi → UCI commit`，启动后恢复持久化选择。现有 `switch` 继续负责重启、监听和真实连接检查，快速切换使用独立 CLI/controller/UI 入口。

**Tech Stack:** Lua 5.1、LuCI controller/CBI、Xray RoutingService、OpenWrt procd、现有 Lua/Node 宿主测试。

---

## 文件与边界

- Modify `root/usr/lib/lua/xc/routing.lua`: 让代理目标可以安全地表达为 `outboundTag` 或 `balancerTag`。
- Modify `root/usr/lib/lua/xc/generator.lua`: 保留单节点 `build()`，新增 `build_dynamic(global, nodes)` 和稳定节点 tag/API 配置。
- Modify `root/usr/lib/lua/xc/platform.lua`: 增加固定 loopback API 调用和受限 `bi` 输出解析。
- Modify `root/usr/lib/lua/xc/runtime.lua`: 增加动态渲染、快速切换、启动恢复和状态字段；把新操作纳入锁、日志和 adapter 校验。
- Modify `root/usr/lib/lua/xc/cli.lua`: 增加 `render-dynamic`、`fast-switch`、`restore-selection`，并白名单转发结果字段。
- Modify `root/etc/init.d/xc`: 启动时渲染动态配置并在 Xray 进程启动后恢复 balancer 选择。
- Modify `luasrc/controller/xc.lua`: 注册 POST `/fast-switch`，映射稳定错误码和成功 envelope。
- Modify `luasrc/view/xc/node_table.htm`: 保留安全“切换”，增加独立“快速切换”按钮和短状态流程。
- Modify `tests/test_generator.lua`, `tests/test_platform_process.lua`, `tests/test_runtime.lua`: 覆盖动态配置、固定 argv 和快速事务的 RED/GREEN 行为。
- Modify `tests/test_controller_static.lua`, `tests/test_controller_actions.lua`, `tests/test_task9_ui.js`: 覆盖路由、响应、按钮状态和重复点击。
- Modify `tests/test_platform_static.lua`: 覆盖 init 脚本的动态渲染、loopback API 和启动恢复命令。
- Modify `po/templates/xc.pot`, `po/zh_Hans/xc.po`: 同步新增 UI 文案。
- Modify `Makefile`: 完成验证后将 `PKG_RELEASE` 从 18 升到 19。
- Create `docs/2026-08-05-r19-fast-select-verification.md`: 记录宿主测试、IPK 校验和 `192.168.6.1` 设备验收，不记录凭据、UUID 或 raw outbound。

### 约定的内部接口

~~~lua
-- routing.lua
routing.build(global, { outboundTag = "proxy-selected" })
routing.build(global, { balancerTag = "xc-balancer" })

-- generator.lua
generator.node_tag("node_1")       -- "xc-node-node_1"
generator.build_dynamic(global, nodes)

-- platform.lua exec adapter
exec.xray_api_override(xray_path, "xc-balancer", "xc-node-node_1")
exec.xray_api_balancer(xray_path, "xc-balancer") -- returns "xc-node-node_1" or nil

-- runtime.lua
runtime:render_dynamic("/var/etc/xc/config.json")
runtime:fast_switch("node_1")
runtime:restore_selection()
~~~

所有 section ID、节点 tag、balancer tag 都经过已有 schema/固定前缀校验；不接受 shell 字符串、任意可执行路径或原始 API JSON。

### Task 1: 先为 routing 和 dynamic generator 写失败测试

**Files:**
- Test: `tests/test_generator.lua`
- Modify later: `root/usr/lib/lua/xc/routing.lua`, `root/usr/lib/lua/xc/generator.lua`

- [ ] **Step 1: 添加 routing 目标抽象的失败测试**

在现有 routing/generator 测试附近加入以下行为断言：默认调用仍输出 `outboundTag = "proxy-selected"`；传入 `{ balancerTag = "xc-balancer" }` 后 DNS 规则和所有代理预设规则改为 `balancerTag`，私网、CN、广告、direct 和 block 规则保持原字段。

~~~lua
t.test("routes proxy traffic through an explicit balancer target", function()
  local function dynamic_node(id)
    return { id = id, enabled = true, protocol = "vless", server = id .. ".invalid", port = 443,
      uuid = "11111111-1111-1111-1111-111111111111", encryption = "none", transport = "tcp", security = "none" }
  end
  local cfg = assert(generator.build_dynamic(global(), { dynamic_node("old"), dynamic_node("new") }))
  local proxy_rules = 0
  for _, rule in ipairs(cfg.routing.rules) do
    if rule.balancerTag == "xc-balancer" then proxy_rules = proxy_rules + 1 end
    t.eq(rule.outboundTag == "proxy-selected", false, "dynamic routing must not retain the legacy proxy tag")
  end
  t.truthy(proxy_rules >= 3)
end)
~~~

- [ ] **Step 2: 添加动态配置结构的失败测试**

断言 `build_dynamic()` 生成两个稳定节点 outbound、`xc-balancer` selector、API service 只含 `RoutingService`、API inbound 监听 `127.0.0.1:10085`、API 出站不进入 balancer；断言节点密码和 UUID 只存在于 outbound 内部结构，不进入 tag、路由或 API 地址。

~~~lua
t.test("builds a loopback Xray API and all enabled node outbounds", function()
  local function dynamic_node(id)
    return { id = id, enabled = true, protocol = "vless", server = id .. ".invalid", port = 443,
      uuid = "11111111-1111-1111-1111-111111111111", encryption = "none", transport = "tcp", security = "none" }
  end
  local cfg = assert(generator.build_dynamic(global(), { dynamic_node("old"), dynamic_node("new") }))
  t.eq(cfg.api.tag, "xc-api")
  t.eq(cfg.api.services[1], "RoutingService")
  t.eq(#cfg.api.services, 1)
  t.eq(cfg.balancers[1].tag, "xc-balancer")
  t.eq(cfg.balancers[1].selector[1], "xc-node-")
  t.eq(cfg.inbounds[3].listen, "127.0.0.1")
  t.eq(cfg.inbounds[3].port, 10085)
  t.eq(cfg.inbounds[3].tag, "xc-api")
  t.eq(cfg.outbounds[1].tag, "xc-node-old")
  t.eq(cfg.outbounds[2].tag, "xc-node-new")
end)
~~~

- [ ] **Step 3: 运行 RED 测试并确认失败原因**

Run: `./.tools/lua5.1 tests/test_generator.lua`  
Expected: FAIL because `build_dynamic`/balancer target support does not exist; no production file is changed before this failure is observed.

- [ ] **Step 4: 实现最小 routing/generator 代码**

`routing.build(global, target)` 默认使用 `{ outboundTag = "proxy-selected" }`，只在 target 明确含有 `balancerTag` 时写 `balancerTag`。 `generator.build_dynamic()` 复用 `build_outbound(node, "xc-node-" .. id)`，追加 direct、block、API freedom outbound，构造 API inbound/routing rule，并拒绝空节点列表、无效 section ID、禁用节点和重复 tag。

- [ ] **Step 5: 运行 GREEN 测试并检查旧结构**

Run: `./.tools/lua5.1 tests/test_generator.lua`  
Expected: 动态断言和原有单节点断言全部 PASS；`build(global,node)` 仍使用 `proxy-selected`。

- [ ] **Step 6: 提交独立 generator 变更**

~~~sh
git add root/usr/lib/lua/xc/routing.lua root/usr/lib/lua/xc/generator.lua tests/test_generator.lua
git commit -m "feat: render Xray dynamic balancer configuration"
~~~

### Task 2: 为 Xray API platform adapter 写失败测试并实现

**Files:**
- Test: `tests/test_platform_process.lua`
- Modify: `root/usr/lib/lua/xc/platform.lua`

- [ ] **Step 1: 添加固定 argv 的失败测试**

用现有 `capture`/`spawn` 注入 adapter，传入一个已校验的 Xray 路径，断言 override 只调用：

~~~text
<selected-xray> api bo --server=127.0.0.1:10085 -b xc-balancer xc-node-new
~~~

并断言 balancer 查询只调用：

~~~text
<selected-xray> api bi --server=127.0.0.1:10085 xc-balancer
~~~

测试非法 tag、分号、空白、超长值时不调用进程；测试 `bi` 的正常、失败、超长和畸形输出均 fail closed。

- [ ] **Step 2: 运行 RED**

Run: `./.tools/lua5.1 tests/test_platform_process.lua`  
Expected: FAIL with missing `xray_api_override`/`xray_api_balancer` behavior, not with a test harness error.

- [ ] **Step 3: 实现最小 adapter**

让 runtime 传入其已有 `selected_xray(self)` 结果；platform 只接受通过 `valid_xray_path()` 校验的路径。新增内部 `valid_api_tag()`，只允许 `xc-balancer` 或 `xc-node-` 加安全 section ID。override 用 `spawn_process` 且 deadline 上限 10 秒；查询用 `capture_process`，最大输出 4096 bytes。解析器先识别 Xray CLI 的 balancer current 字段，再识别结构化 JSON 中与指定 balancer 对应的 current/selected 字段，最终只返回符合 `^xc%-node%-[0-9A-Za-z_-]+$` 的 tag。

- [ ] **Step 4: 运行 GREEN 和全平台相关测试**

Run: `./.tools/lua5.1 tests/test_platform_process.lua`  
Expected: 新增 API 断言与全部既有进程、curl、退出 IP 断言 PASS。

- [ ] **Step 5: 提交 platform 变更**

~~~sh
git add root/usr/lib/lua/xc/platform.lua tests/test_platform_process.lua
git commit -m "feat: add safe Xray routing API adapter"
~~~

### Task 3: 为 runtime 动态渲染、快速事务和恢复写失败测试

**Files:**
- Test: `tests/test_runtime.lua`
- Modify later: `root/usr/lib/lua/xc/runtime.lua`

- [ ] **Step 1: 扩展 runtime fixture 的 exec 记录**

在 fixture 中加入带 xray path 参数的 `xray_api_override`、`xray_api_balancer` 注入点和 `dynamic_config` 文件内容，不改变现有 restart/health fixture。事件使用 `exec:api_override:<tag>`、`exec:api_balancer:<tag>`，不记录凭据。

- [ ] **Step 2: 添加快速切换成功的失败测试**

断言 `runtime:fast_switch("new")` 的事件顺序为 lock、读取状态、API override、API readback、UCI set/commit；返回 `{ ok=true, code="fast_switched", node="new" }`；`exec.restart`、`listener_ready`、`real_connection_check` 均未调用，且 `active_node` 已持久化。

~~~lua
t.test("fast switch changes the live balancer without restarting or probing", function()
  local state = fixture({ dynamic_config = true, api_current = "xc-node-old" })
  local value = state.runtime:fast_switch("new")
  t.eq(value.ok, true)
  t.eq(value.code, "fast_switched")
  t.eq(value.node, "new")
  t.eq(state.global.active_node, "new")
  t.eq(event_index(state.events, "exec:restart"), nil)
  t.eq(event_index(state.events, "exec:real_connection_check"), nil)
  t.truthy(event_index(state.events, "exec:api_override:xc-node-new"))
end)
~~~

- [ ] **Step 3: 添加失败回滚和恢复测试**

分别覆盖 API unavailable、`bi` 返回旧值、UCI pre-commit failure、UCI commit unknown、恢复旧 tag 失败；断言每个场景不报告 `fast_switched`，提交失败会调用旧 tag override，恢复失败返回 `fast_switch_recovery_required`。添加 `restore_selection()` 测试：读取 UCI active node，调用目标 tag override，再通过 `bi` 确认；无 active node、服务停止和非动态配置返回稳定错误。

- [ ] **Step 4: 运行 RED**

Run: `./.tools/lua5.1 tests/test_runtime.lua`  
Expected: 新增测试因 runtime 尚无方法/adapter 能力而失败；既有切换测试仍可执行，便于区分新增失败和回归。

- [ ] **Step 5: 实现最小 runtime 代码**

新增动态节点归一化和 `_encode_dynamic()`，`render_dynamic()` 写入候选路径；新增 `_dynamic_runtime()` 检查当前配置的 API/balancer 结构。 `fast_switch()` 在已有 `_with_lock()` 内严格执行：校验目标 → 获取 `selected_xray(self)` → 检查 service/dynamic config → `xray_api_override(xray_path, ...)` → `xray_api_balancer(xray_path, ...)` → `_apply_active`；`_apply_active` 失败时重新 override 旧 tag。新增 `restore_selection()` 使用相同校验但不修改 UCI。把新操作加入 `_record_completion()`、adapter 必需函数和 status 的 `selection_mode`, `runtime_active_node`, `selection_state` 字段。

- [ ] **Step 6: 运行 GREEN 和完整 runtime 测试**

Run: `./.tools/lua5.1 tests/test_runtime.lua`  
Expected: 全部 runtime 测试 PASS；安全 `switch()` 的重启/真实连接行为和旧事务恢复断言保持 PASS。

- [ ] **Step 7: 提交 runtime 变更**

~~~sh
git add root/usr/lib/lua/xc/runtime.lua tests/test_runtime.lua
git commit -m "feat: add transactional fast node selection"
~~~

### Task 4: 接通 CLI 与 procd 启动恢复

**Files:**
- Test: `tests/test_platform_static.lua`
- Modify: `root/usr/lib/lua/xc/cli.lua`, `root/etc/init.d/xc`

- [ ] **Step 1: 添加 CLI/init 静态失败断言**

断言 CLI 接受且只接受 `render-dynamic --output <safe path>`、`fast-switch <safe section>`、`restore-selection`；`safe_result()` 转发 `selection_mode`, `runtime_active_node`, `selection_state`，不转发任意 API 输出。断言 init 使用 `render-dynamic`，Xray 启动后调用 `restore-selection`，API 端口和命令参数只在已有固定字符串中出现。

- [ ] **Step 2: 运行 RED**

Run: `./.tools/lua5.1 tests/test_platform_static.lua`  
Expected: 新增 CLI/init 静态断言 FAIL，现有 core path 断言 PASS。

- [ ] **Step 3: 实现 CLI 命令与启动恢复**

在 `cli.lua` 增加：

~~~lua
if command == "fast-switch" and #argv == 2 and schema.safe_section_id(argv[2]) then
  return finish(deps, deps.runtime:fast_switch(argv[2]))
end
if command == "restore-selection" and #argv == 1 then
  return finish(deps, deps.runtime:restore_selection())
end
if command == "render-dynamic" and #argv == 3 and argv[2] == "--output" and safe_path(argv[3]) then
  return finish(deps, deps.runtime:render_dynamic(argv[3]))
end
~~~

在 init 中把正常启动渲染改成 `xc render-dynamic --output /var/etc/xc/config.json`；`procd_close_instance` 后启动一次受限 `xc restore-selection`，恢复命令自身轮询 API 可用状态并返回稳定结果，恢复失败只记录事件，不触发 Xray 重启循环。 `restart_prepared` 不重复渲染候选配置，但仍执行恢复。

- [ ] **Step 4: 运行 GREEN**

Run: `./.tools/lua5.1 tests/test_platform_static.lua`  
Expected: 新增静态断言 PASS，脚本没有 CRLF 或未固定命令。

- [ ] **Step 5: 提交 CLI/init 变更**

~~~sh
git add root/usr/lib/lua/xc/cli.lua root/etc/init.d/xc tests/test_platform_static.lua
git commit -m "feat: restore fast selection after Xray startup"
~~~

### Task 5: 接通 LuCI controller 与节点页快速按钮

**Files:**
- Test: `tests/test_controller_static.lua`, `tests/test_controller_actions.lua`, `tests/test_task9_ui.js`
- Modify: `luasrc/controller/xc.lua`, `luasrc/view/xc/node_table.htm`

- [ ] **Step 1: 添加 controller 和 UI RED 测试**

静态测试要求 controller 注册 POST `/fast-switch`；action 测试要求 GET 返回 405、非法/缺失节点返回 400/404、runtime `busy` 返回 409、API unavailable 返回 503、成功返回 `{ok=true,data={code="fast_switched",node=...}}`，并验证异常/日志不泄露 secret。UI 测试要求每行恰有一个 `.xc-fast-switch-one`，点击 POST `/xc/fast-switch`，按钮先显示“快速切换中”，收到 `fast_switched` 后刷新 `/status`，成功/失败都恢复可点击且不会启动安全切换轮询。

- [ ] **Step 2: 运行 RED**

Run: `./.tools/lua5.1 tests/test_controller_static.lua && ./.tools/lua5.1 tests/test_controller_actions.lua && node tests/test_task9_ui.js`  
Expected: 新增 route/action/button 断言 FAIL，当前安全切换测试 PASS。

- [ ] **Step 3: 实现 controller action**

增加消息和状态映射：`fast_switch_unavailable=503`、`fast_switch_api_failed=502`、`fast_switch_not_applied=502`、`fast_switch_commit_failed=500`、`fast_switch_recovery_required=503`，目标校验沿用 400/404/409。 `action_fast_switch()` 使用现有 body/request 校验，调用 `runtime_instance:fast_switch(section_id)`，只返回 `code/node` 白名单字段并记录安全事件。

- [ ] **Step 4: 实现 UI 快速路径**

保留 `.xc-switch-one` 的安全切换代码；新增 `fastSwitchEndpoint`、`.xc-fast-switch-one`、独立 `fastSwitching` 状态和成功/失败文案。初始化时去重、插入按钮、当前节点禁用；快速请求成功只调用 `refreshActive()`，不会调用 `scheduleSwitchPoll()`，网络错误和 API 错误都执行同一个 finish 分支。

- [ ] **Step 5: 运行 GREEN**

Run: `./.tools/lua5.1 tests/test_controller_static.lua && ./.tools/lua5.1 tests/test_controller_actions.lua && node tests/test_task9_ui.js`  
Expected: controller/UI 新增和既有断言全部 PASS，UI 不使用 `location.reload`。

- [ ] **Step 6: 提交 controller/UI 变更**

~~~sh
git add luasrc/controller/xc.lua luasrc/view/xc/node_table.htm tests/test_controller_static.lua tests/test_controller_actions.lua tests/test_task9_ui.js
git commit -m "feat: expose fast node switch in LuCI"
~~~

### Task 6: 同步翻译、包版本和回归保护

**Files:**
- Modify: `po/templates/xc.pot`, `po/zh_Hans/xc.po`, `Makefile`
- Test: `tests/test_check_package.sh`, `tests/run-host.sh`

- [ ] **Step 1: 添加新增文案并更新静态测试**

同步以下 msgid：`Fast switch`、`Fast switching…`、`Fast switched`、`Fast switch failed`；中文分别为“快速切换”“快速切换中…”“已快速切换”“快速切换失败”。保持 POT/PO 条目唯一、非空、编码为 UTF-8。

- [ ] **Step 2: 升级包 release**

将 `Makefile` 的 `PKG_RELEASE:=18` 改为 `PKG_RELEASE:=19`，不修改 `PKG_VERSION`。

- [ ] **Step 3: 运行包和翻译 RED/GREEN 检查**

Run: `sh tests/test_check_package.sh`  
Expected: 翻译同步、版本规范、CRLF、脚本和包结构检查 PASS；若先于文案修改运行，应能明确报告缺少新增 msgid。

- [ ] **Step 4: 运行完整宿主测试**

Run: `sh tests/run-host.sh`  
Expected: Lua、全部 Node UI、包检查和 po2lmo 检查均以退出码 0 完成，报告 0 failures。

- [ ] **Step 5: 提交版本/翻译变更**

~~~sh
git add Makefile po/templates/xc.pot po/zh_Hans/xc.po
git commit -m "chore: release fast selection as r19"
~~~

### Task 7: 构建 IPK 并在 192.168.6.1 做设备验证

**Files:**
- Create: `docs/2026-08-05-r19-fast-select-verification.md`
- Build artifact: `luci-app-xc_0.1.0-r19_all.ipk`（不提交到 git）

- [ ] **Step 1: 确认工作树和提交范围**

Run: `git status --short --branch && git diff --check && git log --oneline -8`  
Expected: 只有 `.artifacts/`、`.xray-26.6.27-test/` 这两个已存在未跟踪目录可保留；源码改动均已提交，未出现凭据、UUID、raw outbound 或 IPK 被 git 跟踪。

- [ ] **Step 2: 在 OpenWrt Buildroot/SDK 构建 r19 包**

Run in the configured OpenWrt build directory: `make package/luci-app-xc/compile V=s`  
Expected: 生成 `luci-app-xc_0.1.0-r19_all.ipk`；使用 `scripts/check-package.sh` 和 `scripts/prepare-release-assets.sh` 校验包版本与架构命名。

- [ ] **Step 3: 备份设备非敏感运行状态**

通过现有 SSH 通道在 `192.168.6.1` 记录 `/etc/config/xc`、`/var/etc/xc/config.json`、服务状态、监听端口、Xray PID 和 active section 的权限/摘要；备份文件放设备 `/tmp`，不要把密码、UUID、raw outbound 或完整配置输出到日志。

- [ ] **Step 4: 安装并验证动态配置/API**

把 r19 IPK 复制到设备 `/tmp` 后执行 `opkg install /tmp/luci-app-xc_0.1.0-r19_all.ipk`，重启 `xc`，验证：

~~~sh
/usr/bin/xray run -test -format json -c /var/etc/xc/config.json
uci -q get xc.global.active_node
/etc/init.d/xc running
ss -lnpt | grep -E '127\\.0\\.0\\.1:10085|:7890|:10809'
~~~

另以 loopback API 验证 `xray api bi --server=127.0.0.1:10085 xc-balancer`，并确认从 LAN 地址无法访问 10085。

- [ ] **Step 5: 验证快速切换的核心验收条件**

在两个已启用节点间连续切换，记录切换前后 Xray PID、SOCKS/HTTP 监听、`bo`/`bi` 返回、UCI active node 和 status API；确认 PID/监听不变、状态刷新、快速路径不触发健康检查阻塞。用现有代理出口 IP 状态接口单独观察出口，不把出口 IP 与节点 server IP 强行相等。

- [ ] **Step 6: 验证重启恢复与失败路径**

重启 `xc` 和设备后确认 active node 与 `bi` 选择一致；临时停止/阻断 API 后确认快速切换返回稳定失败且旧选择不变；执行一次原“切换”安全路径确认重启、监听等待、真实连接测试和回滚仍可用。完成后恢复设备配置到测试前的用户选择。

- [ ] **Step 7: 写入设备验证记录并提交**

文档只记录时间、版本、命令退出码、耗时、PID 是否变化、API 是否 loopback、测试节点内部 ID 和错误码；不记录敏感字段。运行 `git diff --check` 后提交：

~~~sh
git add docs/2026-08-05-r19-fast-select-verification.md
git commit -m "docs: record r19 fast selection verification"
~~~

### Task 8: 完成前验证、提交和推送

- [ ] **Step 1: 重新运行完整宿主验证**

Run: `sh tests/run-host.sh`  
Expected: 退出码 0、所有测试 PASS、无包检查/翻译/CRLF 错误。

- [ ] **Step 2: 检查差异和敏感信息**

Run: `git diff origin/main...HEAD --check; rg -n -i "password|passwd|uuid|private_key|raw_outbound|vless://|vmess://|trojan://" docs/2026-08-05-r19-fast-select-verification.md`  
Expected: diff check 通过；验证文档不含敏感内容。对源码中的 schema 字段和既有测试命中逐一确认，不把测试 fixture 凭据复制到文档。

- [ ] **Step 3: 确认设备 smoke test 证据**

重新读取设备验证文档和当前设备 status，逐项确认动态配置、loopback API、PID 不变、`bi` readback、重启恢复、失败回滚和安全切换均有实际命令输出。

- [ ] **Step 4: 推送分支**

~~~sh
git status --short --branch
git push -u origin fast_select_api
~~~

Expected: push 成功，远端分支为 `fast_select_api`；若设备验证任一项失败，不执行此步骤，先修复并重新验证。
