# XC Xray-core 手动替换功能实施计划

> 状态：已完成（21.02/24.10 设备验收、错误注入和主机/构建验证均已完成）
>
> 目标版本：在不覆盖 OpenWrt/ImmortalWrt `xray-core` 软件包文件的前提下，支持通过 LuCI 上传自建或官方编译的 Xray-core、校验兼容性、切换运行版本、失败自动恢复和手动回滚。

## 1. 背景与边界

当前插件依赖目标系统提供的 `/usr/bin/xray`，节点切换、配置测试和 procd 服务启动都使用固定路径。这样可以保持 21.02 和 24.10 的基础兼容性，但无法让用户在设备上安全替换核心。

本功能的核心原则：

1. **不覆盖 `/usr/bin/xray`**。该文件由 `xray-core`/`opkg` 管理，直接覆盖会造成包校验、升级和卸载异常。
2. **上传文件先暂存、后校验、再激活**。上传成功不等于已经切换运行核心。
3. **核心切换与节点切换共用互斥事务锁**。同一时间只能执行一次会重启 Xray 的操作。
4. **候选核心必须通过设备架构检查、版本检查和当前配置检查**，并在切换后通过服务、监听器和健康检查。
5. **任何失败都保留可用回退路径**：优先恢复上一个手动核心，必要时恢复系统包核心；恢复失败时停止服务并明确提示人工处理。
6. **使用 Lua 5.1、LuCI legacy CBI/ucode bridge、OpenWrt 21.02 可用的固定参数调用**，不依赖 sing-box、Go 工具链或远程订阅。

明确不包含：自动从 GitHub 下载核心、在线自动升级、签名密钥基础设施、透明代理、订阅管理、多核心并发运行和按流量分流。

## 2. 目标用户流程

### 2.1 上传并校验

1. 打开 `服务 → Xray node switching → Xray core`。
2. 页面显示当前运行核心、来源（系统包/手动版本）、架构、版本、文件大小和 SHA-256。
3. 选择一个本地 Xray 可执行文件，填写可选的期望 SHA-256 和备注。
4. 上传以流式写入受保护的临时文件，不把整个二进制读入 LuCI 内存。
5. 插件计算实际 SHA-256，并依次检查：文件大小、ELF 格式、CPU 架构、可执行权限、`xray version` 输出和当前配置的 `run -test`。
6. 校验通过后保存为“已安装但未激活”版本；校验失败则删除候选文件，页面只显示安全的失败原因。

### 2.2 激活

1. 用户点击已校验版本的“激活”。
2. 页面显示版本、SHA-256 和将要执行的切换动作，要求一次明确确认。
3. 插件记录当前核心和运行状态，原子更新核心选择标记，使用候选核心启动 XC。
4. 依次验证 Xray 服务、SOCKS/HTTP 监听、当前节点健康检查和出口 IP（出口 IP 失败不应误判为核心启动失败，按现有健康检查策略处理）。
5. 全部成功后写入“当前核心”元数据；失败则自动恢复旧核心并重启，返回明确的失败或已恢复状态。

### 2.3 回滚与删除

- “回滚”恢复最近一次激活前的核心；若没有手动版本，则恢复系统包核心。
- 回滚也必须经过服务、监听和健康检查，不能只切换文件指针。
- 只能删除未激活且未被回滚槽位引用的版本；当前版本和最近回滚版本不能直接删除。
- 删除前显示版本、SHA-256 和占用空间；删除使用明确的单个版本目录，不使用未展开的通配符。

## 3. 存储与路径设计

核心文件和元数据放在持久化的受保护目录中，不放在 `/tmp` 或 `/var/etc/xc` 运行目录：

```text
/etc/xc/xray/
├── current                         # 当前核心选择标记：system 或安全版本 ID
├── previous                        # 最近一次激活前的核心选择标记
├── transaction                     # 未完成核心事务，用于启动恢复
└── versions/                       # 0700
    └── <version-id>/               # 0700，ID 只允许安全字符
        ├── xray                    # 0700，可执行二进制
        └── manifest.json            # 0600，每个手动核心的元数据
```

实现使用 `current`/`previous` marker 加每个版本目录内的 `manifest.json` 保存状态，不额外生成全局 `current.json` 或 `previous.json`；这样切换指针和版本元数据仍可分别原子校验。

`system` 不复制系统包文件，只代表 `/usr/bin/xray`。手动核心目录由插件管理；软件包升级不会覆盖手动版本，也不会修改 `/usr/bin/xray`。

