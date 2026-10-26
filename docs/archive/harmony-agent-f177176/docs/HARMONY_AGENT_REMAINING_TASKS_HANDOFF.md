> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/HARMONY_AGENT_REMAINING_TASKS_HANDOFF.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# harmony_agent 剩余任务拆分与实施移交

状态：待实施；当前 Agent 后续只负责验收

编制日期：2026-10-18（Asia/Shanghai）

基线工作区：`D:\Harmony_agent`

基线提交：`41e1ce4b57521e62a360035acdf4fb50e137923a`

## 1. 给接手 Agent 的直接指令

请沿用现有架构、模块和任务编号，在 `D:\Harmony_agent` 内按本文逐门实施。不要重新设计 Runtime，不要另建产品工程，不要开发 UI、页面、确认界面或产品 Entry HAP。`AgentRuntimeFacade` 始终是唯一任务控制入口；内部 coordinator、policy loader、Router、Registry、测试工具和离线研究代码不得形成第二入口。

每次只实现一个任务门，创建独立的 `codex/` 分支，完成后提交并推送，把分支名、完整 commit、变更清单、测试输出、artifact/HAR 摘要、证据目录和未验证边界交给验收 Agent。未经项目所有者明确重新分配，验收 Agent 只复核和给出通过/退回结论，不代替实施 Agent 修复代码。

MTRouter 训练仍按项目所有者决定暂停。不要执行 T49，不要创建训练仓库，不要安装训练依赖、下载模型、生成 embedding、训练 checkpoint 或运行付费 benchmark。本文中标为“暂停”或“需单独授权”的工作也不能从本次移交推断为已获授权。

## 2. 不可改变的项目边界

1. 只交付 AgentRuntimeFacade、公共 DTO/事件、Adapter ports、HAR、明确标记的 fake consumer、fixture、测试和集成说明。
2. 不把 `generate`、`confirm`、`records` 等产品业务接口直接塞进通用内核。
3. `test_host` 只是无页面设备测试宿主，不是产品前端。
4. Router 只能在 hard eligibility、预算、Policy Gateway 和 Registry 约束内建议，不能恢复已被过滤的模型、角色或工具。
5. Strong Single 和 deterministic baseline 永久可用。learned policy 缺失、超时、取消、异常、低置信度、NaN/Infinity、摘要或 schema 不匹配时必须 fail closed。
6. MTRouter、MasRouter、HYSET 和 AFlow 的论文复现、harmony_agent adaptation、ArkTS/bridge parity、shadow、canary、active 和设备证据必须分开报告。
7. Python、PyTorch、训练数据、optimizer state、大型 encoder/tokenizer 和上游研究仓库不得打入 HAR/HAP。
8. 凭据、请求/响应正文、用户隐私、原始长期记忆和生产私钥不得进入源码、命令、日志、fixture 或验收证据。
9. 不安装依赖、不修改全局配置、不签名、不安装/卸载设备包、不调用真实 Provider、不创建或删除远端资源，除非项目所有者对该批次明确授权。
10. 不运行 workspace migration，不清理或重置工作树，不处理 C 盘旧项目。

## 3. 工作树和 Git 保护

当前基线分支为 `codex/module-masrouter-t50`，提交为 `41e1ce4b57521e62a360035acdf4fb50e137923a`。实施 Agent 开始时必须重新核对 HEAD、upstream 和工作树。

以下 6 个文件是进入移交时已经存在的未提交差异，必须保留，不得暂存、覆盖、恢复、reset 或 clean：

- `agent_connectors/BuildProfile.ets`
- `agent_connectors/oh-package-lock.json5`
- `agent_runtime/BuildProfile.ets`
- `agent_storage/oh-package-lock.json5`
- `native_tools/oh-package-lock.json5`
- `test_host/oh-package-lock.json5`

每个任务从“最近一次已通过验收的提交”建分支。未验收分支不能作为后续任务的事实基线；确需依赖时，在报告中声明临时依赖关系，不得把“能编译”写成“前一门已验收”。

