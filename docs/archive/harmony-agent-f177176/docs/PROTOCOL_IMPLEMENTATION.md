> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/PROTOCOL_IMPLEMENTATION.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# 协议实现选择

最终采用自有 ArkTS 协议实现，底层使用 `@ohos.net.http`，没有在 HAR 中封装官方 TypeScript SDK。

## 兼容探针结论

已检查 `@modelcontextprotocol/client@2.0.0` 的发布元数据。该包要求 Node.js `>=20`，依赖链包含 `cross-spawn` 等 Node 运行时组件，不满足本项目对 HarmonyOS API 26 HAR 的门槛：不得引入 Node、stdio、`process` 或 Node `Buffer` 垫片。因此探针在依赖审查阶段被拒绝，没有把该包安装进工程。

Release HAR 验收会同时执行：

1. 解包 HAR，检查是否包含 `node_modules`、`cross-spawn`、stdio、process 或 buffer 运行时条目。
2. 扫描 HAR 主源码，检查 Node 模块导入和 Node 专用全局引用。

## 内部结构

- `McpClientManager`：多 Server 生命周期、能力聚合、目录缓存与默认拒绝策略。
- `McpProtocolClient`：现代/旧式协商、分页、调用语义和内容保真。
- `ArkTsHttpTransport`：HarmonyOS HTTP、超时、取消、响应大小限制和错误分类。
- `JsonRpcCodec` / `SseParser`：JSON-RPC 2.0 与 SSE 编解码。

协议模式：

- `MODERN`：直接执行 `server/discover`，要求服务端声明 `2026-07-28`。
- `LEGACY`：执行 `initialize` / `notifications/initialized`，要求协商 `2025-11-25`。
- `AUTO`：先尝试现代发现，只在 400/404、JSON-RPC method-not-found 或明确的协议不支持响应上回退。

401、403、5xx、网络故障、超时和畸形现代响应不会触发旧协议回退。`tools/call` 从不自动重试；安全目录查询只在没有收到 HTTP 响应的网络或超时错误上重试一次，已经收到的 5xx 不重试。

## 安全边界

- Release 仅允许 HTTPS。
- Debug 只有在 Profile 显式设置 `allowInsecureHttp: true` 时允许 HTTP。
- 认证由宿主异步提供，保留字段不能被认证 Provider 覆盖。
- 日志和报告中的 Authorization/Bearer 值会被脱敏。
- 工具调用在策略回调明确允许前不会发送。