版本 ID 不直接使用用户提供的文件名，建议由规范化版本、架构和 SHA-256 前 16 位组成，例如：

```text
v26_6_27-aarch64-51c3e26e4ba03f3a
```

manifest 至少包含：`id`、`version`、`arch`、`size`、`sha256`、`uploaded_at`、`validation` 和可选的用户备注。禁止写入节点 URI、UUID、密码、Token 或上传请求中的原始敏感字段。

所有目录使用 `0700`，元数据使用 `0600`，核心文件使用 `0700`。写入采用“随机临时文件 → fsync → rename → fsync 目录”；路径只由内部生成的安全 ID 组成，并拒绝符号链接和 `..`。

## 4. 校验规则

### 4.1 文件和空间

- 上传大小设置硬上限，初始建议 `64 MiB`；实际限制同时受设备可用空间约束。
- 流式上传使用硬上限；上传完成后、复制到版本目录前检查目标文件系统可用空间，至少预留版本副本、事务临时文件和 1 MiB 安全余量。
- 临时文件必须使用独占创建，权限从创建时即为 `0600`；请求中断、超限或校验失败时只清理本次明确生成的临时文件。
- 不接受 tar、zip、ipk 或包含多个文件的归档；本功能只接受单个 Xray ELF 可执行文件。

### 4.2 ELF 和设备架构

解析 ELF magic、class、endianness 和 `e_machine`，与设备 `uname -m` 对照。至少覆盖项目构建和验收需要的 `aarch64`；对 `arm`, `x86_64`, `i386`, `mips`, `mipsel` 等架构建立明确映射，未知映射直接拒绝。

架构检查必须在执行候选文件前完成。不能仅根据用户填写的文件名或浏览器 MIME 类型判断架构。

### 4.3 SHA-256 与版本

- 插件始终计算并展示本地实际 SHA-256。
- 用户填写期望 SHA-256 时，必须是 64 位小写或大写十六进制字符串，并与实际值完全匹配；不匹配不得进入已安装列表。
- `xray version` 使用固定 argv、有限超时和有限输出读取，输出必须能解析出 Xray 版本；不得把完整输出写入日志。
- 版本字段只允许安全的版本字符，不能用于组成任意路径或命令参数。

### 4.4 配置兼容性

使用候选核心执行：

```text
<candidate-xray> run -test -c /var/etc/xc/config.json
```

调用必须经过现有平台执行适配器，禁止 `shell`, `io.popen`, 字符串拼接命令或用户可控参数。候选核心只能验证当前已生成配置，不能在校验阶段启动监听、连接节点或修改系统配置。

## 5. 运行时架构改造

### 5.1 核心解析器

新增 `root/usr/lib/lua/xc/core.lua`，负责：

- 读取并校验 `current`/`previous` 标记。
- 解析和验证 manifest。
- 列出手动安装版本并返回脱敏公开字段。
- 生成版本目录和元数据路径。
- 统一判断 `system` 与手动核心的实际执行路径。
- 拒绝越界路径、符号链接、非法 ID、超大 manifest 和不匹配的文件哈希。

该模块不执行 shell，不直接处理 HTTP 请求，不写日志；文件和执行动作通过 platform/runtime 适配器注入，便于 Lua 5.1 单元测试。

### 5.2 platform 适配器

扩展 `root/usr/lib/lua/xc/platform.lua`，提供：

- 流式写入和有限大小读取。
- 文件哈希计算适配器；优先使用设备已有的受控 SHA-256 实现，不能将未声明的外部依赖静默加入运行时。
- ELF 头读取、`uname -m` 读取和文件类型检查。
- 固定 argv 执行 `version` 与 `run -test`，有限超时、有限输出、标准错误脱敏。
- 候选核心执行权限和文件类型检查。
- 可用空间查询、fsync、原子 rename 和安全删除。

如果最终选择新增系统依赖（例如独立的 SHA-256 工具包），必须同步修改 Makefile、21.02/24.10 feeds 检查和安装说明；不能仅在开发机存在时通过测试。

### 5.3 runtime 核心事务

在 `root/usr/lib/lua/xc/runtime.lua` 中增加核心事务，复用当前 XC 运行锁和服务健康检查，但不与节点配置回滚文件混用：

```text
prepare
  -> validate candidate
  -> save current core marker/metadata
  -> write transaction intent
  -> atomically set current marker
  -> restart XC with selected executable
  -> check service/listeners/health
commit
  -> write current/previous metadata
  -> clear transaction
failure
  -> restore previous marker
  -> restart previous core
  -> verify recovery
  -> mark recovery_required if recovery also fails
```