## 4. 状态定义

| 状态 | 含义 |
|---|---|
| READY | 可在当前授权范围内实施，不需要安装依赖、凭据、费用或设备操作 |
| APPROVAL | 实施前可完成方案、代码和离线检查，但真实安装、下载、外部调用、签名或设备批次需要项目所有者单独授权 |
| PAUSED | 因项目所有者“暂不训练”的决定暂停，不得自行启动 |
| EXTERNAL | 主仓库只能提供 port、fixture、检查器和集成说明，真实实现或配置属于产品宿主/运维边界 |

## 5. 总体顺序

```text
M12/T49 继续暂停

M13: T51 -> T52 -> T53 -> [T54 暂停] -> [T55 等待 T54 和真实批次授权]
M14: T56 -> T57 -> [T58 需授权] -> [T59 等待 T58]
M15: T60 -> T61 -> [T62 需授权]

Cross-cutting: T63 -> T64 -> T65
```

默认按编号顺序提交验收。T56 和 T60 的纯离线来源冻结可以在 M13 等待授权时推进，但必须使用独立分支，不能把未验收的 M13 代码混入 M14/M15。

## 6. 详细任务

### T49：M12 原环境复现与训练

状态：**PAUSED**

继续沿用 `docs/MTRouter_TRAINING_REPOSITORY_HANDOFF.md`。除非项目所有者明确说“恢复 MTRouter 训练”，不得执行任何安装、下载、训练、Provider/Serper 请求、checkpoint、parity、shadow、canary 或 active 工作。现有 `LearnedRouterPort`、来源锁和 handoff checker 保留，`learnedEnabled=false`。

### T51：M13-B MasRouter 环境、数据与价格输入定义

状态：**READY**

目标：在不安装依赖和不运行上游代码的情况下，把 T50 已发现的环境缺口变成可审计的输入合同。

实施范围：

- 从固定 commit 的 import、README 和实验入口生成依赖候选清单；未知版本必须标记 unresolved，禁止猜成“已锁定”。
- 定义 Python/PyTorch/CUDA 或 CPU 环境 lock schema、dataset lock schema、Provider/model revision schema 和 price snapshot schema。
- 分别固定论文四模型核心池、DeepSeek-V3 归纳验证和源码五模型 profile，禁止静默合并。
- 明确 GSM8K/HumanEval 的 seeded 20/80 划分、MATH 519 样本口径、MMLU/MBPP 的仓库划分及数据摘要要求。
- 给 Claude 价格冲突、README 路径大小写错误和缺失 checkpoint/manifest 建立 unresolved issue 清单。

交付物：`offline/paper_repro/masrouter/` 下的版本化环境候选、数据/价格 schema、checker、少量 fail-closed 自测和确定性报告；同步更新架构与进度文档。

最低验证：JSON/schema 可解析；checker 正向通过；至少拒绝未解析依赖冒充 locked、dataset digest 缺失、model revision 漂移和价格冲突被静默覆盖。离线任务不跑 ArkTS/HAR。

完成边界：只能声明“环境输入合同完成”，不能声明依赖可安装、上游 smoke 通过或论文可复现。

### T52：M13-C MasRouter adaptation schema 与 handoff admission

状态：**READY**，依赖 T51 验收通过

目标：为未来研究产物定义主仓库可接收的候选合同，不生成或假装存在真实 checkpoint。

实施范围：

- 定义版本化 feature envelope、候选角色集合、候选模型集合、single/multi、角色有序分配、置信度、成本/激活估计和完整来源摘要。
- 输入角色只能来自当前 Role Registry；输出不能携带新角色、任务控制命令、授权决定或 Provider credential。
- 定义 handoff manifest、逐文件 SHA-256、普通文件/路径穿越/符号链接检查、未列文件拒绝和大小统计。
- 明确排除 sentence-transformers encoder、tokenizer、Python/PyTorch runtime、optimizer state、数据集和训练日志进入 Runtime/HAR/HAP。
- 使用现有 M11 ArtifactManifest/Registry/release runner，不创建第二套发布系统。
- 同步网络或 embedding 请求禁止进入 `CollaborationPlanSelectorPort.selectPlan()`；如需异步 feature preparation，只能提出与现有 Planner/FIFO/timeout/cancel 边界兼容的 ADR，先验收设计再实现。

