# @harmony_agent/agent-storage

`@harmony_agent/agent-storage` 是无 UI 的 Agent 存储 HAR。0.8.0 同时承载 M05-A 执行恢复边界、Runtime 宿主持久化桥接与 M05-B 长期记忆 baseline；它不是任务执行入口，也不依赖 ArkUI、Ability 或产品 HAP。

## M05-A：执行恢复

M05-A 提供 Repository ports、确定性参考 Store、task snapshot CAS、operation/budget 原子 prepare、append-oriented trace、Registry/Policy 记录、snapshot integrity/migration 端口、recovery lease/fencing、durable snapshot session，以及 API 26 RDB backend。

`ExecutionRecoveryStore` 是用于验证恢复协议的纯 ArkTS 参考实现，不是持久化数据库。`DurableExecutionRecoveryStore` 在隔离事务副本上运行这些状态转换，并只在 `DurableSnapshotBackendPort.compareAndSet` 成功后发布新状态。CAS 失败不会污染当前内存状态，调用方也不得继续平台调用。

`RdbSnapshotBackend` 使用单槽 RDB 表保存 schema version、revision、payload JSON 和 integrity digest。它只接收宿主已打开的 `relationalStore.RdbStore`；数据库配置、加密、备份、打开和关闭仍由外部 composition root 负责。调用方必须提供生产级 `SnapshotIntegrityPort`。除主机测试外，T07 的 API 26 无页面设备套件已验证真实建表、close/reopen、损坏 fail-closed 和恢复 session 竞争；这只关闭 M05-A 存储前置门，不会自动批准任何具体写 adapter。

执行恢复 schema 1.2 在 1.1 的完整 task/step/provider budget authority 之上，为每个任务保存 `checkpointVersion` 与 opaque `checkpointJson`，并提供 `listTaskIds`。存储只验证 checkpoint JSON 的语法与版本字符串；Runtime 必须继续用自己的 validator 校验 checkpoint 1.1 的结构、身份与状态绑定。`ExecutionRecoveryTransaction` 在隔离副本中组合 checkpoint 与 authority mutation，并用一次 backend CAS 发布；CAS 失败不会发布任一部分。旧 schema 不能靠默认字段恢复，必须由显式迁移器生成可通过完整校验的 1.2 数据。

固定写入顺序：

1. `prepareOperation` 同时记录 `PREPARED` intent 和 `RESERVED` budget；
2. 持有有效 recovery lease/fencing token 的执行者调用 `markOperationInFlight`；
3. 平台调用结束后用 `recordOperationOutcome` 原子记录 outcome 并结算预算；
4. 调用结果不确定时用 `markOperationUnknown`；重启时 `IN_FLIGHT` 必须先通过后续 operation/lease 恢复事务归一化，不能由读取路径自动改写；
5. `reconcileOperation` 明确确认已提交，或确认未执行后重新变为 `PREPARED`。

Router、Planner 和外部宿主不能借此签发授权；Policy Gateway grant 仍是执行前置条件。

### Runtime 宿主桥接

`RuntimeExecutionRecoveryBridge` 实现 `ProductionRuntimePersistencePort`，但不提供提交、授权、控制或推进任务的方法。外部宿主仍须只向产品侧暴露 `AgentRuntimeFacade`。桥接在 Tool dispatch 前用一个 `ExecutionRecoveryTransaction` 同时保存 checkpoint、version 3 Policy/Grant、完整预算权威、`PREPARED` operation、recovery lease，并把 operation 转为带 fencing token 的 `IN_FLIGHT`；CAS 拒绝时 Adapter 不会被调用。由于当前 Runtime 端口没有“Adapter 已接受调用”的第二个持久化 hook，`IN_FLIGHT` 会在实际 Adapter 调用前提交；两者之间崩溃将保守地进入 `UNKNOWN_OUTCOME` 对账，避免重复副作用。

明确结果通过宿主注入的 `RuntimeOutcomeAccountingPort` 提供实际 `BudgetAmount` 后结算；`UNKNOWN_OUTCOME` 保留预算占用并释放执行 lease。`STILL_UNKNOWN` 不改变 durable 状态，`NOT_EXECUTED` 回到可重试的 `PREPARED`，确认成功/失败必须由 `RuntimeReconciliationSettlementPort` 提供与 operation 绑定的具体 `ToolOutcome` 和实际预算。缺少计量、结算证据、契约绑定或有效 fencing 时均 fail-closed。bridge 继续实现只读 `ProductionRuntimeRecoverySourcePort`，active operation normalization transaction 通过一次 CAS 接管 fencing、把 `IN_FLIGHT` 与预算转为 `UNKNOWN_OUTCOME`、释放 recovery lease，并保存 Runtime 产生的 `WAITING_RECONCILIATION` checkpoint。恢复过程中不会再次调用 Adapter。

0.8.0 新增 `createRdbRecoveredAgentRuntime` 作为具体 RDB composition。它接收宿主已打开的 `RdbStore`、完整性端口、bridge 配置和 Runtime 的非持久化端口，内部固定使用 `openForRuntimeRecovery`，并在全部 durable task 恢复完成后只返回唯一 `AgentRuntimeFacade`。调用方不能同时注入另一组 persistence/recovery ports；数据库打开、加密、备份、关闭和 Ability 生命周期仍由外部宿主负责。

