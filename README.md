# luci-app-xc

适用于 OpenWrt / ImmortalWrt 21.02–24.10 的 LuCI Xray 自建节点管理与切换插件。

插件使用 Xray-core 作为运行内核，只管理一组自建节点。启用后，当前选中的节点作为统一出口，并应用内置 GeoIP/GeoSite 预设分流；暂不实现订阅、透明代理或可视化专用节点分流。

## 功能

- **节点管理**：新增、编辑、删除和启用/禁用节点
- **协议支持**：结构化支持 VLESS、VMess、Trojan、Shadowsocks、SOCKS；不常见组合可填写完整的 raw outbound JSON
- **快速切换**：节点行内直接切换，成功后当前节点高亮，不需要等待 CBI 页面保存并刷新
- **节点测速**：单节点测速或全部测速；并发度可设置为 1–5，默认 3。测速是连通性与延迟测试，不是带宽测速
- **本地导入**：粘贴分享链接或上传文本/JSON 文件，先预览，确认后导入；不提供订阅拉取
- **安全切换**：切换前校验 Xray 配置，启动后检查 SOCKS/HTTP 监听和健康检查 URL；失败时恢复上一份可用配置
- **手动回滚**：保留上一份运行配置，可从状态区域或 `/usr/bin/xc rollback` 回滚
- **核心管理**：可在 LuCI 上传单个 Xray-core ELF，校验 SHA-256、设备架构、版本和当前配置后再激活
- **核心回滚**：核心激活失败时自动恢复上一个核心；手动版本不会覆盖 `/usr/bin/xray`
- **状态监控**：设置页内显示服务状态、当前节点、监听端点和经当前节点访问得到的出口 IP
- **日志查看**：单一日志页合并 XC 插件日志和 Xray 运行日志，支持全部/错误/警告/信息/调试筛选
- **隐私保护**：访问日志关闭；节点密码、UUID、分享链接、raw JSON 中的敏感字段和日志中的凭据自动脱敏

## 设置项

设置页中的主要选项如下：

| 设置 | 说明 | 默认值 |
| --- | --- | --- |
| Enable | 启用或停用 XC 服务 | 关闭 |
| Xray log level | 控制 Xray 后台实际产生的运行日志 | `warning` |
| Geo routing | 启用预设 GeoIP/GeoSite 分流；关闭后仅保留私有网段直连 | `1` |
| Active node | 选择当前统一出口节点；只有启用的节点可选 | 未选择 |
| Listen mode | 当前支持 LAN 地址 | `lan` |
| Listen address | 从 `network.lan` 自动获取，页面只读；失败时回退 `127.0.0.1` | 自动 |
| SOCKS port | 本地 SOCKS5 监听端口 | `7890` |
| HTTP port | 本地 HTTP CONNECT 监听端口 | `10809` |
| Probe concurrency | 全部测速时的并发数 | `3` |
| Probe timeout | 单节点连通性测试超时时间，范围 1–10 秒 | `3` 秒 |
| Probe URL | 节点测速使用的 HTTP/HTTPS 地址 | `https://www.gstatic.com/generate_204` |
| Health check URL | 切换后健康检查及出口 IP 检测地址 | `https://api.ipify.org` |
| Health check timeout | 切换后的健康检查超时时间，范围 1–30 秒 | `15` 秒 |

Xray 日志级别决定后台会产生什么内容：`error` 只产生错误，`warning` 产生警告和错误，`info` 产生信息及更严重日志，`debug` 产生完整调试日志。日志页的筛选只是筛选已经产生的日志，不会让 Xray 临时生成更低级别的日志。

日志页只有一个页签，显示两类来源：

- XC 自身的启动、停止、切换、测速、导入、回滚、配置渲染和错误记录
- Xray 运行时日志（通过系统日志读取，访问日志保持关闭）

“清空日志”只清空 XC 自身日志，不会清除 OpenWrt 的共享系统日志或 Xray 历史记录。

## 不包含

- ❌ 订阅管理（用的自建节点，不加入额外的订阅功能）
- ❌ 透明代理（TPROXY / TUN）
- ❌ sing-box 内核支持（纯xray-core）
- ❌ 可视化专用节点分流页面配置功能（内置预设规则仍会生效）
- ❌ 多用户 / 多配置
- ❌ Xray-core 自动下载、订阅式升级和远程升级

## 依赖与兼容性