交付物：handoff contract、纯离线 checker、自测、示例 research-only fixture 和集成说明。

最低验证：正向 fixture；角色越界、模型越界、摘要漂移、未知字段、额外文件、encoder/runtime 混入、任务控制字段和同步网络声明均应被拒绝。无需全仓测试。

完成边界：checker 通过只表示结构准入，不证明训练、准确率、parity、包体、设备或生产发布通过。

### T53：M13-D Collaboration policy 适配骨架与 deterministic fallback

状态：**IMPLEMENTED / 待人工审核**。2026-10-19 本地主机门与 Release HAR 通过；详见 `docs/architecture/T53-协作策略接入与验收.md`。依赖 T52 审核修复（同工作区未提交）。

目标：沿用现有 Runtime 和 M11 release runner，以 fake/research-only artifact 验证接线和失败回退，不启用 learned policy。

实施范围：

- 只实现内部 policy adapter/loader port 和 composition 接线；公共任务入口仍只有 `AgentRuntimeFacade`。
- 适配输出必须转换为现有 `CollaborationPlan` 并经过现有 validator、Role Registry identity/digest、activation budget 和 checkpoint 校验。
- `learnedEnabled` 默认 false；缺 artifact、加载失败、超时、取消、低置信度、越界角色/模型、预算不足或非法数值回退 deterministic Single/baseline。
- Multi 选择前预留完整 activation budget，一次任务最多进行一次协作重判。
- fake artifact 只能证明控制流，不得标为 MasRouter checkpoint 或论文复现产物。

交付物：Runtime 内部适配代码、必要公共 port 导出、集成说明、定向 Hypium 测试、Release HAR 和证据目录。

最低验证：只跑受影响的 runtime 测试、新增 fail-closed 用例和 Runtime Release HAR；只有公共契约或跨模块 wiring 改动时才扩大到相关模块。无需设备测试。

完成边界：本门不关闭 S9，不声明 learned quality、parity、shadow 或生产可用。

### T54：M13-E MasRouter 严格复现、训练与候选导出

状态：**PAUSED / APPROVAL**，依赖 T51–T53；受“暂不训练”决定约束

恢复后也必须分批授权：隔离环境安装、依赖下载、数据下载、模型/encoder 下载、凭据读取、Provider 调用和费用批次。不得修改全局 Python/CUDA/PATH。

最低交付：可重建 dependency lock、上游 smoke、完整数据/model/price identity、论文协议与源码协议分别运行、全部 seed/失败 run、checkpoint/feature schema/golden fixture、包体测量和清理记录。若环境或 Provider 已漂移，结果标为 nonComparable。

### T55：M13-F parity、shadow、S9 head-to-head 与设备/生产门

状态：**APPROVAL**，依赖 T54 有合格候选

顺序固定为：offline reference parity → ArkTS/bridge parity → disabled → shadow → canary → active。使用同一 T43 12×2 Bench schema、模型池、权限、价格快照和预算比较 Strong Single 与 learned collaboration；同时报告 unnecessary activation、质量、成本、延迟、Agent 数、消息量和 fallback。

真实 Provider、签名、安装/卸载和设备批次必须分别取得授权。没有稳定 Pareto 改善或出现成本放大、越权、不可回滚时保持 deterministic baseline，并可形成 No-Go 结论关闭研究门。

### T56：M14-A HYSET 上游来源冻结与复现准入

状态：**IMPLEMENTED / 待人工审核**。2026-10-19 离线来源门完成，报告与边界见 `offline/paper_repro/hyset/README.md`。

