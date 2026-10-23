# @harmony_agent/agent-runtime

`@harmony_agent/agent-runtime` 0.15.0 是不依赖 UI 的 Agent Runtime HAR。目前提供 Promise-based `AgentRuntimeFacade` 公共接口、异步 `SemanticPlannerPort`、版本化协作计划、M03 内部 Session/Planner/Runtime 编排、M04 Registry 与确定性 Router、M09-B 生产组合 factory、外部授权决定到内部短期授权凭证的转换、凭证绑定校验、预算预留以及 secret 脱敏。

外部宿主只能提交 `AuthorizationDecision`；`AuthorizationGrant` 由本模块内部签发并绑定 task、step、operation、tool identity、schema、arguments、policy version 和预算预留。

`Index.ets` 只把 `AgentRuntimeFacade` 暴露为业务控制接口。`createProductionAgentRuntime` 接收版本化 composition config、Planner/Router/Tool preparation ports、一个启用 Adapter 的 factory 和持久化端口，返回的仍是 `AgentRuntimeFacade`。0.14.0/composition 2.7 包含协作计划、异步准备和按 task 绑定的 Planner 中断合同；Role Registry 身份和协作决定摘要在 Planner 前冻结。异步 `createRecoveredProductionAgentRuntime` 继续通过只读 `ProductionRuntimeRecoverySourcePort` 枚举任务、读取 authority，并在 Facade 暴露前完成 checkpoint 重建、budget/policy authority hydration 和恢复事件持久化；遇到 active operation 时，先通过 persistence port 的专用 normalization 门把恢复 checkpoint 与 durable operation/fencing 原子对齐。恢复 source、factory、ports 和 DTO 都不能创建任务、推进状态或签发执行 grant；M03 的 `RuntimeCoordinator` 和生产实现类均保持模块内部可见。

生产组合层按 snapshot version 暂存检查点并等待异步持久化完成。0.14.0/production composition 2.7 延续每个 checkpoint 的同状态 `RuntimeDurableAuthorityPayload`，并把 task/snapshot version、policy version、完整 task/step/provider budget scopes、全部 reservation 以及当前可证明的 policy/operation 绑定交给 persistence port。等待授权 checkpoint 携带 version 1 request；dispatch 准备 checkpoint 携带 version 3 decision/grant 和 `PREPARED` operation，`beforeDispatch(checkpoint, expectedPreviousVersion, context, authority)` 成为宿主单 CAS 原子提交边界，成功后才调用 Adapter。active recovery 使用 `normalizeRecoveredOperation` 专用门，普通 `saveCheckpoint` 仍不能创建或回退 operation；outcome/reconciliation 之后的 operation、fencing 和结算状态仍由对应 persistence 方法维护。持久化端收到独立深拷贝，不能改写 Runtime 保留的 checkpoint、协作计划或 authority。

同一 Facade 实例的公共操作和异步 Adapter completion 继续进入同一个调用顺序 FIFO；前一项 durable lifecycle 未结束时，后一项不会进入协调器或提前完成，单项拒绝不会毒化队列。同步 Adapter completion 仍在当前 dispatch 生命周期内登记后应用，避免重入自等待。`RuntimeTaskRecoveryCheckpoint` 1.1 将原始 submission、公开 snapshot 与 envelope、workflow、scheduler、事件、规划状态、等待项、在途 invocation 和稳定关联 ID 放在同一个版本化保存单元；原始 submission 用于重建 requestId 的精确去重。`RuntimeCheckpointValidator` 在写入前以及持久化回读后校验版本、submission normalization、事件顺序、workflow/scheduler 和 task/request/session/dispatch 绑定；1.0 或绑定不一致的检查点 fail-closed。该检查点和 authority payload 都是敏感恢复数据，宿主必须按 privacy class 施加访问控制和加密，不能把它们作为公共事件输出。

内部 `RuntimeCoordinator.restoreCheckpoint` 可以在新协调器中重建 Session、事件、workflow 和 scheduler。在途无副作用步骤转为待重试，带副作用步骤转为等待对账，旧 dispatch ID 被撤销。除 COMPLETED/CANCELLED 外，所有恢复记录保持 `RECOVERY_AUTHORITY_REQUIRED` 锁定；Policy/Budget durable authority 完成 hydration 前，不能授权、推进、重规划、控制、对账或接受旧 Adapter completion。该内部方法不从公共 `Index.ets` 导出，不构成第二任务入口。

