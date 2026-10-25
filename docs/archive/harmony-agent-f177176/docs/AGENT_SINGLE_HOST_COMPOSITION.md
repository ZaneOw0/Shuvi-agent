> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_SINGLE_HOST_COMPOSITION.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# 单 Agent 产品宿主组合接线

更新时间：2026-10-19

## 1. 目标

`agent_runtime` 提供宿主中立的 `createSingleAgentHostRuntime`，把第一版单 Agent 后端所需资源收敛到一个生命周期入口。该入口只返回 `AgentRuntimeFacade`，不会暴露 `RuntimeCoordinator`、Planner、Adapter 或其他任务控制接口。

本合同解决资源启动、失败回滚和关闭顺序问题。具体 HarmonyOS Ability、RDB、系统密钥、Provider 凭据和 MCP 网络对象仍由产品宿主创建并注入。

## 2. 固定启动顺序

宿主必须提供以下互不相同的资源实例：

1. `credentialStore`：凭据解析与轮换资源；
2. `executionStorage`：任务 checkpoint、authority 与 operation 的执行恢复存储；
3. `memoryStorage`：长期记忆与可重建索引存储；
4. `mcpClient`：MCP catalog、连接与调用资源；
5. `runtimeFactory`：在上述资源已经打开后创建唯一 `AgentRuntimeFacade`。

组合器严格按前四项顺序执行 `open()`。某一资源的 `open()` 抛出异常时，该资源和此前已经打开的资源都会按相反顺序执行 `close()`；此时不会调用 `runtimeFactory.create()`。

## 3. 关闭顺序

产品 Ability 结束时应对返回的 Facade 调用一次 `shutdown(mode)`。组合器先调用底层 Runtime 的 `shutdown`，然后按以下顺序释放资源：

1. MCP client；
2. memory storage；
3. execution storage；
4. credential store。

某一项关闭失败不会跳过剩余资源。全部释放尝试结束后，调用方收到稳定的 `HOST_SHUTDOWN_FAILED`。重复调用 shutdown 会复用第一次的 Promise，不会重复关闭资源。

## 4. Fail-closed 条件

以下情况会在打开任何资源前以 `INVALID_CONFIGURATION` 拒绝：

- composition version 不是 `1.0`；
- 任一资源或 Runtime factory 缺失；
- 两个资源端口引用同一实例。

资源打开失败返回 `RESOURCE_OPEN_FAILED`；若回滚本身失败，返回 `RESOURCE_ROLLBACK_FAILED`。Runtime factory 创建失败会先回滚全部资源，再返回 `RUNTIME_FACTORY_FAILED` 或回滚错误。底层异常文本不会进入这些稳定错误信息。

## 5. 产品宿主接线要求

产品 Ability 的 composition root 应完成以下工作：

- 使用系统安全存储实现 credential resource，不把凭据写入日志、checkpoint 或公共事件；
- 创建 execution RDB 与 memory RDB，并配置访问控制、加密和密钥轮换；
- 创建真实 MCP client 与允许列表，明确认证、超时和断网行为；
- 用已经打开的对象组装现有 Local AI Gateway、MCP、RDB recovery 与 memory context factories；
- 仅向页面或业务层保留组合器返回的 `AgentRuntimeFacade`；
- 在 Ability 销毁路径调用 shutdown，并记录不含密钥和正文的稳定错误码。

## 6. 已验证范围

2026-10-19 主机 Hypium 共 133/133 通过，其中新增 6 项组合器用例。Release HAR 构建成功，大小 240,587 bytes，SHA-256 为 `F55724AD0AA37D21B19BE21930BC91F69BA425AAEBCCE8D35BD1A739BFED56D5`。

本轮没有构建 HAP、没有签名、没有安装或运行设备，也没有创建真实 RDB、读取生产凭据或连接第三方 MCP。上述外部能力必须在产品宿主接线后单独验收。
