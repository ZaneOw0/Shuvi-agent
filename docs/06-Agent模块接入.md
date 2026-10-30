# 06 Agent 模块接入

本文描述当前应用宿主装配，来源与本地扩展见 [整合与维护](07-仓库整合与文档迁移方案.md)。具体版本测试见 [验收目录](verification/README.md)。

## 1. 模块与入口

Agent 源码位于 `modules/harmony_agent/`，八个 HAR 的职责见 [模块说明](architecture/Agent模块与职责.md)。产品使用公共出口；唯一任务控制入口为 AgentRuntimeFacade，页面通过应用服务消费状态。

| 应用落点 | 职责 |
|---|---|
| EntryAbility / Index | 生命周期、导航、页面与依赖装配 |
| RuntimeAssistantCoordinator | 主助手、搜索和知识库工具组合与授权 |
| RuntimeChatService / DeepSeekToolTransport | 会话发送、模型 tool_calls 与结果回填 |
| KnowledgeAgentRuntime / ModelKnowledgeTools | 知识库 Registry 工具、查询与引用校验 |
| RuntimeSearchSession | Tavily 搜索授权、Runtime 派发与网页来源 |
| 日历与文档应用适配 | 用户确认后的日历写入、文档版本与 Download 发布 |

## 2. 模型与工具

设备直接连接 DeepSeek，工具循环可选择普通回答、文档工具、日程提议，以及用户已授权的搜索和知识库工具。搜索直连 Tavily，不需要电脑搜索服务。Windows 网关保留为独立子项目。

Runtime 在每次操作前处理 Registry 身份、参数、授权、预算、持久化派发与结果记录。模型建议与真实执行状态分别保存；结果未知时按工具核查规则处理。

## 3. 资源生命周期与存储

宿主注入凭据、执行库、记忆、平台资源和时钟，负责资源打开、失败清理、取消和关闭。后台停止活动调用，前台不自动恢复旧派发。

普通对话记忆、知识库内容、搜索执行库、日历账本和文档版本各自持久化。知识库派生上下文只在当前授权会话使用；来源 UI 快照只恢复显示。

## 4. 调试与验证

MCP 连接探针验证握手/目录，Runtime 启动检查验证装配；两者独立于产品模型和工具成功。独立 Agent 测试宿主不进入 HAP，设备测试需按其文档准备环境。

- [接入边界](integration/agent/接入与边界.md)
- [普通对话契约](../specs/07-Runtime普通对话接入.md)
- [独立测试宿主](../tests/agent-host/README.md)
- [宿主迁移记录](verification/agent/测试宿主迁移.md)、[主对话集成验证](verification/PR26-main合入与RAG三链路回归.md)

正式发布、目标 OpenHarmony、完整恢复/权限矩阵与供应商账单仍需独立验收。