目标：按 T48/T50 的证据模式冻结官方仓库、论文、license、commit/tree、关键文件、checkpoint/encoder 身份、依赖声明、数据和论文目标。

实施范围：只读获取和短期检查上游；主仓库只保留 lock/spec/checker/report，不 vendoring 上游仓库、checkpoint 或 encoder。服务器原版复现与 harmony_agent adaptation 必须分开。

最低验证：确定性报告、来源漂移/执行声明/架构边界的少量关键自测；不安装依赖，不下载 checkpoint，不跑模型。

完成记录：固定官方 commit/tree、MIT/Apache-2.0 许可证边界、arXiv v2、26 个关键文件、13,860-tool corpus、六个 100-query split、论文参数与结果表。checkpoint、BERT/Qwen encoder、ToolLLaMA/DFSDT 的权威 revision/digest、raw ToolBench/UltraTool、reward/trajectory 和 judge snapshot 仍 unresolved；T56 不把这些缺口伪装为可执行复现。`.gitmodules` 声明与固定提交的 tracked-tree 存储差异已显式记录。确定性报告和 11/11 fail-closed 自测见 `offline/paper_repro/hyset/`。T57 可继续；T58 仍需身份补齐和单独授权。

### T57：M14-B Tool-Set handoff 合同与规模基线 harness

状态：**READY**，依赖 T56

目标：在没有 HYSET checkpoint 时先冻结工具检索输入、输出和公平比较方法。

实施范围：

- 输入分别绑定 Tool Registry identity、input schema digest、description digest、retrieval relation version 和 hard eligibility 结果。
- 输出只能对已合格工具形成 tool set/ranking；risk、permission、side effect 和 data boundary 不能被 relevance score 覆盖。
- 新工具、未知 schema/relation、空 artifact、超时或异常回退 independent deterministic top-k baseline。
- 扩展 TestKit 到 32/128/512/2,048/10,000+ Registry 的纯 fixture 规模，记录 completeness、wrong-tool、时延、内存和输出大小。
- learned fixture 必须明确标为 fake/research-only，不可产生质量结论。

最低验证：受影响 TestKit/Runtime 定向测试、规模 harness 的可重复报告；若修改 Runtime 则构建对应 Release HAR。无需 Provider 或设备。

### T58：M14-C HYSET 严格复现、checkpoint 适配与 parity

状态：**APPROVAL**，依赖 T56–T57

需要单独授权安装隔离依赖、下载官方 checkpoint/encoder 和数据。交付原版复现、reference inference、artifact handoff、ArkTS/bridge parity、包体/内存/延迟报告。任何大型 encoder 或 Python runtime 不得进入 HAR/HAP；资源不满足端侧约束时采用受控服务或保持 baseline，不能强行部署。

### T59：M14-D S10 top-k vs HYSET head-to-head

状态：**APPROVAL**，依赖 T58

在相同 Registry、eligible set、任务、模型、价格和权限下比较 independent top-k 与 HYSET。必须覆盖 32/128/512/2,048/10,000+，并报告 completeness、wrong-tool、质量、延迟、峰值内存和成本。未形成稳定净收益则 No-Go，保留 top-k baseline。

### T60：M15-A AFlow 上游来源冻结与复现准入

状态：**READY**

按 T56 相同方式冻结官方来源、论文、license、依赖、数据/evaluator、搜索预算和论文目标。不得把论文或评审材料中的操作建议当成执行授权，不安装依赖或调用模型。

最低验证：纯离线 lock/spec/checker/report和少量关键漂移用例。

### T61：M15-B 白名单 Workflow 搜索合同与安全 fixture

状态：**READY**，依赖 T60

目标：先证明候选 Typed Workflow 可以安全进入现有 Graph Validator 和 M11 artifact 链，而不是运行真实 AFlow 搜索。

实施范围：

