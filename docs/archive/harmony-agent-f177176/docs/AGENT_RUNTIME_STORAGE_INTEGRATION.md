> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_RUNTIME_STORAGE_INTEGRATION.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Agent Runtime 与执行恢复存储集成边界

本文说明 `@harmony_agent/agent-runtime` 0.15.0 的 M09-B 异步生产组合端口如何与 `@harmony_agent/agent-storage` 0.8.0 的 M05-A 执行恢复存储对齐。T25 已接入 active operation 的原子恢复归一化；T26 新增具体 RDB composition 与两阶段设备 fixture；T32 将 Semantic Planner 的 plan/resume/replan 纳入同一 Promise/FIFO 生命周期；T39 在不改变 checkpoint 1.1 的前提下加入可选的版本化协作计划恢复状态。本文同时记录其验证范围。

## 1. 控制入口与生命周期

外部宿主仍只通过 `AgentRuntimeFacade` 提交和控制任务。`ProductionRuntimePersistencePort` 只保存 Runtime 已产生的状态与操作记录，不能创建任务、推进协调器或签发授权。数据库打开、加密配置、备份、关闭和 Ability 生命周期均由外部宿主负责；任何页面或 `Context` 都不传入 Runtime HAR。

## 2. 任务恢复检查点

`RuntimeTaskRecoveryCheckpoint` 1.1 是一个协调器任务的版本化恢复状态。它把原始 `TaskSubmission`、公开 `AgentTaskSnapshot` 与 TaskEnvelope、TaskFrame、handle、事件序列、规划请求、workflow、scheduler snapshot、使用量、等待中的澄清/策略/调用、在途 invocation、dispatch/operation ID、Provider 注册和暂停状态放在同一个保存单元。原始 submission 保留 `submittedAt` 和完整提交语义，用于重建 requestId 的精确去重。生产持久化端口通过 `saveCheckpoint`/`loadCheckpoint` 原子保存和读取该单元，不能再只保存公开摘要后宣称可恢复活动任务。旧 1.0 格式缺少该字段，当前版本明确 fail-closed，尚未提供迁移器。

检查点包含 `userIntent`、Tool `argumentsJson` 和短期授权引用，属于敏感内部恢复数据。宿主必须依据任务 privacy class 实施访问控制、静态加密、备份和删除策略；它不能进入公共 event、日志或产品展示。M05-A 的 operation、budget 和 policy durable record 仍是相应状态的权威来源，恢复时必须用稳定 ID 与检查点核对，不能仅信任检查点副本。

当前实现已捕获并按 snapshot version 交给生产持久化端口。每次 checkpoint 捕获同时生成绑定相同 task/snapshot version 的 `RuntimeDurableAuthorityPayload`。pending dispatch、operation 和 active invocation 会在任何 Adapter 调用前先保存；写前检查点失败时不调用 Adapter。`RuntimeCheckpointValidator` 在保存前以及 `loadCheckpoint` 回读后严格校验版本、submission normalization、公共契约、task/request/session 绑定、事件序列、workflow/scheduler、等待项、在途 invocation、使用量与 Provider ID。回读值还必须绑定调用方请求的 taskId；任何失败都会进入持久化故障并拒绝使用。

内部协调器现可从 1.1 检查点重建 Session 去重、事件、workflow 和 scheduler。重启时已在途的无副作用步骤回到待重试状态，带副作用步骤进入 `WAITING_RECONCILIATION`，旧 dispatch callback 不再有效。所有仍可能继续执行的恢复任务保持 authority lock，直到下节定义的 Policy/Budget authority 通过严格校验与 hydration。

## 3. 恢复权威图与解锁门

`RuntimeRecoveryAuthority` 1.0 是 storage-neutral 数据图。宿主只能在同一次 durable read/lease 范围内组装它，必须提供原 checkpoint 的 taskId 与 snapshot version、正数 storage revision、当前 policy version、完整 task/step/provider budget scopes 以及该任务全部 reservation。等待授权状态还需要相同的 version 1 policy request；在途 Tool 需要 version 3 decision/grant、operation 及同一 reservation。operation 必须保留 policy request、幂等模式与副作用分类，不能从 Tool 默认值推断。

