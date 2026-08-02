# XC 开发踩坑复盘与扩展约束

更新日期：2026-07-31

本文记录 `luci-app-xc` 从设计、构建、部署到发布过程中已经遇到的问题。后续扩展功能前应先检查本文，避免重复引入路径、凭证、兼容性、依赖和运行时问题。

## 1. GitHub 凭证状态

当前环境的实际状态：

- WSL 中的 GitHub CLI 尚未登录。
- WSL Git 没有可用的凭据助手，直接通过 HTTPS 推送会报 `could not read Username for 'https://github.com'`。
- Windows Git Credential Manager 已配置，可以正常推送。
- 推送需要通过代理 `http://192.168.6.1:7890`。

当前可靠的推送方式：

```bash
'/mnt/c/Program Files/Git/cmd/git.exe' \
  -C 'C:\Users\sdjam\Documents\设计xray切换插件（luci）\.worktrees\implement-luci-app-xc' \
  -c http.proxy=http://192.168.6.1:7890 \
  push origin main
```

安全要求：

- 不得把 PAT 写入远程 URL、源码、脚本、日志或 Git 配置。
- 不得使用 `https://TOKEN@github.com/...` 形式的远程地址。
- 优先使用 Windows Credential Manager；如需改用 WSL Git，应先执行 `gh auth login` 或安全配置凭据助手。
- 曾经通过非安全渠道暴露的 Token 应废止并重新签发，设备密码也应定期轮换。

## 2. Windows、WSL 与 Git worktree 路径

正式项目工作树：

```text
/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）/.worktrees/implement-luci-app-xc
```

固定构建副本：

```text
/home/dean/xc-build/luci-app-xc
```

OpenWrt 21.02 Buildroot：

```text
/home/dean/immortalwrt-mt798x-21.02
```

注意事项：

- 不要直接相信自动提供的当前目录；Windows 路径与 WSL 路径可能被错误拼接。
- worktree 的 `.git` 文件保存的是 Windows 路径，WSL Git 不一定能自动识别。
- 源码修改只在正式 worktree 中完成，Buildroot 固定副本只用于构建。
- 临时修改构建副本后必须恢复，并用 `cmp` 确认它与工作树同步。
- 不得把 Buildroot 中的副本当作源码主仓库。

WSL Git 无法识别 worktree 时，显式指定 Git 元数据和工作树：

```bash
git \
  --git-dir='/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）/.git/worktrees/implement-luci-app-xc' \
  --work-tree='/mnt/c/Users/sdjam/Documents/设计xray切换插件（luci）/.worktrees/implement-luci-app-xc' \
  status
```

## 3. OpenWrt 21.02/23.05/24.10 构建兼容

最低支持版本为 OpenWrt/ImmortalWrt 21.02，指定构建源为：

```text
repository: https://github.com/hanwckf/immortalwrt-mt798x.git
branch: openwrt-21.02
verified commit: ba554197ed
target: mediatek/mt7986
device: Zyxel EX5700
```

21.02 的旧版 `luci.mk` 对版本字段的处理与新版本不同，可能忽略主包中的 `PKG_RELEASE`。为生成版本正确的 IPK，构建副本可以临时改为：

```make
PKG_VERSION:=0.1.0-r5
PKG_PO_VERSION:=0.1.0-r5
```

这只是构建兼容措施，不得提交回源码。仓库中的标准写法必须保持：

```make
PKG_VERSION:=0.1.0
PKG_RELEASE:=5
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)
```

每次构建后必须检查 IPK 的 control 信息和 SHA256，不能只看文件名。

23.05 和 24.10 也必须使用各自版本的 SDK/Buildroot 与 feeds；不能把一个版本的
`luci.mk`、LuCI 运行时或 `xray-core` 混入另一个版本。仓库 CI 固定构建三套平台：

```text
OpenWrt 21.02 -> ARCH=x86_64-openwrt-21.02
OpenWrt 23.05 -> ARCH=x86_64-23.05.6
OpenWrt 24.10 -> ARCH=x86_64-24.10.8
```

