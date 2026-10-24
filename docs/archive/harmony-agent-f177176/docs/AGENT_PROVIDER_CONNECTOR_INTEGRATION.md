> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_PROVIDER_CONNECTOR_INTEGRATION.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Provider Connector 集成说明

`@harmony_agent/agent-connectors` 0.6.0 在同一 HAR 中提供 M06 MCP adapter、M07 LLM/Remote API connector、Local AI Gateway transport、Provider Semantic Planner，以及通用和 Local AI Gateway 具体 production composition。它是 `agent_runtime` 的可注入依赖，不是新的任务控制入口；外部产品仍只通过 `AgentRuntimeFacade` 提交和控制任务。网关装配见 [LOCAL_AI_GATEWAY_INTEGRATION.md](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/docs/LOCAL_AI_GATEWAY_INTEGRATION.md)。

## 组合边界

宿主或后续 M09-B composition root 负责提供：

- `ProviderCredentialPort`：按 `providerId + credentialScope` 从受保护存储解析短期凭据；产品宿主可使用本 HAR 提供的 `AssetStoreProviderCredentialPort`，或注入满足同一契约的实现；
- `ModelTransportPort`、`EmbeddingTransportPort`、`RemoteApiTransportPort`：实现具体 Provider 的 HTTP/SDK 映射和底层网络取消；
- `ProviderTimerPort`：生产环境可使用 `SystemProviderTimer`，测试可注入确定性计时器；
- `ProviderGrantVerifierPort`：把 Remote API `ToolInvocation` 重新绑定到 M02 已签发且仍有效的内部 grant；
- `ConnectorDigestPort` 与 `ConnectorClockPort`：沿用 Runtime 的摘要和时钟实现。

Provider 专用 model ID 只保存在 `ModelProviderProfile.providerModelId`，调用 Runtime 使用稳定的 `registryModelId`。`ProviderCatalog` 绑定 provider、capability version、region 和 `ProviderPriceSnapshot`，返回隔离副本，避免注册后的输入对象或调用方修改当前快照。

## 调用与追溯

模型和 Embedding 请求必须携带选路时冻结的 model version、region 与 price snapshot ID。成功结果返回同一组 trace 字段和 `ProviderUsage`；connector 使用冻结价格计算 `settledCostMicros`，同时保留 Provider 报告的成本。

Remote API 返回 `RemoteApiProviderResult`。其中 `outcome` 是通用 `ToolOutcome`，外层同时记录 provider、capability version、region、price snapshot 和 usage。参数 JSON 在调用前规范化并核对摘要，随后验证 grant；任一步骤失败都会在解析凭据和启动网络前关闭。

## 凭据与资源生命周期

普通 invocation、workflow、stream chunk、结果和错误不包含认证 header。`ProviderOperationRunner` 只在输入和取消预检通过后调用 `ProviderCredentialPort`，再把凭据直接交给 transport。transport 不应把凭据复制到请求 DTO、日志、trace 或 provider receipt。

API 26 产品宿主可使用 `AssetStoreProviderCredentialPort` 与 `HarmonyAssetSecretQueryPort`。绑定表显式固定 provider、scope、Asset alias 与 Bearer/`x-api-key` 二选一；重复绑定、共享 alias 和未知 scope fail-closed。适配器只查询，不写入、缓存或轮换 secret；查询异常与畸形 secret 统一脱敏，临时字节在组装调用期 header 后清零。具体写入、轮换与设备验收见 [Agent AssetStore credential store 接入](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/docs/AGENT_ASSET_CREDENTIAL_STORE.md)。

取消或 timeout 会调用当前 `ProviderOperationHandle.cancel()`，取消计时器并解除取消订阅。transport 的 `cancel()` 必须关闭或中止实际 HTTP/SDK 资源。对于已经启动且带副作用的 Remote API，网络中断、取消或 timeout 返回 `UNKNOWN_OUTCOME`；connector 不自动重试，后续由恢复与对账流程处理。

## Semantic Planner 适配

`createProviderMcpProductionAgentRuntime` 与恢复型工厂接收一个已注册的 `RegisteredModelProvider`、匹配的 `ModelProvider` 和 Planner 配置，并使用 `ProductionAgentRuntimePorts` 中同一组 Runtime 时钟与 ID 生成器构造 `ProviderSemanticPlanner`。调用方不得预置另一 Planner；缺 clock 或 ID 时会在 MCP 目录发现前失败。构造完成后仍复用既有 catalog-before-Facade 边界，外部只获得唯一 `AgentRuntimeFacade`。

Provider 只能返回受约束的 JSON 草图。Adapter 会重新生成 workflow/clarification 的可信 task、workflow、version、时间和 ID 字段，随后检查步骤字段、JSON schema、依赖与 entry、DAG、binding、Tool capability，以及副作用与幂等关系。ready、clarificationRequired 与 rejected 的 payload 必须互斥；身份/usage 不一致、非 `stop` 结束、额外字段或非法图都返回稳定拒绝码。输入/输出 token 和金额按任务预算严格比较，0 表示没有可用额度。Provider Promise 异常保留为异常边界，由 T32 Runtime 统一闭合为脱敏的 `plannerInvocationFailed`。

可选 observer 只接收 phase、task ID、Provider request ID、Provider/model/version/region/price、finish reason、planning status、稳定拒绝码和 usage。它不接收 prompt、模型输出、凭据或用户回答；observer 异常不能影响规划结果。

## 当前验收边界

M07 的 15 项 contract test、Local AI Gateway transport 5 项、T33 Planner 6 项、T34 通用 composition 3 项、T35 网关具体 composition 3 项和 T37 协作选择 composition 2 项，与 M06/M09-B MCP 用例合并运行时为 52/52。T37 的 Release HAR 为 58,288 bytes、SHA-256 `BAFCEE611C9349B570E30B6FF57BA365AA59E77953B57D15BF5EDEC26F5F7073`，包内版本 0.7.0、`debug=false`。

T37 要求通用与 Local AI Gateway 工厂保留宿主显式提供的 `CollaborationSelectorPort`，仅在缺失时使用 Strong Single fallback。Multi 选择仍由 Runtime 激活预算约束；预算不足时在 planner、credential、Provider 网络和 MCP 前失败，且终态恢复检查点保持有效。该接线不提供角色拓扑或第二任务控制入口。

这些历史主机门本身不证明真实 Provider Planner 请求、真实 Asset 预置/轮换、真实取消/timeout、HAP/设备行为或 S6 system run。T36 已另行取得 signed API 26 的单任务系统证据：真实 Provider Planner 生成一个 Tool workflow，经唯一 `AgentRuntimeFacade` 等待显式授权后调用一次 MCP `echo` 并完成；该证据不替代产品宿主凭据治理、真实取消/timeout、第三方远端 MCP 或 12×2 S6 Bench。

P0-C 又新增 5 项 AssetStore credential resolver 主机用例，当前合并 Connector 套件为 65/65。Release HAR 为 67,249 bytes、SHA-256 `176DE3443BB09836D6B6B2433237127599E17441CD11F7061A1D72622C5F9F5E`。该门证明 API 26 类型、allowlist/脱敏/清零逻辑与打包，不替代真实 Asset 写入、轮换、锁屏策略或签名设备查询。
