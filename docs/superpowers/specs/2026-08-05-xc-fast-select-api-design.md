# XC 快速切换 API 设计规格

**日期：** 2026-08-05  
**分支：** `fast_select_api`

## 背景

当前节点切换把“选择节点”和“验证节点可用性”放在同一个运行时事务中：插件生成只包含目标节点的 Xray 配置，执行配置检查，替换运行时配置，重启 Xray，等待 SOCKS/HTTP 监听，再通过代理执行真实连接检查，最后才提交 `active_node`。真实连接检查对判断节点可用性有价值，但它不应阻塞用户已经明确的手动选择，因此当前切换操作会明显慢于直接修改代理组的实现。

MetaCubeXD 的切节点方式是向常驻 Mihomo 进程的代理组 API 写入目标名称，进程内立即改变选择，连接验证和旧连接处理是独立动作。本设计将同一边界应用到 Xray：常驻 Xray 进程负责节点转发，Routing API 负责改变 balancer 的当前选择，安全切换事务继续保留。

## 目标

1. 在不更换 Lua 5.1/LuCI 技术栈的前提下，新增不重启 Xray 的快速切换路径。
2. 快速切换只在 Xray API 和动态 balancer 配置可用时执行，并在 API 返回后读取状态确认目标确实生效。
3. 快速切换成功后立即持久化 `active_node`，不等待真实连接检查。
4. Xray 重启或设备重启后恢复已持久化的 balancer 选择。
5. API 调用失败、状态不一致或持久化失败时，不破坏原节点选择；持久化失败要恢复旧选择。
6. 保留现有“安全切换”路径，用于首次生成配置、动态模式不可用和需要完整真实连接验证的场景。

## 非目标

- 不更换开发语言，不引入新的常驻守护进程。
- 不把节点健康检查删除或改成快速切换的同步前置条件。
- 不实现 MetaCubeXD 的连接管理、连接关闭或完整代理组 UI；本次只实现 Xray balancer 选择和必要的状态刷新。
- 不把 API 入站暴露到 LAN 或 WAN。

## 方案比较

### 方案 A：每次切换继续重生成配置并重启 Xray

改动最少，安全事务已经存在，但切换延迟仍由进程重启、监听等待和真实连接检查决定，无法解决本次核心问题。

### 方案 B：另起代理进程，通过外层转发切换节点

可以绕开 Xray 配置重启，但会引入额外进程、监听端口、生命周期和故障恢复复杂度，且会改变已有运行架构。

### 方案 C：Xray 常驻进程 + Routing API 动态切换（采用）

启动时生成所有启用节点 outbound 和一个 balancer；手动快速切换只通过本机 Xray API 执行 balancer override。该方案与现有 Xray 版本能力匹配，切换路径短，且可保留现有安全事务作为兼容路径。

## 架构设计

### 动态 Xray 配置

生成器增加动态模式配置，所有启用节点各生成一个 outbound，使用稳定且不包含敏感信息的 tag：

```text
xc-node-<section_id>
```

配置增加：

- `balancers: [{ tag: "xc-balancer", selector: ["xc-node-"] }]`
- 代理流量规则使用 `balancerTag: "xc-balancer"`，不再把业务流量固定到 `proxy-selected`。
- 仅监听 `127.0.0.1:10085` 的 Xray API 入站。
- Xray `api.services` 只启用 `RoutingService`。
- API 入站走本地 API 出站，不进入节点 balancer。

动态模式只纳入启用且通过现有 schema 校验的节点。节点 tag 由受限 section ID 派生，不能由节点原始字段或分享链接内容控制。

现有单节点配置仍作为安全模式保留：使用 `proxy-selected`，只生成当前目标 outbound，不启用动态 API。

### 快速切换事务

运行时新增 `fast_switch(section_id)`，事务顺序如下：

1. 在运行时锁内校验 section ID、目标节点存在且已启用。
2. 读取当前持久化节点，并确认动态配置文件存在、Xray 服务处于运行状态。
3. 使用固定参数调用 Xray API `bo`，把 `xc-balancer` override 到目标 `xc-node-<id>`。
4. 使用 API `bi` 读取 `xc-balancer`，只有返回的当前选择与目标 tag 一致才算成功。
5. 通过现有 UCI adapter 设置并提交 `active_node`。
6. 若提交失败，调用 `bo` 恢复旧 tag；恢复也失败时返回明确的 recovery-required 状态并记录内部节点 ID和错误码，不记录节点凭据。
7. 成功返回 `fast_switched`、目标 section ID 和耗时；不执行 Xray 重启、监听等待或真实连接检查。

API 不可用、当前配置不是动态模式、目标节点不在 balancer 中或 `bi` 状态不匹配时，快速路径返回失败，不自动偷偷切换到慢速路径。调用方可以明确选择现有安全切换入口，避免用户误以为已经完成了真实连接验证。

### 启动恢复

`/etc/init.d/xc` 启动动态配置并确认 Xray 进程进入运行状态后，读取 UCI 中的 `active_node`，通过固定 API 执行一次 `bo` 并用 `bi` 确认。恢复失败不得让已通过配置检查的 Xray 进程反复重启；服务状态和插件 status API 要报告恢复错误，节点页显示当前选择未知或恢复失败。