`RuntimeRecoveryAuthorityValidator` 先在隔离的 Budget Ledger 中验证 scope 集合、limit、reservation 引用和 consumed/reserved 聚合，再验证 Policy/Grant/Invocation/Operation 的稳定 ID、identity/schema/arguments digest、fencing/dispatch 与 budget state。任何缺失、额外记录或漂移都会 fail-closed。内部协调器保存恢复前检查点作为一次性锚点；validator 与实际 ledger hydration 均成功后才删除锚点并解除锁。失败不会部分写入预算总账，也不会调用 Adapter。

这套 DTO、validator 与内部 hydration 已通过本地主机测试。写入侧的 `RuntimeDurableAuthorityPayload` 没有 storage revision；revision 只能由宿主完成 CAS 后分配。等待授权状态提供 version 1 request，dispatch 准备状态提供 version 3 decision/grant、预算预留与 `PREPARED` operation。Runtime 不掌握持久化端分配的 fencing token、dispatch count 或最终费用，所以普通 checkpoint 写入不能重建或回退 operation；outcome/reconciliation 方法拥有后续状态。M05-A schema 1.2 已持久化完整 budget scope 总账、operation 绑定以及 Runtime 产生的版本化 opaque checkpoint，并可枚举任务、按 taskId 返回全部 scope 和 reservation。`RuntimeExecutionRecoveryBridge` 把 checkpoint、Policy、预算、operation 和 lease/fencing 变更放入隔离副本，以一次 backend CAS 发布；CAS 失败时全都不可见。

`ProductionRuntimeRecoverySourcePort` 仍是只读启动边界：bridge 确定性枚举 taskId，从 durable task、Policy、budget 和 operation 记录组装 `RuntimeRecoveryAuthority`，并在返回前运行完整 validator。`createRecoveredProductionAgentRuntime` 在任何 Facade 引用交给宿主前，按 taskId 读取并校验 checkpoint、登记 durable snapshot version、恢复 Coordinator、hydrate authority、顺序保存 hydration 事件；随后订阅可从 checkpoint 内事件序列回放，并重新交付 pending Policy/Clarification。

T25 遇到 active invocation/pending dispatch 时先读取与原 checkpoint 绑定的 authority，再让协调器生成 `WAITING_RECONCILIATION` checkpoint。`ProductionRuntimePersistencePort.normalizeRecoveredOperation` 随后成为专用 durable 门：Storage bridge 从当前 durable checkpoint 重新验证 active invocation/operation 绑定，接管新的 fencing token，把 `IN_FLIGHT` operation 与预算保守转为 `UNKNOWN_OUTCOME`，释放 recovery lease，并保存规范化 checkpoint；全部变更只通过一次 backend CAS 发布。CAS 冲突、错误 lease、错 operation 或错 checkpoint 均在 Facade 暴露前 fail-closed，Adapter 调用数保持不变。宿主与 bridge 组合时必须使用 `DurableExecutionRecoveryStore.openForRuntimeRecovery`，避免默认 `open()` 先独立执行旧式 restart normalization；默认入口继续保留 T07 的兼容行为。

## 4. 写前准备元数据

Tool step 通过 Policy Gateway 后，Runtime 为 `StepDispatchRequest` 生成 `DispatchPersistenceContext` 1.0。持久化端口只收到该对象的副本，字段包括：

- operation、dispatch、invocation、attempt、task 和 step 的稳定 ID；
- Tool ID、Tool identity version、schema digest 与 arguments digest；
- idempotency key/mode 与 side effect 分类；
- policy request、budget reservation、Provider ID 和本次预留的 Tool call/费用；
- 创建时间。