## M05-B：长期记忆 baseline

`MemoryRepository`、`ArtifactRepository`、`RebuildableMemoryIndexPort` 和 `MemoryTransferPort` 定义长期记忆与派生数据边界。`DeterministicMemoryStore` 是纯 ArkTS 参考实现，当前提供：

- owner 隔离、内容 digest 校验、显式版本 CAS 与复制隔离；
- 原子批量导入，默认拒绝原始个人轨迹；
- 确定性分块、可重建词法索引与稳定排序；
- 本地检索默认排除敏感记忆和原始个人轨迹；
- 导出默认只包含 `SHAREABLE`，并对标题、正文和标签应用调用方提供的脱敏词表；
- 更新和删除时同步失效 chunk、索引条目和派生 artifact。

该实现不上传数据，也不调用模型或 embedding。`DurableMemoryStore` 在隔离副本上执行变更，仅在完整快照 revision CAS 成功后发布；权威 Memory 与非索引 artifact 进入快照，chunk 和词法索引在 reopen 后重建。`RdbMemorySnapshotBackend` 使用独立的 API 26 RDB 单槽表，并继续由宿主负责数据库打开、加密、备份和关闭。主机测试已覆盖 CAS、并发、重开重建、损坏与显式迁移，RDB 代码也已通过类型检查；设备 close/reopen、真实损坏注入和宿主加密配置仍待验收，因此 M05-B 仍处于实施中。调用方必须提供生产级 `MemoryDigestPort` 和 `MemorySnapshotIntegrityPort`，不得把测试 digest 当作安全摘要。

2026-10-11，0.8.0 合并主机套件 47/47、Release HAR 和完整依赖图 HAP 构建已通过。`RuntimeRdbDeviceRecoverySeed` 在 API 26 真实 RDB 中建立 active operation 后保持进程存活，主机验证就绪标记与 PID 后执行 force-stop；`RuntimeRdbDeviceRecoveryRecover` 在新进程运行 1/1，通过对账状态、UNKNOWN operation/budget、lease 释放和 Adapter 零重放断言。签名验证、安装、卸载及 bundle 不存在核对均已完成，T26 跨进程恢复门已关闭。M05-B 当前命名签名包也已在 API 26 运行 3/3；宿主长期记忆加密配置仍待验收。数据库、manifest 和证据兼容边界见 [`HARMONY_AGENT_NAMING.md`](../docs/HARMONY_AGENT_NAMING.md)。

公共存储类型和 backend 是 composition ports，不是第二条 Agent 业务控制入口。外部产品调用任务能力时仍只能使用 `AgentRuntimeFacade`。

### Planner 记忆上下文适配

`RuntimeMemoryContextAdapter` 把 `RebuildableMemoryIndexPort` 投影为 Runtime 的 `PlanningMemoryContextPort`。查询始终以任务的 `userId` 作为 owner，固定拒绝敏感记忆与原始个人轨迹，并在返回前应用条目数和字符数预算。它不写入记忆、不访问网络、不调用模型，也不负责数据库加密。Provider Planner 接线、关闭顺序和宿主配置见 [`AGENT_MEMORY_CONTEXT_INTEGRATION.md`](../docs/AGENT_MEMORY_CONTEXT_INTEGRATION.md)。

### 加密 RDB 配置

`createEncryptedRdbStoreConfigs` 为执行恢复库和长期记忆库生成 `encrypt: true`、`persist: true` 的 API 26 `StoreConfig`，并拒绝同名或不安全文件名。它不接收原始密钥，也不替宿主打开数据库；接线和设备验收边界见 [`AGENT_ENCRYPTED_RDB_CONFIGURATION.md`](../docs/AGENT_ENCRYPTED_RDB_CONFIGURATION.md)。

## M11：Artifact Registry 持久化适配

T46 新增 `DurableArtifactRegistryAdapter`。它把 Runtime 拥有的完整 Artifact Registry envelope 保存为现有 `DurableExecutionRecoveryStore` 中固定 ID `artifact-registry:m11` 的 Registry record，并同时核对 record version、record digest 与 envelope metadata。Artifact revision 使用 Registry record version 做局部 CAS，底层 durable store 再以全局 snapshot revision CAS 发布；任一竞争失败都不会更新 Runtime 内存选择指针，调用方必须重开 durable session 后重试。

该适配器不解释 manifest、不验签、不决定兼容性或路由，也不提供任务提交、控制、授权和执行方法。Runtime 在首次读取和每次发布时负责 manifest、验签 receipt、compatibility、生命周期和 rollback target 校验；宿主仍负责 RDB 打开、加密、备份、迁移和关闭。接线与信任边界见 [`AGENT_ARTIFACT_REGISTRY_INTEGRATION.md`](../docs/AGENT_ARTIFACT_REGISTRY_INTEGRATION.md)。

RDB 设备验收用例、构建命令、运行门和清理要求见 [`docs/AGENT_STORAGE_DEVICE_ACCEPTANCE.md`](../docs/AGENT_STORAGE_DEVICE_ACCEPTANCE.md)。