IPK 虽然标记为 `all` 架构，依赖的 LuCI/运行时 ABI 和 Xray 包仍由目标发行版决定。
设备安装时必须选择同一平台的主包与中文包。

## 4. Xray 依赖与设备现有内核

通用包应继续声明 `+xray-core`，保证普通用户通过 opkg 安装时依赖完整。

`192.168.13.1` 属于特殊设备环境：

- 设备已有独立安装的新版 Xray。
- `/usr/bin/xray` 存在，但没有登记到 opkg 数据库。
- 软件源中的 `xray-core` 版本较旧。
- 直接安装通用包可能导致 opkg 安装旧内核并覆盖现有新版 Xray。

设备适配规则：

- 仓库源码保持标准 `+xray-core` 依赖。
- 仅在明确确认设备已有可用 Xray 时，临时构建移除包级 `xray-core` 依赖的设备适配包。
- 安装完成后立即恢复固定构建副本。
- 不得使用 `opkg --force-depends` 绕过依赖检查。

部署前至少检查：

```sh
/usr/bin/xray version
opkg list-installed | grep '^xray-core '
opkg info xray-core
```

## 5. Lua 5.1 与 LuCI 兼容

Lua 5.1.5 是 OpenWrt 21.02 和传统 LuCI Lua API 的兼容基线，不是为了主动使用旧版本。所有 Lua 代码必须以 Lua 5.1 语法和标准库为最低要求。

风险点：

- 不使用新版本 Lua 才支持的语法或标准库函数。
- PC 宿主测试通过，不代表设备上的 `luci-compat` 和 ucode bridge 一定可以加载。
- LuCI 21.02、新版 LuCI 和 ucode bridge 的 Controller、CBI 行为并不完全一致。

部署后至少验证：

```sh
lua -e 'require("luci.controller.xc")'
```

## 6. LuCI Controller 与 ucode bridge

曾经出现：

```text
attempt to call global 'call' (a nil value)
```

原因是 Controller 使用了旧式隐式全局 `call()`，而目标设备的 ucode bridge 没有提供该全局函数。

后续要求：

- 不依赖隐式全局 `call`。
- 使用当前最低支持 LuCI 版本兼容的路由 action 写法。
- Controller 静态测试通过后，仍需在真实设备检查菜单树和页面请求。

## 7. CBI datatype 兼容

曾经出现：

```text
Datatype error, bad token "url"
```

目标 LuCI 版本不支持 CBI 中使用的 `url` datatype token。最低兼容 21.02 时，只能使用该版本已存在的 datatype。URL、URI、节点链接等复杂输入应通过自定义 `validate()` 校验。

每次新增或修改 CBI 字段都必须在真实设备执行一次“保存并应用”，不能只验证页面能否打开。

## 8. 配置保存与快速切换必须分离

节点编辑属于配置管理流程：

```text
新增或编辑 -> 保存并应用
```

节点切换属于运行时流程：

```text
点击切换 -> 验证节点 -> 生成配置 -> 重启 Xray -> 健康检查 -> 成功或回滚
```

快速切换不应依赖整个 CBI 页面保存和刷新，否则会混入未保存字段、增加等待时间并降低错误反馈质量。独立“切换”按钮和当前节点高亮应继续保留。

## 9. SOCKS 测速的 0 ms 不代表失败

本地 NaiveProxy SOCKS 节点可能在一毫秒内完成 TCP 检查，耗时取整后变成：

```json
{"socket":"ok","ping":0}
```

正确判断规则：

- `socket == "ok"` 且 `ping >= 0` 表示测速成功。
- `0 <= ping < 1` 显示 `<1 ms`。
- socket 失败、非法数值或明确超时才显示错误。

不能只依据延迟数值判断测速是否成功，必须联合 `socket` 和 `outcome`。

## 10. Xray 日志级别与页面筛选不同

Xray 日志设置决定后台产生哪些日志：