该对象不包含 `userIntent`、工具参数 JSON、Provider 凭据、`AuthorizationGrant` 或 grant ID。Adapter 接收 `StepDispatchRequest` 的独立深拷贝；持久化实现或 Adapter 修改各自副本时，都不会改变 Runtime 保留的 pending 绑定与拒绝记录上下文。

非 Tool step 的 `persistenceContext` 为 `undefined`。这类 step 仍按 snapshot version 保存任务状态，但没有 M05-A operation intent。

## 5. M05-A DTO 映射

宿主 bridge 将 `DispatchPersistenceContext` 映射为 `StoredOperationIntent`：

| `StoredOperationIntent` | 来源 |
| --- | --- |
| `operationId` | `context.operationId` |
| `invocationId` | `context.invocationId` |
| `taskId` | `context.taskId` |
| `stepId` | `context.stepId` |
| `attemptId` | `context.attemptId` |
| `toolId` | `context.toolId` |
| `toolIdentityVersion` | `context.toolIdentityVersion` |
| `schemaDigest` | `context.schemaDigest` |
| `argumentsDigest` | `context.argumentsDigest` |
| `idempotencyKey` | `context.idempotencyKey` |
| `idempotencyMode` | `context.idempotencyMode` |
| `sideEffect` | `context.sideEffect` |
| `policyRequestId` | `context.policyRequestId` |
| `budgetReservationId` | `context.budgetReservationId` |
| `createdAt` | `context.createdAt` |

对应的 `BudgetReservationSnapshot` 使用同一个 `budgetReservationId`、`taskId`、`stepId` 和 `providerId`。`requested.toolCalls` 取 `requestedToolCalls`，`requested.monetaryCostMicros` 取 `requestedCostMicros`，其余 requested/actual 计数初始为 0，状态为 `RESERVED`。

`dispatchId` 用于 Runtime callback 和拒绝记录关联。`policyRequestId`、`idempotencyMode` 与 `sideEffect` 用于 bridge 的绑定校验和恢复决策，并已进入 M05-A schema 1.1。`prepareOperation` 还要求对应的 version 3 Policy decision/grant 已 durable 保存并与 operation、Tool identity、参数摘要、Provider 和 reservation 完整绑定；不能在重启后凭默认值推断这些字段。

## 6. 必须保持的顺序

安全组合必须保持以下顺序：

1. Runtime 按 `snapshotVersion` 顺序等待普通状态 checkpoint 保存；
2. dispatch 前，通过 `beforeDispatch(checkpoint, expectedPreviousVersion, context, authority)` 把最终 dispatch checkpoint、version 3 Policy、operation intent、budget reservation 和预留后的完整 scope 图映射到同一次存储 transaction；
3. 只有 durable prepare 成功，才调用具体 Adapter；
4. 现有端口在 durable transaction 中取得 lease/fencing 并记录 `IN_FLIGHT`，随后才调用 Adapter；结果返回时先记录 outcome、receipt 和实际预算，再让 Runtime 应用 completion；
5. 不确定副作用保持 `UNKNOWN_OUTCOME`，取得对账报告并 durable 保存后再推进 Runtime；
6. 恢复执行者必须先取得 lease/fencing，stale owner 不得提交结果。

写前保存失败时必须拒绝 dispatch。已开始的带副作用调用若无法可靠保存结果，不能按普通失败自动重试。

当前端口没有“Adapter 已接受调用”之后的第二个 durable hook，所以 bridge 在 Adapter 调用前先提交 `IN_FLIGHT`。如果进程恰在这两步之间退出，重开存储会把该 operation 保守规范化为 `UNKNOWN_OUTCOME`；这可能产生一次无需最终结算的对账，但不会把可能发生的副作用误判为安全重试。

## 7. 当前 bridge 与 RDB composition