核心事务必须处理这些中断点：标记已更新但服务未重启、服务已重启但健康检查未完成、进程被杀死、LuCI 请求超时和设备重启。启动脚本或首次状态调用应发现未完成 transaction 并执行一次安全恢复，而不是继续使用不确定的核心指针。

### 5.4 init 脚本

修改 `root/etc/init.d/xc`：

- 通过受控 resolver 读取 `current`，只接受 `system` 或已验证的内部版本 ID。
- 解析为 `/usr/bin/xray` 或 `/etc/xc/xray/versions/<id>/xray`。
- `procd_set_param command` 使用解析后的 argv，不经过 shell 命令字符串。
- 解析失败时拒绝启动并写入安全错误日志，不回退到用户可控路径。
- 保留 `restart_prepared`、`running` 等现有测试接口。
- `xray-core` 软件包升级、重装和卸载流程不能被插件脚本改写；系统核心只作为 `system` 选择项。

## 6. LuCI 接口设计

### 6.1 页面

新增 `luasrc/model/cbi/xc/core.lua` 和 `luasrc/view/xc/core.htm`，页面分为：

- 当前核心：来源、版本、架构、SHA-256、运行状态。
- 上传核心：文件、期望 SHA-256、备注、校验结果。
- 已安装版本：版本、架构、大小、SHA-256、校验时间、当前/回滚标记、激活/回滚/删除按钮。
- 操作结果：阶段性状态、失败原因、是否已自动恢复。

页面只展示安全公开字段，不展示完整上传路径、命令行、节点配置或 Xray 原始 stderr。

### 6.2 控制器端点

在 `luasrc/controller/xc.lua` 中增加受 ACL 保护的端点：

```text
GET  /core-status       当前核心和已安装版本
POST /core-upload       流式上传并校验，返回 staged 版本
POST /core-activate     激活指定已校验版本
POST /core-rollback     回滚到 previous 或 system
POST /core-delete       删除未引用的手动版本
```

所有修改端点要求 POST、LuCI CSRF token、固定请求大小和表单字段校验。`id`、版本、SHA-256、备注和文件名都必须经过白名单验证；任何错误都返回稳定的 JSON code，不返回堆栈、命令行或候选核心输出。

> 已实现错误码还包括 `core_hash_invalid`、`core_manifest_invalid`、`core_runtime_unavailable`、`core_recovery_required`；未实现 `core_disk_space_low`（以流式写入失败和 64 MiB 上限拒绝）与 `core_not_staged`（上传校验通过后直接安装为未激活版本，不保留单独 staged 状态）。

建议错误码：

```text
core_upload_too_large
core_disk_space_low
core_invalid_elf
core_arch_mismatch
core_hash_mismatch
core_version_invalid
core_config_invalid
core_not_staged
core_busy
core_activate_failed
core_recovered
core_recovery_failed
core_no_rollback
core_in_use
core_delete_failed
```

### 6.3 权限与日志

- ACL 只允许 LuCI 管理员访问核心管理端点和页面。
- 上传、激活、回滚、删除均记录 XC 自身日志，但只记录动作、版本 ID、架构、大小、哈希前后缀和结果。
- 不记录 multipart 原始内容、上传文件名中的路径、命令输出、环境变量或节点凭据。
- 日志筛选继续沿用现有“全部/错误/警告/信息/调试”，核心操作使用 info，校验和恢复失败使用 error/warning。

## 7. 测试驱动实施任务

### Task 1：冻结核心管理契约和安全路径

**文件：**

- 新增：`root/usr/lib/lua/xc/core.lua`
- 新增：`tests/test_core.lua`
- 修改：`tests/test_platform_static.lua`

- [x] 先写失败测试：路径、ID、manifest、`system` 解析、非法字符、符号链接和版本列表边界。
- [x] 定义 64 MiB 文件限制、manifest 字段上限、版本 ID 白名单和公开返回字段。
- [x] 实现纯 Lua 核心元数据模块，所有 IO 通过注入适配器完成。
- [x] 运行 Lua 5.1 核心测试和包静态检查。

- [x] 实现 `core.lua` 安全 ID/路径/哈希/manifest/版本解析。
- [x] 覆盖 `tests/test_core.lua`、`tests/test_coremanager.lua` 的路径、哈希、架构、事务与删除测试。
- [x] 主机 Lua 5.1 测试与包静态检查通过。