- `luci-compat`、`lua`、`libuci-lua`、`luci-lib-jsonc`
- `curl`、`ca-bundle`
- `v2ray-geoip`、`v2ray-geosite`：提供 GeoIP/GeoSite 资源
- `xray-core`：由目标 OpenWrt/ImmortalWrt 的 feeds 提供，插件不内置核心

同一份插件源码可以在 21.02、23.05 或 24.10 的 SDK/Buildroot 中分别编译，但必须使用对应版本的构建环境和 feeds：

```text
21.02 SDK/Buildroot -> 21.02 版 luci-app-xc IPK + 21.02 版 xray-core
23.05 SDK/Buildroot -> 23.05 版 luci-app-xc IPK + 23.05 版 xray-core
24.10 SDK/Buildroot -> 24.10 版 luci-app-xc IPK + 24.10 版 xray-core
```

不要把一个发行版环境生成的 IPK 当作其他发行版的正式包直接发布。插件包本身虽为 `all` 架构，依赖和 LuCI/核心版本仍由目标发行版决定。

最低支持 Lua 5.1 和 LuCI 21.02；23.05 和 24.10 使用各自 feeds 中的 LuCI/Xray 依赖。代码不依赖 sing-box，也不要求升级 21.02 的 Go 工具链。

## Geo 分流资源

启用 `Geo routing` 时，设备必须同时存在以下两个文件：

```text
/usr/share/xray/geosite.dat
/usr/share/xray/geoip.dat
```

插件优先使用 `/usr/share/xray`。在 OpenWrt/ImmortalWrt 21.02 上，若该目录不存在完整资源，
会回退到 `v2ray-geoip`/`v2ray-geosite` 提供的路径：

```text
/usr/share/v2ray/geosite.dat
/usr/share/v2ray/geoip.dat
```

23.05/24.10 通常使用 `/usr/share/xray`；两套路径都会按“两个文件同时存在”选择，
不会混用。生成的 Xray 配置使用 `domainStrategy=IPIfNonMatch`，保证域名规则未命中时
仍可通过 GeoIP 进行后续解析。

插件会在渲染、切换和启动前检查文件；任一文件缺失都会返回
`routing_assets_missing`，不会启动错误配置。资源文件不打包进 LuCI IPK，需从目标
发行版的 Xray 资源包或已验证设备同步。临时排查时可在设置页关闭 `Geo routing`，此时只保留私有网段直连。

## 安装

### 通过 feeds 源

```sh
cd /path/to/openwrt
echo "src-git xc https://github.com/deanzai/luci-app-xc.git" >> feeds.conf.default
./scripts/feeds update xc
./scripts/feeds install luci-app-xc
make package/luci-app-xc/compile V=s
```

### SDK 或源码树编译

```sh
git clone https://github.com/deanzai/luci-app-xc.git package/luci-app-xc
./scripts/feeds update base
./scripts/feeds install luci-compat luci-lib-jsonc xray-core v2ray-geoip v2ray-geosite
make package/luci-app-xc/compile V=s
```

当前源码包版本为 `0.1.0-r16`，常见产物路径为：

```text
bin/packages/**/luci-app-xc_0.1.0-r16_all.ipk
```

GitHub Actions 同时构建 OpenWrt 21.02、23.05 和 24.10。21.02、23.05 的旧版 `luci.mk`
可能忽略 `PKG_RELEASE`，因此 SDK 原始产物可能使用不带 release 后缀的文件名。CI 会在上传前为每个
原始 IPK 加上明确的平台后缀，避免 Release 中出现无法判断目标系统的同名文件：
同时将主包和翻译包的 control 元数据版本规范化为 `0.1.0-r16`，确保可以从旧版
`0.1.0-10` 正常升级：

```text
21.02: luci-app-xc_0.1.0-r16_all_openwrt-21.02.ipk
23.05: luci-app-xc_0.1.0-r16_all_openwrt-23.05.ipk
24.10: luci-app-xc_0.1.0-r16_all_openwrt-24.10.ipk
```

中文翻译包由 LuCI 的 PO 版本单独生成，并使用相同的平台后缀：

```text
luci-i18n-xc-zh-cn_0.1.0-r16_all_openwrt-21.02.ipk
luci-i18n-xc-zh-cn_0.1.0-r16_all_openwrt-23.05.ipk
luci-i18n-xc-zh-cn_0.1.0-r16_all_openwrt-24.10.ipk
```