首次生成动态配置时，选择持久化的 `active_node`；若没有有效持久化选择，则使用排序后的第一个启用节点，并在 API 恢复成功后写入该选择。没有启用节点时仍按现有错误处理，不能生成可启动但没有代理节点的动态配置。

### 配置变化与兼容

- 节点增删、节点字段修改、监听端口修改、路由设置修改仍通过生成候选配置并重启 Xray 的安全路径完成。
- 保存配置不等于快速切换；配置提交后的服务 reload 按现有 procd 流程执行。
- 动态配置生成失败或 Xray 版本不支持 Routing API 时，安全切换仍可用。
- 普通安全切换成功后，下一次配置生成重新建立所有 outbound 和 balancer，随后启动恢复逻辑把选择恢复到新的 `active_node`。
- 快速切换不改变健康检查缓存，也不把健康检查结果当作 API 切换的成功条件。状态页可在切换完成后独立刷新出口 IP。

## 平台接口边界

平台 adapter 增加两个固定 argv 的操作，供运行时注入和宿主测试。运行时先沿用现有核心选择校验得到 `xray_path`，平台层只接受已校验的 Xray 可执行路径：

- `xray_api_override(xray_path, balancer_tag, outbound_tag)`：只接受插件内部生成的 tag，使用固定 argv 调用 Xray API `bo`。
- `xray_api_balancer(xray_path, balancer_tag)`：调用 Xray API `bi`，限制输出大小，解析并返回当前选择的受限 tag。

平台层不得通过 shell 拼接命令，不得接受任意用户传入的路径、命令或原始 JSON。API 地址固定为 `127.0.0.1:10085`，超时有上限，失败统一返回可记录的稳定错误码。

## LuCI 行为

节点页保留现有“切换”按钮作为安全切换，增加独立的“快速切换”按钮。快速按钮：

- POST 到独立 action；请求返回后立即根据响应刷新 active 状态。
- 只显示短暂的“快速切换中”，不复用当前等待重启和健康检查的长轮询状态。
- 成功显示“已快速切换”，失败显示“快速切换失败”，并重新读取 status，避免页面把未完成操作永久显示为“切换中”。
- 在当前节点、已有操作锁或目标无效时禁用。

安全切换原有异步轮询行为不变。健康检查、测速和快速切换相互独立：测速/真实连接检查可以验证节点，不能阻塞 API 选择；快速切换成功也不宣称出口 IP 或目标网站访问已经验证。

## 错误处理与可观测性

新增稳定错误码至少覆盖：

- `fast_switch_unavailable`：动态配置、服务或 API 不可用；
- `fast_switch_target_invalid`：目标不存在、禁用或不在 balancer；
- `fast_switch_api_failed`：`bo` 或 `bi` 调用失败；
- `fast_switch_not_applied`：API 返回的当前选择不是目标；
- `fast_switch_commit_failed`：UCI 持久化失败；
- `fast_switch_recovery_required`：切换后无法恢复旧选择或启动恢复失败。

事件日志只记录操作类型、内部 section ID、结果、错误码和耗时。禁止记录 UUID、密码、私钥、token、raw outbound、完整 API 响应和分享链接。

## 测试设计

先写失败测试并观察其因缺少动态行为而失败，再实现最小代码。测试覆盖：

1. generator 为动态配置生成稳定节点 tags、balancer、API loopback 入站和 balancer routing；安全模式输出保持原结构。
2. routing 可以把代理目标抽象为 outbound tag 或 balancer tag，并保持 DNS、私网、直连和拦截规则语义不变。
3. platform 只发出固定安全 argv，拒绝非法 tag，正确处理 API 成功、失败、超时、超长/畸形 `bi` 输出。
4. runtime 快速切换按 `bo → bi → UCI commit` 顺序执行，成功不调用 restart、listener_ready、real_connection_check；各失败点保持旧状态，提交失败执行旧 tag 回滚。
5. runtime 启动恢复能够从持久 `active_node` 恢复 balancer，无法恢复时返回可展示的错误状态。
6. controller 只把已确认的快速切换结果返回给前端，UI 在成功、失败和重复点击场景都能结束“切换中”状态并刷新 active 节点。
7. 运行现有完整宿主测试、包检查和翻译检查；构建 r19 IPK 后在目标设备做真实 API、重启恢复和节点切换验证。

## 设备验收标准

在 `192.168.6.1` 上安装构建包并备份现有配置后，必须确认：

- Xray 配置检查通过，API 仅能从 loopback 访问；
- Xray 进程 PID 在快速切换前后不变，SOCKS/HTTP 监听不重启；
- `bo` 后 `bi` 返回目标 balancer 选择，节点页 active 状态刷新；
- 快速切换不等待健康检查，且出口 IP 可单独通过状态接口重新观察；
- Xray/设备重启后 active node 与 balancer 选择恢复；
- API 故障和 UCI 提交故障不会破坏旧选择，安全切换仍可完成；
- 宿主测试和设备 smoke test 均通过后，才提交并推送 `fast_select_api` 分支。