### Task 2：实现上传暂存和二进制校验

**文件：**

- 修改：`root/usr/lib/lua/xc/platform.lua`
- 修改：`root/usr/lib/lua/xc/core.lua`
- 新增：`tests/test_core_validation.lua`
- 修改：`tests/test_check_package.sh`

- [x] 先写 ELF、架构、大小、SHA-256、版本输出和配置测试的失败用例。
- [x] 实现流式临时文件、空间检查、固定 argv 校验和原子安装。
- [x] 验证候选文件不会覆盖 `/usr/bin/xray`，也不会执行任意用户参数。
- [x] 覆盖上传中断、哈希不匹配、错误架构、非 ELF、超时和配置不兼容。

- [x] 实现 `coremanager.lua` ELF/架构/哈希/版本/`run -test` 五级校验。
- [x] 实现 `platform.lua` 流式上传、SHA-256（`/usr/bin/sha256sum` 与 busybox 回退）、固定 argv 与原子写入。
- [x] 上传失败与中断路径清理临时文件；控制器失败分支统一删除候选文件。
- [x] 覆盖哈希不匹配、架构不匹配、非 ELF、超大文件与非法路径测试。

### Task 3：让运行时和 procd 使用选定核心

**文件：**

- 修改：`root/usr/lib/lua/xc/runtime.lua`
- 修改：`root/usr/lib/lua/xc/platform.lua`
- 修改：`root/etc/init.d/xc`
- 新增：`tests/test_core_runtime.lua`
- 修改：`tests/test_platform_process.lua`

- [x] 先写失败测试：候选核心测试、切换前快照、服务失败恢复、重启恢复和系统核心回退。
- [x] 实现核心事务文件和 current/previous 原子标记。
- [x] 将核心路径注入现有 Xray `run -test`、服务 restart 和状态检查流程。
- [x] 用固定 argv 验证 init 脚本，不允许通过 shell 拼接核心路径。
- [x] 确认节点切换、节点回滚和核心回滚三者不会互相覆盖状态文件。

- [x] 实现 `current/previous/transaction` 标记、事务恢复与自动回滚。
- [x] `runtime.lua` 节点切换、配置测试和回滚统一使用 `current` 标记解析的核心。
- [x] init 脚本 `resolve_xray` 拒绝符号链接与非法 ID，`procd_set_param command` 使用解析后的固定 argv。
- [x] 启动时若存在未完成 transaction，先执行 `/usr/bin/xc core-recover` 再启动服务。
- [x] 覆盖激活失败恢复、transaction 中断恢复、无效 transaction、回滚和系统核心回退测试。

### Task 4：增加 LuCI 上传、激活、回滚和删除接口

**文件：**

- 修改：`luasrc/controller/xc.lua`
- 新增：`luasrc/model/cbi/xc/core.lua`
- 新增：`luasrc/view/xc/core.htm`
- 修改：`root/usr/share/rpcd/acl.d/luci-app-xc.json`
- 新增：`tests/test_controller_core.lua`

- [x] 先写端点鉴权、POST、CSRF、大小限制、路径注入和错误码测试。
- [x] 实现 multipart 流式上传，上传完成后只返回安全的校验摘要。
- [x] 实现无整页刷新的激活、回滚、删除操作和 busy 状态展示。
- [x] 删除操作拒绝当前版本、previous 版本和正在事务中的版本。
- [x] 处理恢复成功与恢复失败两种结果，向页面明确显示服务是否已停止。

- [x] 控制器新增 `/core-status`、`/core-upload`、`/core-activate`、`/core-rollback`、`/core-delete` POST 端点。
- [x] `core.htm` 使用 FormData 流式上传并校验 `core_file`/`sha256`/`note` 字段名与后端一致。
- [x] 21.02（Lua `luci.http`）与 24.10（ucode `http.uc`）的 `setfilehandler` 回调签名均已对照源码核实，均为 `(field, chunk, eof)`。
- [x] 删除仅允许未激活且未被 previous 引用的版本；激活/回滚/删除都有明确确认。
- [x] `tests/test_controller_core.lua` 覆盖端点、字段名、DOM 校验与事务恢复优先调用。

### Task 5：中文翻译和页面回归

**文件：**

- 修改：`po/templates/xc.pot`
- 修改：`po/zh_Hans/xc.po`
- 修改：`tests/test_log_ui.js` 或新增 `tests/test_core_ui.js`
- 修改：`README.md`、`README_EN.md`

