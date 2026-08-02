# XC 预设分流与 Geo 资源设计

## 目标

让 XC 生成的 Xray 配置真正使用旧 `xc` 预设中的分流规则，同时保证缺少
`geosite.dat` 或 `geoip.dat` 时不会静默启动错误配置。

## 规则语义

插件内置一组可审计、无凭据的预设规则，默认启用：

1. `geosite:category-ads-all` 进入 `block`；
2. `geoip:private`、`geosite:private` 进入 `direct`；
3. 旧配置中的自定义域名/IP 直连规则进入 `direct`；
4. 指定 OpenAI、YouTube、Twitter、Telegram、TikTok、Netflix、Google、Facebook
   等域名使用当前选中节点；旧的 `reality-uk` 标签统一映射为
   `proxy-selected`，因为插件只维护一个选中出站；
5. `geosite:geolocation-!cn` 使用当前选中节点；
6. `geoip:cn`、`geosite:cn` 进入 `direct`；
7. 旧配置中的自定义代理域名使用当前选中节点。

备份中的第一条无匹配条件规则不直接复制；Xray 未命中其他规则时已经使用
第一个出站 `proxy-selected`，因此该语义由默认出站保持，避免遮蔽后续规则。

## 资源与运行时

- 固定资源目录为 `/usr/share/xray`，需要 `geosite.dat` 和 `geoip.dat`。
- `/usr/bin/xc` 与 procd 服务导出 `XRAY_LOCATION_ASSET=/usr/share/xray`。
- 渲染、切换和当前配置测试在生成前检查资源文件；缺失时返回稳定错误码
  `routing_assets_missing`，不写入候选配置、不重启服务。
- 关闭 `routing_enabled` 时只保留私有 CIDR 直连规则，不要求 Geo 资源，便于
  故障排查和兼容没有资源文件的旧安装。

## 接口与兼容性

- 新增纯 Lua `xc.routing` 模块，返回独立的路由表，兼容 Lua 5.1。
- `xc.generator` 只负责把路由表嵌入 Xray 配置，不读取文件系统。
- `xc.runtime` 负责资源存在性检查，保持现有事务与回滚流程。
- 23.05、21.02、24.10 共用同一 Lua 实现；Geo 数据不打包进 IPK，由部署/发布
  流程单独提供。

## 验证

- 生成器测试断言所有预设规则、标签映射和关闭开关行为。
- 运行时测试断言两个资源都存在时继续生成，任一缺失时返回
  `routing_assets_missing` 且不调用 Xray。
- 主机测试、包结构检查、Xray `run -test` 和设备上的实际配置检查全部通过后
  才提交和推送。