`AgentRuntimeFacade`、`ProductionRuntimePersistencePort` 和 completion sink 均返回 `Promise`。生产组合层暂存同步协调器产生的 checkpoint，逐个等待普通 checkpoint 保存；对 dispatch 则把最终 checkpoint、expected previous version 与最小 `DispatchPersistenceContext` 一起交给异步 `beforeDispatch`。只有该 Promise 接受后才调用 Adapter。主机测试通过人为挂起 Promise 证明等待期间 Adapter 调用数保持 0，释放后才发生 dispatch；持久化拒绝或异常会让 Facade fail-closed。Observer 事件也只在对应 checkpoint durable 后发送。

0.14.0/production composition 2.5 保留同一 Facade 实例的 FIFO 和 checkpoint authority 参数：`saveCheckpoint` 与 `beforeDispatch` 都收到同状态深拷贝。前者只允许保存 checkpoint、budget 图及 version 1 pending policy request，不能准备或回退 operation；后者才允许把 version 3 Policy、reservation、scope 与新 operation 作为单 CAS 写前准备。可选的 schema 1.0 `CollaborationPlan` 随 `PlanningRequest` 深拷贝进入 checkpoint 1.1，恢复校验会重新检查 task/mode、角色唯一性、激活预算和完整摘要；旧 Single checkpoint 继续兼容。`normalizeRecoveredOperation` 只接受协调器产生的下一版本、无 active invocation 且处于 `WAITING_RECONCILIATION` 的 checkpoint。任务提交、异步 Planner、读取、控制、授权、澄清、对账、订阅、shutdown 和异步 Adapter completion 继续按调用顺序执行。

`agent_storage` 0.8.0 的 `RuntimeExecutionRecoveryBridge` 已完成上述写入、只读恢复和 active normalization 映射：普通 checkpoint 可保存 version 1 pending policy 与初始预算图；Tool dispatch 以一次 CAS 写入 checkpoint、version 3 Policy/Grant、完整 scope/reservation、operation 和 lease/fencing，再允许 Adapter 调用。Adapter 拒绝会原子转为已确认未执行的 `PREPARED` 并释放 lease；明确 outcome 需要 `RuntimeOutcomeAccountingPort` 提供实际预算；未知 outcome 保持对账状态；确认型 reconciliation 需要 `RuntimeReconciliationSettlementPort` 提供具体 outcome 与预算。缺少宿主证据时桥接拒绝写入，不从报告文本推断结果或费用。

`createRdbRecoveredAgentRuntime` 是具体 RDB composition：宿主先按自己的安全策略打开 `RdbStore`，工厂固定用 `RdbSnapshotBackend` 和 `openForRuntimeRecovery` 创建 durable session，再把同一个 bridge 绑定为 Runtime persistence/recovery ports；只有 `createRecoveredProductionAgentRuntime` 完成全部任务恢复后才向宿主返回 `AgentRuntimeFacade`。工厂拒绝调用方预置第二组 persistence/recovery ports，并要求 Runtime 与 bridge 使用相同 policy version。RDB 加密、备份、关闭和 Ability 生命周期继续由外部宿主负责。

主机集成测试通过真实 `createProductionAgentRuntime`/`createRecoveredProductionAgentRuntime`、唯一 `AgentRuntimeFacade`、fake durable backend 与桥接验证成功结算、active operation 重开、fencing 接管、CAS 拒绝时 Adapter 调用数为 0、未知结果保持占用以及证据支持的 reconciliation。T26 在 API 26 上使用 `RuntimeRdbDeviceRecoverySeed` 建立真实 RDB active operation 并保持进程存活；主机验证就绪标记与 PID 后执行 `aa force-stop`，再由新进程的 `RuntimeRdbDeviceRecoveryRecover` 运行 1/1，验证 Facade 恢复、UNKNOWN 转换、预算保持、lease 释放和 Adapter 零重放。签名、安装、强制进程边界、恢复与卸载核对均已完成；数据库加密接线及具体 Adapter 的设备闭环仍未完成。

T23 已完成主机测试、HAR 和完整依赖图 unsigned HAP 构建；没有签名、安装、卸载或设备运行。