- `error`：只产生错误日志。
- `warning`：产生警告和错误日志。
- `info`：产生信息、警告和错误日志。
- `debug`：产生完整调试日志。
- `none`：不产生 Xray 日志。

日志页面的“全部、错误、警告、信息、调试”只筛选已经产生的日志。后台设置为 `error` 时，页面选择“调试”不会产生调试日志。

日志来源：

- XC 自身日志：`/var/log/xc.log`。
- Xray 内核日志：系统日志中带精确 `xray[PID]` 标签的记录。

两者可以合并展示，但“清空日志”只清理 XC 自身日志，不能清空整个系统日志。

## 11. 日志隐私与文件权限

日志不得记录：

- UUID、密码或 Token。
- 完整节点链接。
- Authorization 请求头。
- Raw outbound JSON。
- 包含凭据的代理 URL。

日志只记录操作类型、节点内部 ID、结果、稳定错误码和耗时等安全字段。

关键权限要求：

```text
/etc/config/xc       0600
/etc/xc              0700
/etc/xc/rollback     0700
```

## 12. 切换、事务和回滚

节点切换不能简化为修改一个 UCI 值。正确顺序是：

```text
加锁
-> 验证目标节点
-> 生成候选配置
-> 执行 Xray 配置测试
-> 保存事务证据
-> 安装运行配置
-> 重启服务
-> 等待 SOCKS/HTTP 监听
-> 执行健康检查
-> 提交 active 节点
-> 清理事务
```

任一阶段失败都必须恢复旧配置、旧 active 节点和旧服务状态，同时保留不含凭据的错误信息。不得破坏上一份有效回滚快照，也不能把“重启命令返回 0”直接等同于切换成功。

## 13. 部署前必须备份

升级前应备份：

```text
/etc/config/xc
/etc/xc/
/usr/bin/xc
/etc/init.d/xc-xray
```

部署到 `192.168.13.1` 时使用过的备份目录：

```text
/tmp/xc-r5-backup-192-168-13-1-20260731-0001
```

`/tmp` 在设备重启后可能丢失。生产环境中的长期备份应下载到电脑或放入持久存储。安装成功后可以删除上传到 `/tmp` 的 IPK，但不要立即删除备份。

## 14. IPK 不纳入 Git 源码提交

仓库 `.gitignore` 已忽略 `*.ipk`。Git 提交应包含源码、测试、翻译、Makefile 版本号和文档。IPK 应作为构建产物保存或上传至 GitHub Release，不应强制加入源码提交。

每次发布应记录：

- 源码提交 ID。
- Buildroot 源码和提交 ID。
- 目标架构。
- IPK SHA256。
- IPK control 信息。
- 真实设备验证结果。

CI 上传前会调用 `scripts/prepare-release-assets.sh`，将 SDK 原始文件名复制为带平台后缀
的资产，例如：

```text
luci-app-xc_0.1.0-r9_all_openwrt-23.05.ipk
luci-i18n-xc-zh-cn_0.1.0-r9_all_openwrt-23.05.ipk
SHA256SUMS-openwrt-23.05.txt
```

Release 不应同时上传无后缀的同名 IPK；21.02 即使因旧 `luci.mk` 生成了不带 `-r9` 的
原始文件，也必须经过脚本加上 `openwrt-21.02` 后缀再发布。

## 15. 固定验证和发布顺序

后续扩展功能统一使用以下顺序：

```text
修改源码
-> 定向回归测试
-> 完整宿主测试
-> OpenWrt 21.02/23.05/24.10 构建
-> 检查 IPK control 和 SHA256
-> 备份目标机配置
-> 安装 IPK
-> 检查 Lua Controller 加载
-> 检查 XC 服务
-> 执行 /usr/bin/xc test
-> 检查监听端口
-> 实际操作 LuCI 页面
-> 检查日志和敏感信息
-> 代码审查
-> 提交
-> 推送
```

核心原则：

- 源码与构建副本分离。
- 通用依赖与设备适配分离。
- 配置保存与运行时切换分离。
- 日志产生级别与页面筛选分离。
- 自动测试通过与真实设备验证分离。
