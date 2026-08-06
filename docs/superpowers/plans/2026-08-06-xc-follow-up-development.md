# XC 后续功能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `fast_select_api` 上完成核心上传体验、资源更新、访问控制和版本展示，并在设备上验证。

**Architecture:** 复用现有 LuCI controller、Lua 5.1 runtime、Xray generator 和事务回滚。上传 UI 只负责展示进度，后台继续自动计算核心哈希；访问控制把用户输入转换为独立候选配置，经 Xray `run -test` 通过后才进入现有运行时 A/B 回滚流程。

**Tech Stack:** OpenWrt LuCI CBI、Lua 5.1、Xray JSON、原生 JavaScript XMLHttpRequest、现有 testlib/Node DOM 测试。

---

### Task 1: 核心页与版本显示

**Files:**
- Modify: `luasrc/view/xc/core.htm`
- Modify: `tests/test_core_ui.js`
- Modify: `luasrc/view/xc/status.htm`
- Modify: `tests/test_status.js`
- Create: `root/usr/lib/lua/xc/version.lua`
- Modify: `Makefile`
- Modify: `po/templates/xc.pot`, `po/zh_Hans/xc.po`

- [ ] 写测试：核心上传 UI 必须有 progress 元素、使用 `xhr.upload.onprogress`，不再提交 SHA-256/备注；状态页必须有插件版本和不换行运行状态类。
- [ ] 运行 `node tests/test_core_ui.js` 与 `node tests/test_status.js`，确认新增断言失败。
- [ ] 删除核心页 SHA-256/备注输入与展示，增加进度显示，保留后台自动哈希；状态模板增加版本行和 `white-space: nowrap`。
- [ ] 把显示版本设为 `0.1.0-r20`，运行 UI 测试及 `sh scripts/check-package.sh`。

### Task 2: Geo/Xray 资源更新契约

**Files:**
- Modify: `root/usr/lib/lua/xc/routing.lua`
- Modify: `root/usr/lib/lua/xc/coremanager.lua`
- Modify: `luasrc/controller/xc.lua`
- Modify: `luasrc/view/xc/core.htm`
- Modify: `tests/test_generator.lua`, `tests/test_core.lua`, `tests/test_controller_core.lua`, `tests/test_core_ui.js`
- Modify: `README.md`, `README_EN.md`

- [ ] 写测试：版本上限为 `26.6.27`，高版本返回稳定提示且不替换当前核心/资源；缺资源时仍返回已有 `routing_assets_missing`。
- [ ] 运行对应 Lua/Node 测试确认失败。
- [ ] 增加统一版本门槛、手动替换提示和资源/核心更新状态；校验失败在激活前终止。
- [ ] 运行完整 Lua 测试、核心 UI 测试和包检查。

### Task 3: 访问控制与 A/B 候选配置

**Files:**
- Create: `root/usr/lib/lua/xc/access.lua`
- Create: `luasrc/model/cbi/xc/access.lua`
- Create: `luasrc/view/xc/access.htm`
- Modify: `root/usr/lib/lua/xc/generator.lua`, `root/etc/config/xc`
- Modify: `luasrc/controller/xc.lua`, `root/usr/share/rpcd/acl.d/luci-app-xc.json`
- Create: `tests/test_access.lua`, `tests/test_access_ui.js`, `tests/test_controller_access.lua`
- Modify: `po/templates/xc.pot`, `po/zh_Hans/xc.po`, `README.md`, `README_EN.md`

- [ ] 写失败测试：合法 DNS/direct/proxy 规则进入候选配置；空值、非法地址、越界长度被拒绝；拒绝时不调用 Xray、不替换当前配置。
- [ ] 运行新测试确认失败原因是接口/模块尚未实现。
- [ ] 实现 `xc.access` 纯 Lua 解析与白名单校验，生成独立候选配置数据；保留当前生效配置和回滚槽位，不覆盖原始基线。
- [ ] 新增访问控制页签和 POST 校验接口；校验失败只返回提示，成功后调用现有 runtime switch/apply 事务。
- [ ] 运行 Lua、Node、ACL、翻译和包检查。

### Task 4: 主机、设备和交付

**Files:**
- Modify only files identified by failed verification.

- [ ] 运行 `sh tests/run-host.sh`。
- [ ] 构建 `r20` 主包和中文包，不把 IPK 纳入 Git。
- [ ] 备份 `192.168.6.1` 的 `/etc/config/xc`、运行配置和核心指针。
- [ ] 安装测试包，确认服务、7890/10809、规则、版本显示和配置校验失败保护。
- [ ] 检查 diff，提交 `fast_select_api` 并推送远程。