0.8.0 新增 storage-neutral `RuntimeRecoveryAuthority` 1.0 与只读 `RuntimeRecoveryAuthorityValidator`。权威图必须绑定原检查点 snapshot version、正数 durable revision 和当前 policy version，并携带完整 task/step/provider budget scopes 与全部 reservation；等待授权状态还必须匹配 version 1 policy request，在途 Tool 则必须匹配 version 3 decision/grant、operation intent、幂等模式、副作用分类、fencing/dispatch 状态和同一预算预留。校验或预算 hydration 任一失败都不解除锁；成功后内部协调器才允许原有控制路径继续。DTO 与 validator 只处理数据，不能创建或推进任务。

Tool dispatch 携带 `DispatchPersistenceContext` 1.0：只包含 operation/dispatch/invocation/attempt、Tool identity、参数摘要、幂等模式、预算预留和 Provider 等稳定元数据，不包含任务正文、工具参数 JSON、凭据或授权凭证。`beforeDispatch` 获得独立上下文副本，Adapter 获得完整请求的独立深拷贝；两者都不能改写 Runtime 保留的 pending 绑定。非 Tool step 没有 operation context。Adapter 只获得 completion-only sink；回调必须匹配 Runtime 已发出的 task、step、dispatch 和 Tool invocation，重复或伪造回调不会推进任务。同步回调会在 dispatch 返回且内部状态登记完成后再应用。

`createFakeAgentRuntime` 和 `FakeAgentConsumer` 是 M09-A 的显式测试实现；它们用于无 UI 合同验收，不伪装成生产 Planner、Provider、Store 或系统 Tool。M02 的 `PolicyGateway` 仍保持模块内部可见。

M11/T46 新增 storage-neutral `ArtifactRegistry` 数据面。它要求 signed canary/active/rolledBack manifest 先通过宿主注入的 `ArtifactPackageVerifierPort`，再以明确的 `harmony_agent-runtime>=x.y.z`、`api>=n` 和 feature schema allowlist 检查实际 Runtime 兼容性。每种 artifact kind 只有一个 canary 指针和一个 active 指针；immutable active release 可保留为历史 rollback target，新的 active 以单次持久化 CAS 替换选择指针，rolledBack release 按 digest 原子恢复旧 active。相同 artifact ID 的 provenance、payload digest、compatibility 和三类结果不能在生命周期更新中漂移。

Registry 快照通过 `ArtifactRegistryPersistencePort` 先持久化后发布，CAS/摘要/验签异常均返回稳定拒绝，重开时会重新检查 snapshot integrity、signed package receipt 和当前 Runtime compatibility。该公共数据 API 不能提交、控制、授权或推进任务；T47 release runner 只消费 Registry 的防御性只读视图，仍不直接接管具体 Router。生产宿主必须为 verifier 提供受信公钥、撤销策略和按 package digest 绑定的真实 T45 验签结果，并为 `ArtifactRegistryDigestPort` 提供密码学摘要；不能根据 manifest 自报字段直接返回成功。具体接线见 `docs/AGENT_ARTIFACT_REGISTRY_INTEGRATION.md`。

T47 新增 `ArtifactPolicyReleaseRunner` 与 `DeterministicArtifactCanaryAssignment`。Runner 总是先调用并校验 deterministic baseline，再读取 T46 Registry：shadow 只生成数量有界且不含异常文本的观察；canary 仅在稳定 0–9999 bucket 命中 basis-point 阈值时参与选择；未命中或 canary 失败时使用当前 active，active 异常、越界 decision 或 Registry view 损坏时回退 baseline。`0 bp` 不调用 assignment port，`10000 bp` 全量命中。请求、Registry entry 和 decision 均复制隔离。M11-E 又为 baseline、shadow、canary 和 active 的每次调用增加默认 5000 ms 的有界执行、外部取消订阅和每次尝试独立的协作取消信号；超时会通知策略释放资源并忽略迟到结果。shadow 超时只形成观察，canary 超时回退 active，active 超时回退 baseline，baseline 超时和外部取消则返回稳定的非接受结果。该 runner 只处理候选 ID 与 opaque JSON evidence，不创建任务、不签发授权、不执行工具，也不替代具体 Model/Tool Router 的 hard eligibility。

M03 当前提供：