- 定义白名单算子、参数、边上限、节点上限、循环/递归禁止、复杂度预算和 canonical workflow digest。
- 禁止任意生成代码、动态 import、shell、文件系统、网络或未注册 Tool/Model/Role。
- 候选只进入离线 evaluator；不能提交、授权或推进真实任务。
- Graph Validator、Policy/Budget、Registry identity、permission 和 side-effect 约束继续由现有模块裁决。
- 未通过隐藏集、跨 judge、安全、复杂度或成本门时继续使用手写 workflow。

最低验证：候选正向、未知算子、任意代码、循环、复杂度超限、未注册能力、摘要漂移和 rollback fixture；受影响模块定向测试及必要 HAR。

### T62：M15-C AFlow 官方复现、候选搜索与 S11 head-to-head

状态：**APPROVAL**，依赖 T60–T61

真实搜索可能产生 Provider 费用，执行前必须提交模型、数据发送范围、请求/token/费用/时间上限和清理计划并取得授权。比较 handwritten workflow 与候选 workflow，分开报告训练/搜索集、validation 和隐藏 test；不得只报告最佳候选。候选只有经过 M11 signed artifact、shadow/canary 和 rollback 门后才可能 active。

### T63：M11-F 具体 policy loader 与取消资源释放

状态：**IMPLEMENTED / 待人工审核**（fixture）/ **EXTERNAL**（生产实现）

目标：补齐 M11-E 留下的具体资源释放证据。

主仓库可以实现 storage-neutral loader port、进程/worker/IPC/网络 fixture 和 fail-closed 测试，证明 timeout/cancel 信号会停止底层工作、释放订阅并忽略迟到结果。生产密钥信任、撤销、轮换、私钥保管和实际推理服务生命周期由宿主负责；仓库只提供接口、验证器、fake 和集成说明。

2026-10-19 实现记录：新增 `ArtifactPolicyResourceOperationPort`、baseline/released loader port 与 managed adapter。资源 operation 在 timeout/cancel 时立即收到 `cancel()` 和 `close()`，成功时只 `close()`；fixture 分别覆盖 process、worker、IPC、network 四类底层以及 active 迟到结果隔离。Runtime Hypium 127/127、Release HAR 构建通过。该结果不证明生产 loader、密钥、模型、IPC 或网络服务已经接入。

最低验证：baseline/shadow/canary/active 四路径的 timeout/cancel/resource release；无明文密钥；Runtime 定向测试和 HAR。

### T64：外部宿主集成验收包

状态：**EXTERNAL / APPROVAL**

拆成三个独立验收子门，不互相冒充：

1. T64-A：宿主 credential store 接线。主仓库验证 port、最小作用域、一次解析、日志脱敏和轮换后 fail-closed；不保存生产 secret。
2. T64-B：长期记忆宿主加密接线。验证 key provider、密文持久化、错误 key/损坏、轮换/恢复和明文残留扫描；既有 RDB 设备证据不能替代此门。
3. T64-C：第三方远端 MCP 兼容。使用明确批准的 server，固定协议/version/auth/能力和数据发送范围；与本地 fixture 证据分开。

真实配置、网络、凭据、签名和设备操作逐批授权。产品宿主没有提供实现时，可以交付验收说明和 fixture，但必须标记 blocked/external，不能关闭对应生产门。

### T65：发布候选、整体验收与首个 tag

状态：**APPROVAL**，依赖项目所有者确定本次 release scope

目标：只整合已逐门验收通过的分支，生成 release manifest、模块版本、HAR 摘要、公共 API 清单、兼容矩阵、已知限制和回滚说明。按变更范围运行合并测试和 Release HAR；需要设备证据的模块使用已有仍适用证据或经授权复验，不能用 host test 代替。

创建/推送首个 source tag、GitHub release 或发布制品属于外部写入，必须在候选内容可审查后取得项目所有者最终授权。未完成的 M12–M15 learned policy 可以明确排除在首个 release scope 之外；接口保留不等于功能已上线。

## 7. 最低测试策略