每个平台的 CI 资产还包含对应的 `SHA256SUMS-openwrt-<版本>.txt`。安装时只选择与设备
发行版匹配的两个 IPK（主包和中文包），不要根据 `all` 架构判断跨版本兼容。

### 路由器直接安装

安装前先备份 `/etc/config/xc` 及旧版 XC 运行文件，然后安装对应目标系统编译出的 IPK：

```sh
opkg install /tmp/luci-app-xc_0.1.0-r16_all.ipk /tmp/luci-i18n-xc-zh-cn_0.1.0-r16_all.ipk
```

如果使用 GitHub Release 资产，请将上面两个文件替换为同一平台后缀的 IPK；中文包不是
主包的运行时依赖，必须显式安装才会显示完整简体中文界面。

不要使用 `opkg --force-depends`。如果设备已经手动安装了未被 opkg 管理的 Xray，应先确认核心可执行文件和版本，再使用不覆盖该核心的设备适配包；正式发布包仍保留 `xray-core` 依赖。

## 使用流程

安装后打开 LuCI：`服务 → Xray node switching`。

1. **设置**：启用插件，检查监听地址、端口、测速和健康检查参数。
2. **节点**：新增或编辑自建节点；节点列表同行提供测速、切换、编辑和删除操作。
3. **切换**：点击目标节点的“切换”。插件会独立完成验证、启动、健康检查和必要的回滚；不需要先点击“保存并应用”。
4. **配置保存**：新增、编辑、启用/禁用、端口或 URL 修改仍使用 LuCI 的“保存并应用”。这是配置管理流程，与节点快速切换流程分开。
5. **测速**：使用“测速”测试单个节点，或使用“全部测速”按配置的并发度批量测试；结果显示在“延迟”列。
6. **日志**：按全部、错误、警告、信息或调试筛选，点击刷新读取最新内容。筛选不会改变 Xray 的后台日志级别。

### Xray-core 手动替换

打开 `服务 → Xray node switching → Xray core`，选择与设备架构匹配的单个 Xray ELF 可执行文件。插件会在设备端计算 SHA-256，并检查 ELF 架构、`xray version` 输出和当前配置的 `run -test`；校验通过后才会写入版本目录。

核心激活使用与节点切换相同的运行锁，更新前保存当前核心，重启后检查服务、监听器和健康检查。失败时自动恢复上一份核心；如果当前是手动核心但没有可用的 previous 标记，页面“回滚”会安全回到系统核心。系统包核心始终指向 `/usr/bin/xray`，手动版本存放在 `/etc/xc/xray/versions/`，不会改写 `opkg` 管理的文件。

### SOCKS / HTTP 代理

启用并成功切换节点后，插件监听在当前 LAN 地址的：

- SOCKS5：`<LAN 地址>:7890`
- HTTP CONNECT：`<LAN 地址>:10809`

监听地址不是固定的 `192.168.6.1`，而是从设备的 `network.lan` 自动获取。实际地址和端口以状态区域显示为准。

### 出口 IP

状态页的 `Exit IP` 是通过 XC 本地 SOCKS 监听、经当前节点访问健康检查 URL 后观察到的公网 IP，不是路由器本地 WAN 地址。结果会在受保护的运行目录中短暂缓存；服务或监听不健康时显示 `Unavailable`。

## 迁移与恢复

如果从旧版 xc 切换脚本升级，首次安装会在 `/etc/xc/legacy-backup-<timestamp>/` 创建权限受限的备份，并在验证通过后接管服务：

1. 备份旧的节点、当前配置、运行配置和旧服务文件（存在时）
2. 将旧节点转换为新 UCI 格式
3. 用 Xray `run -test` 验证候选配置
4. 接管成功后停止并禁用旧的 `xc-xray` 服务

迁移失败时保留旧服务和备份，不应强行覆盖配置。出现运行问题时可执行：

```sh
/usr/bin/xc status
/usr/bin/xc test
/usr/bin/xc rollback
```

也可以从备份目录手动恢复，然后重新启动旧版脚本服务。恢复前请先确认备份目录和目标文件，避免覆盖新的有效配置。

## 开发与验证

```sh
git clone https://github.com/deanzai/luci-app-xc.git
cd luci-app-xc
sh scripts/bootstrap-lua.sh
sh tests/run-host.sh
```

提交前应在目标 21.02/23.05/24.10 构建环境分别编译，并在实际设备验证 LuCI 菜单、配置保存、节点切换、测速、日志和回滚。

## 许可证

GPL-3.0-only