- `TaskSubmission -> TaskEnvelope` 规范化、ID 分配与重复提交去重；
- `TaskAnalyzer -> CollaborationSelectorPort/CollaborationPlanSelectorPort -> SemanticPlannerPort` 两阶段规划；显式计划携带 schema 1.0、task/mode、完整 SHA-256 Role Registry/decision 摘要和互异 role identity。MULTI 没有有效计划时在 Planner 前 fail-closed；Planner 的 plan/resume/replan 均为 Promise，且必须实现按 task 绑定的 `interrupt`。Facade 串行队列会等待规划完成后才允许 Tool dispatch；取消和 shutdown 可在 FIFO 外只发计算中断信号，任务状态与持久化仍在 FIFO 内完成；非取消 Promise 拒绝时任务以稳定的 `plannerInvocationFailed` 证据闭合，底层异常文本不会进入公共快照或事件；
- Planner 结果必须通过 M01 `WorkflowGraphValidator`，文本不能直接触发 adapter；
- Scheduler 驱动、暂停/恢复、取消、澄清、授权等待、异步 dispatch、迟到完成拒绝和未知结果对账；
- 受保护的成功、运行中和 `UNKNOWN_OUTCOME` 步骤不能被 partial replan 替换；
- planner call、agent activation 和 replan 使用量显式计数。

M04 当前提供：

- Model、Role、Tool、Workflow 四类内存 Registry；稳定 ID、版本、调用方提供的 digest 与确定性快照身份分离；同版本内容漂移拒绝；
- Model/Tool Router 先执行 region、隐私、能力、风险、副作用、权限、数据边界、网络和成本硬过滤，再进行确定性评分；
- learned Model/Tool policy 可关闭；越界选择、低置信度、异常或不可用时回退到确定性 baseline；
- Context Router 按系统、用户、已验证依赖、短期历史、允许的长期记忆与可选内容顺序守 token 预算；
- Collaboration Router 对 Runtime composition port 保持单 Agent，只有显式 route 请求、可并行任务、独立能力和至少两个 activation 预算时才返回 multi；
- Tool Router 不依赖 embedding，并保持 schema、description、retrieval relation 的版本职责分离。

当前限制：M04 的 Model/Role/Tool/Workflow Registry 仍是内存实现，其 `snapshotDigest` 是由调用方提供的 entry digest 组成的确定性身份串，不声称由 Runtime 重新计算密码学哈希；M11 Artifact Registry 与 release runner 已有 durable CAS、shadow/canary/active/fallback/rollback 和通用 timeout/cancel 协议，但生产 verifier、密钥治理、policy loader、具体策略资源释放实现和 Router 接线仍由宿主与 M12–M14 完成。0.14.0 已冻结协作计划验证/恢复、异步 Facade、异步 Planner 生命周期、同实例 FIFO、checkpoint/authority 写入，以及无在途和 active operation 的启动恢复；M05-A bridge 可把 active operation 保守转入 `WAITING_RECONCILIATION`，不会在重启后重放 Adapter，具体 RDB composition 和 API 26 跨进程恢复已由 T26 验收。生产 credential store、真实 learned Router artifact 或带写副作用 Tool 仍未接入。映射和时序边界见 `docs/AGENT_RUNTIME_STORAGE_INTEGRATION.md`。

T63 增加 storage-neutral 的资源型 policy loader adapter。宿主把 process、worker、IPC 或 network 调用包装为 `ArtifactPolicyResourceOperationPort`；Runtime 在成功时关闭资源，在 timeout、取消或失败时同时取消并关闭资源，且忽略迟到结果。主仓库只提供生命周期合同和 fixture，生产 verifier、密钥治理、具体 loader 及底层资源实现仍由宿主负责，见 `docs/AGENT_ARTIFACT_POLICY_LOADER_INTEGRATION.md`。

P0-B 增加 storage-neutral `PlanningMemoryContextPort`。Runtime 只定义 task/owner 绑定与条目/字符预算合同；具体索引由 Storage 适配，Provider Planner 负责二次校验与预算核算。该接口不提供记忆写入或宿主加密，见 `docs/AGENT_MEMORY_CONTEXT_INTEGRATION.md`。

P0-A 增加 host-neutral `createSingleAgentHostRuntime`。它只编排资源生命周期：依次打开 credential store、execution storage、memory storage 和 MCP client，随后由注入 factory 创建唯一 `AgentRuntimeFacade`；失败时逆序回滚，shutdown 时先停止 Runtime 再逆序释放资源。它不创建具体 RDB、密钥或网络对象，也不取代产品 Ability composition root，见 `docs/AGENT_SINGLE_HOST_COMPOSITION.md`。

P0-D 补齐 Planner 取消传播。`SemanticPlannerPort.interrupt(taskId)` 只中断计算，不在队列外修改任务状态；`ProviderSemanticPlanner` 为每个在途请求登记独立 `ProviderCancellationSource`，只取消匹配 task，并在 Promise 结束后注销。协作 Planner 委托同一中断合同。具体时序与验收见 `docs/AGENT_PLANNER_CANCELLATION.md`。
