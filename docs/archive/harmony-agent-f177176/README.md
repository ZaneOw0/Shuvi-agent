> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `README.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# harmony_agent Agent Runtime（ArkTS）

这是无 UI 的 harmony_agent Agent Runtime 与其 HarmonyOS/OpenHarmony ArkTS 基础模块，不是示例应用，也不包含产品前端。

harmony_agent Agent Runtime 的分层、数据契约、安全边界、算法落点和实施门见 [docs/architecture/HARMONY_AGENT_ARCHITECTURE.md](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/docs/architecture/HARMONY_AGENT_ARCHITECTURE.md)；可独立开发和验收的 M00–M15 模块见 [docs/architecture/HARMONY_AGENT_DEVELOPMENT_MODULES.md](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/docs/architecture/HARMONY_AGENT_DEVELOPMENT_MODULES.md)。T01–T48、T50–T52 已关闭各自记录的任务门，M10 已完成 TestKit、S6 fixture baseline、真实证据封存和执行准入封顶；T43 已完成真实 12×2 Provider/system Bench 基线，T50–T52 已完成 MasRouter 来源冻结、环境输入合同和 adaptation handoff 结构门，当前证据边界以 [PROJECT_STATUS.md](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/PROJECT_STATUS.md) 为准。

当前工程交付包括：

- `agent_contracts/`：harmony_agent Agent Runtime 的版本化纯 ArkTS 契约 HAR；不依赖网络、存储、UI 或具体 Provider。
- `agent_core/`：确定性 Workflow Kernel HAR；提供语义图校验、状态机、调度、恢复边界和 operation journal。
- `agent_runtime/`：无 UI 的 Agent Runtime HAR；提供唯一 `AgentRuntimeFacade` 业务控制接口、明确标记的 headless fake/consumer、M03 编排、M04 Registry/Router、Policy Gateway，以及生产 persistence/recovery composition ports。
- `agent_storage/`：无 UI 的执行恢复与长期记忆存储 HAR；提供 durable recovery、RDB backend、Runtime bridge、active operation 保守恢复和长期记忆索引。T26 已完成 API 26 跨进程恢复验收。
- `agent_connectors/`：MCP、Model、Embedding 与 Remote API 的 Adapter HAR；包含 Local AI Gateway 的 OpenAI-compatible Model transport，现有结论为主机协议/fixture gate。
- `native_tools/`：HarmonyOS/OpenHarmony Kit Adapter HAR；首个只读 battery slice 已完成签名 API 26 设备验收。
- `agent_testkit/`：M10 的确定性故障注入、共用集成 fixtures、benchmark manifest 与指标评估 HAR；不提供任务控制入口。
- `offline/harmony_agent_bench/`：冻结的十二类任务、32/128/512 工具规模 fixture、价格快照和可重复离线报告；不进入端侧 Runtime。
- `mcp_client/`：可复用的 `@harmony_agent/mcp-client` HAR。
- `test_host/`：仅承载设备集成测试的无页面、未导出 Ability；不进入 harmony_agent 产品代码。
- `tools/test-mcp.ps1`：唯一人工验收入口，配套 Node.js Fixture Server。

## Agent 接入

HAR 的公共入口是 `mcp_client/Index.ets`。宿主负责 Server Profile、认证秘密和每次工具调用的授权策略；HAR 不持久化这些数据。

```typescript
import {
  McpCapabilityKind,
  McpClientManager,
  McpInvocationPolicy,
  McpProtocolMode
} from '@harmony_agent/mcp-client';

const manager = new McpClientManager({
  debugBuild: false,
  authProvider: harmonyAgentAuthProvider,
  invocationPolicy: harmonyAgentInvocationPolicy as McpInvocationPolicy
});

manager.registerServer({
  id: 'knowledge',
  displayName: 'Knowledge MCP',
  endpoint: 'https://mcp.example.com/mcp',
  protocolMode: McpProtocolMode.AUTO
});

await manager.connect('knowledge');
const tools = await manager.listTools();
const result = await manager.callTool({
  serverId: 'knowledge',
  kind: McpCapabilityKind.TOOL,
  name: 'search'
}, { query: 'OpenHarmony' });
```

`McpCapabilityRef` 使用 `{ serverId, kind, name }` 定位能力，因此不同 Server 可以安全地暴露同名工具。未注册策略、策略拒绝或策略异常时，`tools/call` 默认拒绝。

## 支持范围

- Streamable HTTP，JSON 与 SSE 响应。
- 现代协议 `2026-07-28`，以及旧式 `2025-11-25`。
- `auto` 只在明确的不支持信号上回退；认证、5xx、网络和超时错误不回退。
- 多 Server、Tools、Resources、Resource Templates、Prompts、分页和目录缓存。
- 文本、图片、音频、资源链接、嵌入资源、结构化内容及未知扩展块。
- 网络、认证、协商、JSON-RPC、策略拒绝、超时、取消和响应过大错误。

不支持 stdio、OAuth UI、持久化令牌、Tasks、Sampling、Elicitation、Roots、Logging 或持续资源订阅。HarmonyOS 本地 Kits 继续由 harmony_agent 的本地工具适配层调用。

## 验收

在项目根目录运行：

```powershell
.\tools\test-mcp.ps1
```

可选参数：

```text
-Device Auto|Required|Skip       默认 Auto
-Protocol Modern|Legacy|Both    默认 Both
-HdcPath <path>
-AdvertiseHost <host>
-InstallDependencies
-KeepTestApp
```

脚本不会自动启动模拟器、修改防火墙或更改永久环境配置。只有显式传入 `-InstallDependencies` 才允许 OHPM 联网安装。没有设备时，`Auto` 完成主机侧验收并将设备阶段标记为 `SKIPPED`；`Required` 则失败。

报告和交付物写入被版本控制忽略的 `artifacts/test-results/<runId>/`。退出码 `0` 表示所有必需阶段通过，`1` 表示测试失败，`2` 表示必需工具或配置缺失。

协议实现选择与兼容探针见 [docs/PROTOCOL_IMPLEMENTATION.md](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/docs/PROTOCOL_IMPLEMENTATION.md)，逐项验证边界见 [docs/TEST_MATRIX.md](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/docs/TEST_MATRIX.md)，本机影响及清理边界见 [docs/ENVIRONMENT_IMPACT.md](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/docs/ENVIRONMENT_IMPACT.md)。