项目所有者允许适当减少测试。实施 Agent按以下范围执行，不能把“减少测试”解释为取消关键失败路径：

| 变更类型 | 最低要求 |
|---|---|
| 纯 lock/spec/checker/docs | checker 正向、2–4 个关键漂移拒绝、JSON parse、`git diff --check` |
| 单模块 ArkTS 实现 | 受影响模块现有套件、新增关键正/负向、Release HAR |
| 公共契约或跨模块 wiring | contracts + 直接依赖模块定向套件 + 相应 Release HAR |
| Storage/CAS/恢复 | 定向并发、损坏、重开、fail-closed；需要平台行为时再申请设备批次 |
| Provider/MCP 真实调用 | 离线 fixture 先通过，再做有请求/token/费用上限的单独授权批次 |
| 签名/设备 | verify-app/profile、安装、指定 suite、原始结果、卸载和独立不存在检查 |
| learned policy 质量 | 预注册数据/模型/价格、baseline、全部 seeds、失败 run、parity、资源与回滚 |

全仓测试只在公共 DTO/schema、依赖图、统一构建配置或 release candidate 发生变化时执行。不要无理由重复已关闭模块的设备验收。

## 8. 每个任务的证据目录

统一使用：

```text
artifacts/tNN-short-name/YYYYMMDD-HHMMSS-final/
  commands.txt
  environment.txt
  git-status-before.txt
  git-status-after.txt
  test-output.txt
  build-output.txt              # 有构建时
  artifact-sha256.txt           # 有 HAR/HAP/package 时
  source-lock.txt               # 有外部来源时
  device-output.txt             # 有设备批次时
  cleanup.txt                   # 有进程/设备/临时配置时
  review.md
```

`review.md` 必须分别写：代码完成、主机测试、构建、签名、安装、设备运行、Provider/费用、清理和仍未完成事项。没有执行的阶段写 `not run`，不能省略。

临时源码 clone、论文 PDF、下载归档、模型、数据、venv、cache 和凭据不得作为默认 Git 交付。只提交来源 URL、固定 identity、必要 license、摘要和可复验脚本；删除本轮临时目录前先验证其绝对路径位于预期工作区。

## 9. 提交给验收 Agent 的固定格式

实施 Agent 每门完成后提交以下内容：

```text
Task: TNN / milestone
Branch: codex/...
Commit: <40-hex>
Base commit: <40-hex>

Changed files:
- ...

Validation actually run:
- command -> exact result

Artifacts:
- path, bytes, SHA-256

Evidence:
- artifacts/...

Not run / not proven:
- ...

Approvals used:
- exact approved scope, or none

Pre-existing worktree differences preserved:
- yes/no, exact list
```

不要只说“测试通过”或“已完成”。没有完整 commit、证据路径和事实边界的交付直接退回。

## 10. 验收 Agent 的职责

验收 Agent 对每个提交先只读核对 workspace、branch、HEAD/upstream、适用 AGENTS/skill、变更范围、六个既有差异和证据，再决定最低复验范围。

验收只给三种结论：

- `ACCEPTED`：实现、证据和边界均满足本任务书，可作为后续基线。
- `REJECTED`：列出具体文件/行、失败证据和必须由实施 Agent 修正的项目。
- `BLOCKED`：缺少明确外部输入或授权，且实现侧已经完成所有不依赖该输入的工作。

验收 Agent 不得把 review 变成继续开发。发现缺陷时先退回实施 Agent；只有项目所有者明确重新分配实现工作，验收 Agent 才修改源码。验收通过也不自动授权合并、tag、release、签名、安装、设备、凭据或付费调用。

## 11. 当前可立即领取的任务

接手 Agent 现在从 **T51** 开始。T51 通过验收后依次做 T52、T53；随后可以推进 T56、T57、T60、T61 和 T63 的无外部副作用部分。

T49、T54 保持暂停。T55、T58、T59、T62、T64 的真实外部批次以及 T65 的 tag/release 不得自行执行。
