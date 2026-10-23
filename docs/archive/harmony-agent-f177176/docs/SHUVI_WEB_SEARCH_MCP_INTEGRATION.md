> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/SHUVI_WEB_SEARCH_MCP_INTEGRATION.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Shuvi 联网搜索 MCP 后端接入

本接入固定服务端契约 `shuvi-search-mcp/0.1.0`、Server ID `shuvi-web-search` 和工具名
`web_search`。代码位于 `agent_connectors/.../ShuviWebSearch.ets`；产品页面不在本仓库范围内。

## 组合顺序

1. 用同一 `ConnectorDigestPort` 创建 `McpInvocationPolicyBridge`、`McpProviderRegistry` 与
   `McpReadOnlyToolPolicyRegistry`。
2. 创建 `McpClientManager`，把 bridge 注入 `invocationPolicy`。没有匹配的一次性 Runtime
   授权票据时，工具调用继续 fail-closed。
3. 调用 `connectShuviWebSearchMcp(...)`。该函数注册固定 Legacy Profile、连接服务、发现目录，
   并只允许 `shuvi-web-search/web_search` 进入本地只读 allowlist。
4. 用 `ShuviWebSearchMcpClientToolPort` 包装 `McpClientManagerToolPort` 后再创建
   `McpAgentAdapter`。包装层在发出请求前校验 `query/maxResults`，成功后严格校验
   `structuredContent`、来源 URL 和等价 JSON 文本；错误结果仍由 Adapter 的结构化错误映射处理。
5. 按 `AGENT_MCP_ADAPTER_INTEGRATION.md` 创建生产 `AgentRuntimeFacade`。联网开关只控制工具资格；
   用户授权仍由 Runtime Policy Gateway、grant verifier 和一次性 MCP ticket 完成。

```text
McpClientManager(invocationPolicy = bridge)
  -> connectShuviWebSearchMcp(manager, providers, policies, config)
  -> ShuviWebSearchMcpClientToolPort(McpClientManagerToolPort(manager))
  -> McpAgentAdapter
  -> createMcpProductionAgentRuntime / provider composition
```

固定策略为 `RiskLevel.LOW`、`SideEffect.NONE`、`DataBoundary.REMOTE_ALLOWED`，能力标签为
`web-search/public-web/read-only`，权限要求为产品策略标识 `network.search.public`。这不替代宿主 HAP
中的 `ohos.permission.INTERNET`。

## 会话和取消

- Profile 固定 `McpProtocolMode.LEGACY`，与服务端已经验证的 `2025-11-25` 协商路径一致。
- 只为这个显式只读 Profile 启用 `retryToolCallOnExpiredSession`。收到会话过期 HTTP 404 时，客户端
  清除旧会话、重新 initialize，并只重发原调用一次；其他 Tool/Profile 默认不启用。
- `cancelTask` 会按 `dispatchId -> invocationId -> McpCancellationSource` 只取消对应 HTTP 请求，
  不再通过关闭整个 transport 影响并发调用。服务端 SDK 的 request signal 随 HTTP 断开传播到 Tavily fetch。
- disconnect 仍发送带 Session ID 的 DELETE；服务端 120 秒空闲回收不需要产品侧定时保活。

## 地址和认证

当前服务只监听电脑 `127.0.0.1:8787` 并校验 Host。设备调试使用 HDC reverse：

```powershell
hdc rport tcp:8787 tcp:8787
```

设备 Profile 仍使用 `http://127.0.0.1:8787/mcp`，并且仅在 debug build 中设置
`allowInsecureHttp=true`。设备端口必须保持 8787，否则转发后的 Host 头会被服务端拒绝。

这一模式不开放局域网端口，因此开发阶段不额外加入应用层 token；它只适用于单机受控联调。本机其他进程
仍可访问服务，不能把它当作多用户认证。

正式远端部署必须由服务端另行提供 HTTPS 与认证入口。客户端已提供
`McpCredentialAuthProvider`，可把 `ProviderCredentialPort`/AssetStore 中按
`serverId + credentialScope` 读取的短期 Bearer 或 `x-api-key` 注入 MCP 请求；凭据不进入 Profile、任务、
日志或快照。Tavily API Key 始终只留在搜索服务端。

## 当前验证边界

- MCP Client 28/28：新增会话过期重握手和单次调用取消用例。
- Agent Connectors 72/72：新增 Profile/allowlist、参数、成功结果绑定和凭据注入用例。
- Agent Runtime 134/134：取消任务会命中对应 dispatch。
- Agent Storage 57/57、Native Tools 12/12 回归通过；test_host unsigned HAP 构建通过。
- 当前没有连接中的 HDC 设备，因此尚未执行真实设备到 `D:\\Shuvi-agent` 服务的网络验收，也没有再次调用
  Tavily。服务端已有的 Node 测试和真实搜索记录不能替代本次 ArkTS 设备验收。