- [x] 覆盖上传、哈希、架构、版本、当前、回滚、系统核心、恢复和错误提示的完整中文翻译。
- [x] 用 DOM/XHR 测试验证按钮禁用、确认、进度、结果和空列表行为。
- [x] 更新安装说明：正式包仍依赖 `xray-core`，手动版本只通过插件目录管理。
- [x] 更新隐私和安全说明，强调不会覆盖 `/usr/bin/xray`。

- [x] `po/templates/xc.pot` 与 `po/zh_Hans/xc.po` 补齐核心管理翻译。
- [x] `tests/test_core_ui.js` 覆盖按钮禁用、确认、操作结果和空列表。
- [x] README/README_EN 补充核心管理使用说明与隐私说明。
- [x] 版本号提升至 `0.1.0-r7`，避免覆盖旧 IPK。

### Task 6：构建与设备验收

- [x] 在 ImmortalWrt/OpenWrt 21.02 环境编译，安装前已备份 `/etc/config/xc` 和核心目录。
- [x] 上传与设备架构匹配的测试核心，验证 SHA-256、版本和配置检查。
- [x] 激活已安装且通过完整校验的手动核心，确认节点服务、7890/10809 监听、Exit IP 和日志正常。
- [x] 使用故意错误的核心、错误哈希和错误架构验证拒绝流程（设备错误注入 + 主机适配器测试）。
- [x] 验证激活后强制停止服务、模拟健康检查失败，确认自动恢复 previous（主机故障注入测试）。
- [x] 验证 previous 不存在时恢复 `system`，恢复失败时服务进入可识别的 recovery-required 状态（主机故障注入测试，24.10 设备无 previous 时返回 `core_no_rollback`）。
- [x] 在 24.10 上重复核心上传、激活、回滚和 `opkg` 升级/重装兼容性验证。
- [x] 构建 21.02/24.10 适配主包和中文包，运行全部主机测试与包检查，并完成 21.02 目标设备验收。

## 8. 验收标准

功能完成必须同时满足：

- 能上传单个 Xray ELF，并在设备端显示实际 SHA-256、版本、架构和校验结果。
- 错误哈希、错误架构、非 Xray ELF、超大文件、磁盘不足和配置不兼容均被拒绝。
- `/usr/bin/xray` 的 inode、内容和 opkg 所属关系不因手动替换改变。
- 激活成功后，procd 使用选定版本，现有节点切换、测速、日志和状态页面继续工作。
- 激活失败会自动恢复可用旧核心；恢复失败会停止服务并给出明确人工恢复路径，不会静默运行未知核心。
- 回滚操作可在 LuCI 和 `/usr/bin/xc` CLI 使用，且重启设备后 current/previous 状态仍一致。
- 删除不会删除当前核心、回滚核心或事务引用的文件，也不会使用宽泛递归目标。
- 21.02 Lua 5.1/LuCI 和 24.10 LuCI/ucode bridge 均通过测试和设备验收。
- 文档、Release 资产和构建说明明确：核心手动替换是设备本地功能，不是订阅或自动更新功能。

## 9. 风险与取舍

| 风险 | 处理方式 |
| --- | --- |
| 直接覆盖 `/usr/bin/xray` 破坏 opkg | 永不覆盖，系统核心只作为 `system` 选择项 |
| 上传恶意或错误 ELF | ELF/架构/哈希/版本/配置五级校验；仅管理员可操作 |
| 核心启动后立即崩溃 | procd 状态、监听和健康检查；失败自动恢复 |
| 设备重启发生在切换中 | transaction 文件 + 启动时恢复流程 |
| 21.02 与 24.10 工具差异 | Lua 5.1、nixio、固定 argv；不依赖新 Go 或新 LuCI API |
| overlay 空间不足 | 上传前空间检查、版本保留策略和安全删除 |
| 用户误删回滚版本 | 当前/previous/事务引用版本禁止删除 |
| Xray 新版本配置行为变化 | 以目标设备实际 `run -test` 和健康检查为最终门禁，不承诺所有版本兼容 |

## 10. 交付顺序

1. 先完成 Task 1–3，确保核心管理、校验、运行时路径和事务在主机测试中稳定。
2. 再完成 Task 4–5，接入 LuCI、ACL 和中文界面。
3. 必须先在 21.02 设备上备份配置并验证完整流程，再在 24.10 设备复测。
4. 两套设备均通过后再更新 README、版本号、IPK 和 GitHub Release；失败测试或设备回滚未验证前不发布。
