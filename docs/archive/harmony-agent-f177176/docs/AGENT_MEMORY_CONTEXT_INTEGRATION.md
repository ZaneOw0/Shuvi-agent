> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_MEMORY_CONTEXT_INTEGRATION.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Agent 长期记忆上下文接入

更新时间：2026-10-19

## 1. 目标与边界

本接线把 M05-B 已有的长期记忆检索能力接入 Provider Semantic Planner，同时保持 Runtime 不依赖具体数据库。它只负责读取经过约束的上下文，不会自动保存聊天、模型输出或工具结果。

依赖方向固定为：

```text
agent_runtime PlanningMemoryContextPort
        ↑
agent_storage RuntimeMemoryContextAdapter
        ↑
DeterministicMemoryStore / DurableMemoryStore 的 RebuildableMemoryIndexPort

agent_connectors ProviderSemanticPlanner → PlanningMemoryContextPort
```

## 2. 运行时合同

`PlanningMemoryContextRequest` 由 Planner 创建，必须绑定：

- 当前 `taskId`；
- `TaskEnvelope.userId` 作为 `ownerId`；
- 当前用户意图、任务目标、约束和能力分类组成的查询词；
- `maxItems` 和 `maxCharacters` 两个硬预算。

`PlanningMemoryContextResult` 必须回传相同的 `taskId`、`ownerId` 和合同版本。每个条目只包含 `memoryId`、`chunkId`、`memoryVersion`、正文和标签，不包含数据库对象、凭据或原始个人轨迹元数据。Planner 会再次校验身份、版本、条目数、字符数、重复 chunk 和字段有效性；任何异常都以 `PLANNER_MEMORY_CONTEXT_FAILED` 在 Provider 调用前拒绝。

## 3. 隐私与预算

`RuntimeMemoryContextAdapter` 固定使用以下查询策略，调用方不能放宽：

```text
includeSensitive = false
includeRawPersonalTrace = false
ownerId = TaskEnvelope.userId
```

Adapter 先限制条目数，再按确定顺序限制正文字符数，必要时只截取最后一个条目并标记 `truncated=true`。Planner 将实际注入的字符数以“一字符至少占一个输入 token”的保守方式加入输入预算和费用预检；Multi Agent 聚合预检使用配置的最大记忆字符数。

`maxPromptCharacters` 仍对加入记忆后的完整 prompt 生效。记忆正文不会写入 `ProviderPlannerTrace`，Observer 只能看到身份、usage 和结果状态。

## 4. 宿主接线

宿主先打开长期记忆存储并保证索引可用，再创建适配器：

```ts
const memoryContext: RuntimeMemoryContextAdapter =
  new RuntimeMemoryContextAdapter(memoryStore);

config.plannerConfig.maxMemoryItems = 4;
config.plannerConfig.maxMemoryCharacters = 2048;
ports.memoryContext = memoryContext;
```

`maxMemoryItems`、`maxMemoryCharacters` 和 `memoryContext` 必须同时启用或同时关闭。缺少任一项时 composition 在创建 Planner 时拒绝，不能静默降级为无记忆模式。

关闭顺序由宿主负责：先停止接受新任务并关闭 `AgentRuntimeFacade`，再关闭长期记忆 durable session 和 RDB。当前 port 是同步本地查询，不能在实现中发起网络请求或长耗时模型调用。

## 5. 已验证

- owner 隔离；
- 敏感记忆和原始个人轨迹默认排除；
- 条目数和字符数确定性截断；
- 删除记忆后不可召回；
- 记忆 port 抛异常、身份错绑和预算超限均在 Provider 前失败；
- 记忆正文进入 Planner prompt，但不进入 Planner trace；
- 新建与恢复型 Local AI Gateway + MCP composition 均可注入同一 port。

## 6. 未完成的外部门

本接线不证明宿主 RDB 已加密，也不提供密钥生成、轮换、备份或错误 key 恢复。它没有运行签名 HAP、设备测试或真实 Provider 请求。产品宿主还必须完成 T64-B 加密验收，才能把长期记忆称为生产可用。
