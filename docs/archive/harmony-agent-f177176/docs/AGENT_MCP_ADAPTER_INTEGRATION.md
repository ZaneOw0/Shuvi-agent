> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_MCP_ADAPTER_INTEGRATION.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# harmony_agent MCP Agent Adapter 集成说明

`@harmony_agent/agent-connectors` 是无页面 HAR。它把现有 `@harmony_agent/mcp-client` 的 Server Profile、Tool 和调用结果映射到 Agent 公共 Tool 契约，不提供任务提交、确认、记录或界面接口。任务控制仍只通过 `AgentRuntimeFacade`。

## 装配边界

宿主按以下顺序连接：

1. 创建一个 `ConnectorDigestPort`。生产实现必须返回稳定的密码学摘要；测试可以注入确定性 fixture。
2. 用同一个 digest port 创建 `McpInvocationPolicyBridge`。
3. 创建 `McpClientManager` 时把该 bridge 作为 `McpManagerOptions.invocationPolicy`；不要为 Agent MCP 调用注册允许全部请求的 policy。
4. 用 `McpClientManagerToolPort` 包装 manager。Adapter 每个 invocation 只调用一次 `callTool`，不在该层重试。
5. 向 `McpProviderRegistry` 注册实际交给 manager 的 Server Profile 和受控版本。Profile 的 endpoint、协议或超时配置变化会生成新的 profile digest。
6. 向 `McpReadOnlyToolPolicyRegistry` 注册明确允许的只读工具。远端 annotations 不决定 risk、side effect、权限或数据边界；未进入本地 allowlist 的工具不会进入 Agent Tool Registry。
7. 注入 `McpGrantVerifierPort`。它必须校验完整 `ToolInvocation` 与 M02 grant 的 task、step、operation、tool identity、schema 和 arguments 绑定。由于 `RuntimeCoordinator` 已在 dispatch 前消费一次 grant，同一 invocation 的 `IDEMPOTENT_REPLAY` 可以作为允许结果；不同 invocation 的复用必须拒绝。没有 verifier 的默认放行实现。
8. 创建一个空 `agent_runtime.ToolRegistry`，并让注入的 Planner 与 Tool Preparer 共享它。调用 `createMcpProductionAgentRuntime`；需要启动恢复时调用 `createRecoveredMcpProductionAgentRuntime`。工厂会先运行 catalog discovery，在临时 Registry 完整校验后才填充共享 Registry，并强制使用 `SingleAgentCollaborationSelector`。
9. 工厂在内部把 `McpStepDispatchAdapter` 连接到 Production Runtime 的私有 completion sink，最终只返回 `AgentRuntimeFacade`。宿主不能传入第二个 AdapterFactory；部分 Server discovery 失败、空受控目录、非空目标 Registry 或非法 entry 都会在 Facade 暴露前 fail-closed。

Provider/Profile 或 schema 变化会改变 `registryVersion` 和 Registry snapshot；旧 grant 携带的 identity/schema 会在调用前失败。当前生产组合要求每次创建 Facade 使用新的空 Registry；运行中 catalog 刷新与 Router cache 原子替换仍需后续生命周期设计，宿主不能直接调用 `refreshCatalog()` 绕过组合门。

真实网络宿主需要在自己的 HAP `module.json5` 中声明 `ohos.permission.INTERNET`；HAR 本身不拥有宿主权限或 Ability 生命周期。

Shuvi `web_search` 的固定 Profile、只读 allowlist、成功结果校验、会话恢复、单次调用取消和设备地址约束见
[`SHUVI_WEB_SEARCH_MCP_INTEGRATION.md`](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/docs/SHUVI_WEB_SEARCH_MCP_INTEGRATION.md)。

## 调用与失败语义

- MCP 身份始终包含 `{serverId, kind, name}`，Tool ID 形如 `mcp://<serverId>/tool/<name>`。
- schema 使用规范 JSON 后计算组合 digest；tool identity 还绑定 profile digest。
- 参数会重新规范化并核对授权时的 arguments digest，随后校验 M02 grant，再签发一次性 MCP policy ticket。
- MCP policy ticket 只允许一次匹配的 Server、Tool 和参数调用；未装配 ticket 时 manager fail-closed。
- Adapter 不重试工具调用。查询、目录缓存和查询重试继续由现有 MCP client 管理。
- 当前 M06 registry 仅接收受控只读工具，强制 `SideEffect.NONE`。写工具及断线后的未知结果/对账留给对应后续任务，不得用只读 policy 绕过。
- MCP `NETWORK`、`TIMEOUT`、`AUTHENTICATION`、`FORBIDDEN`、`POLICY_DENIED`、`CANCELLED` 和配置错误会映射到 Agent error taxonomy。

## 验收边界

M06 的 HAR 构建和 adapter contract test 证明纯映射、授权桥、一次调用和 M03 dispatch port 接线。T29 主机组合测试进一步证明 catalog 先绑定、Single Agent Facade、授权决定、一次 MCP dispatch、异步 completion 和恢复型 Facade 装配。T30 的 API 26 证据另行证明设备经真实 `McpClientManager` HTTP transport 与 HDC 反向转发完成受控只读 Facade 任务；各层结论按对应证据分别判断。

T30 的 `test_host` 无页面套件 `McpFacadeDevice` 用于真实设备网络闭环。运行 `tools/test-mcp-facade-device.ps1` 时必须显式提供当前源码构建的主/ohosTest HAP 和 `-AllowDeviceChanges`；脚本只执行该 class，并要求 fixture Tool 计数精确增加 1。2026-10-14 的 API 26 运行保存了主/ohosTest HAP 安装、`McpFacadeDevice` 1/1、反向转发、fixture 和最终卸载清理证据，关闭了 T30/S2 受控只读闭环；证据位于 `artifacts/t30-s2-mcp-facade-device/20261014-132524/`。本轮使用 unsigned 测试包、确定性 Planner/persistence/digest/grant fixture 和本机 MCP fixture，因此发布签名、生产 Planner/credential store 及第三方远端 MCP 兼容性不在该结论内。
