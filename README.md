# luci-app-xc

适用于 OpenWrt / ImmortalWrt 21.02–24.10 的 LuCI Xray 节点管理插件。

## 功能

- **节点管理**：新增、编辑、删除自建节点，支持 VLESS、VMess、Trojan、Shadowsocks、SOCKS、raw outbound
- **手动切换**：选择一个节点后所有流量统一走该节点
- **快速测速**：单节点或全部测试，并发度 1–5（默认 3），参考 SSR Plus 风格
- **本地导入**：通过粘贴或文件导入分享链接，预览确认后提交
- **健康切换**：切换节点时自动验证 Xray 配置、监听端口和 HTTP 健康检查，失败自动回滚
- **手动回滚**：保留上一份可用配置，一键恢复
- **状态监控**：5 秒轮询显示运行状态、Endpoints 与出口 IP
- **日志查看**：尾部读取 / 清空操作日志，明文内容自动脱敏

## 不包含

- ❌ 订阅管理
- ❌ 透明代理（TPROXY / TUN）
- ❌ sing-box 内核支持
- ❌ 专用节点分流
- ❌ 多用户 / 多配置

## 依赖

- `luci-compat` `lua` `libuci-lua` `luci-lib-jsonc`
- `curl` `ca-bundle`
- `xray-core`（建议 >= 1.8.0）

## 安装

### 通过 feeds 源

```
cd /path/to/openwrt
echo "src-git xc https://github.com/deanzai/luci-app-xc.git" >> feeds.conf.default
./scripts/feeds update xc
./scripts/feeds install luci-app-xc
make package/luci-app-xc/compile V=s
```

### SDK 编译

```
git clone https://github.com/deanzai/luci-app-xc.git package/luci-app-xc
./scripts/feeds update base
./scripts/feeds install luci-compat luci-lib-jsonc
make package/luci-app-xc/compile V=s
```

编译产物位于 `bin/packages/*/luci/luci-app-xc_0.1.0-1_all.ipk`。

### 路由器直接安装

```
opkg install /tmp/luci-app-xc_0.1.0-1_all.ipk
```

安装前会自动备份旧 xc 脚本配置到 `/etc/xc/legacy-backup-<timestamp>/`。

## 使用

1. 安装后登录 LuCI -> 服务 -> Xray node switching
2. **设置页**：开启插件，配置监听地址和端口
3. **节点页**：添加自建节点（支持 VLESS、VMess 等协议）
4. **状态页**：查看运行状态、测试节点、切换或回滚
5. **导入页**：粘贴分享链接或上传文件，预览后确认

### SOCKS / HTTP 代理

启用插件后默认监听：
- SOCKS5：`192.168.6.1:7890`
- HTTP CONNECT：`192.168.6.1:10809`

## 迁移

如果从旧版 xc 脚本升级，首次安装时自动：
1. 备份旧配置到 `/etc/xc/legacy-backup-<timestamp>/`
2. 转换节点到新 UCI 格式
3. 仅在新配置通过 Xray 验证后禁用旧服务

## 恢复

如果新配置出现问题，手动回滚：

```
/usr/bin/xc rollback
```

或从备份手动恢复：

```
cp /etc/xc/legacy-backup-*/nodes.json /etc/xc/nodes.json
# 然后重新安装旧版 xc 脚本
```

## 开发

```
git clone https://github.com/deanzai/luci-app-xc.git
cd luci-app-xc
sh scripts/bootstrap-lua.sh
.tools/lua5.1 tests/run.lua
```

## 许可证

GPL-3.0-only
