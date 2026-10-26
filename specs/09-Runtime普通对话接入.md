# 09 Runtime 普通对话接入

> 状态：v0.1 已实现待验收；用户已确认四项主要模拟器交互符合预期；2026-10-26 后端增加显式同意的 PERSONAL 知识库回答（host 150/150、知识库统一宿主 182/182、完整知识库宿主 309/309、未签名构建 207 任务通过），模拟器冒烟已归档；当前页面仍为仅本机检索、待前端按契约接入。
> 优先级：先验证 UX → Runtime → 模型的最小真实链路。
> 负责人：UX 应用接入；Agent / 平台共同审核。
> 最后更新：2026-10-26。
> 授权依据：用户确认“按照你的建议推进”，本轮完成普通对话装配及首页接线；不开放工具调用。

## 1. 目标与范围

2026-10-24 后续扩展：真实搜索作为独立模式接入，见 [spec 03 §6.11](03-联网搜索.md)。搜索后的回答复用模型适配器并注入裁剪后的来源上下文；本 spec 的普通对话路径仍不调用搜索或读取 RAG，以下“不开放工具”限定于普通对话。

- 首页可明确选择真实普通对话，经过应用服务和生产 Runtime 请求既有 DeepSeek Provider。
- 一次发送对应一次模型调用，支持等待、成功、失败、取消、主动停止、离开助手页和退后台中止。
- 日程与搜索保留原有 Mock。真实对话不自动回退为 Mock，不读取知识库，不连接搜索 MCP，不修改上游公共契约。
- 本轮为 debug 验证入口，非目标包括多轮历史上下文、真实搜索、工具授权、历史对话列表、跨进程继续执行及真实账单获取。

## 2. 用户流程

1. 在助手首页点击“清空对话并配置真实模型”。清空的是当前页面消息和输入，既有本机执行记录不删除。
2. 阅读数据发送范围与请求限制，在设备内输入 Key，点击“同意上述范围并启用”。启用仅打开专用加密库并装配 Runtime，不验证 Key、不发送模型请求。
3. 输入公开问题或填入“提问样例”，点击发送。页面显示等待模型回答；每次仅发送当前问题和固定系统提示，不携带之前的对话。
4. 模型响应经过协议与结果校验、持久化后显示，并标明真实对话。失败保持可理解的提示，不显示供应商原始错误正文，不自动重试。
5. 用户可取消回答、停止会话或切回演示。离开助手页、退后台会停止会话并清除凭据；回来后需要重新手动启用。

## 3. 页面事项

- `Index.ets` 只调用 `RuntimeChatService.session`，不直接调用模型或 RDB。
- `RuntimeChatSetup` 提供密码输入、粘贴及明确启用按钮；输入提交后清空，后台状态变更和组件消失同样清空。
- `RuntimeChatSession` 映射任务事件和终态：先订阅事件再读取快照，处理订阅同步回放、订阅迟到、重复事件及提交途中取消。
- 真实模式下禁用搜索按钮；日程演示场景不能应用到真实任务。未就绪时发送会提示先配置，不调用 Mock。
- 请求中禁止重复发送、新对话和模式切换，保留取消与停止按钮。切页时主动停止，旧结果不能污染之后的任务。
- 返回前台不自动请求、不自动恢复；会话清理失败显示阻断状态。取消不代表供应商没有处理或没有计费。

## 4. 业务与 Agent 事项

链路：`Index → RuntimeChatSession → ShuviRuntimeController → AgentApplicationBackend → ProductionAgentRuntime → ChatModelAdapter → GenericModelProvider → DeepSeekModelTransport`。

- `ChatRuntimeFactory` 与原 `RuntimeStartupFactory` 分开。原启动检查继续禁止任务，不要求其连通搜索服务才能使用普通对话。
- `ChatPlanner` 是应用针对单轮问答的确定性路由：只生成一个 `LLM` 回答步骤。回答来自真实 Provider，不使用固定样例；不调用语义搜索规划器或子智能体。
- `ChatModelAdapter` 只接受固定 LLM 步骤，工具准备端口拒绝所有工具。模型输出不能变更流程或扩大执行权限。
- 使用已确认的 `deepseek-flash` / `DeepSeek-V4.1-Flash-1017`，非思考模式。官方模型与价格于 2026-10-24 再核对：[DeepSeek 模型与价格](https://api-docs.deepseek.com/quick_start/pricing/)。复用已有估价快照，核对日期不作为供应商价格生效日期。
- 每次任务输入上限 500 个 UTF-16 字符、输出上限 1024 tokens；请求 30 秒、页面绝对等待 45 秒，超时关闭会话。每次启用至多执行 10 次模型请求，失败请求也占次数；无自动重试、重规划或工具预算。
- USD 0.01 是单次请求的本地**估算准入上限**，不是供应商扣费硬上限。按 8192 输入 tokens 和 1024 输出 tokens、峰时缓存未命中价格保守检查；保留实际返回的 token 用量，不显示或入账 `GenericModelProvider.settledCostMicros` 为实际扣款。不替代供应商账单，亦非账户跨会话总预算。

### 4.1 专用执行记录

现有 `RuntimeExecutionRecoveryBridge` 的结果入口要求工具操作绑定，不能直接拿来保存没有工具 invocation 的 LLM 步骤。本轮在应用层增加 `ChatExecutionStore`，实现原有持久化端口，隔离普通对话记录，未修改上游工具恢复/待核账契约。

- 专用库 `shuvi_chat_execution_v1.db`，schema `shuvi-chat-1.0`，复用已有加密 RDB 配置和 `RdbSnapshotBackend`。
- 派发前通过 CAS 原子保存 Runtime checkpoint 与 dispatch 绑定；失败不请求模型。模型结果先保存，再推进 Runtime 完成状态，持久化失败不能显示成功。
- 结果绑定 task / step / dispatch，完全相同的回放不重复保存，冲突拒绝覆盖；加载校验 schema、摘要、checkpoint 和结果结构。
- checkpoint 保留用户问题和事件，outcome 保存回答、token 用量或固定错误分类；不保存 Key、不保存供应商原始错误正文。
- 进程重启只校验并保留记录，不恢复旧任务、不重新调用模型；发生在模型完成与最终 checkpoint 保存之间的中断仍保留结果证据，本版未提供恢复展示界面。
- 最多保留 128 个任务，快照 JSON 上限 800000 字符（还受摘要字节上限约束）；达到上限明确拒绝，不自动清理或覆盖用户数据。后续需单独设计归档/历史界面，不能当成无限历史存储。

## 5. 平台能力与权限

- 沿用已有 INTERNET 权限、HTTPS Transport、原生 UTF-8 / UUID / SHA-256 和加密 RDB，无新增依赖、权限、云服务或密钥存储方式。
- SDK / 系统能力依据见 [spec 08 第 5 节](08-设备直连模型与连接验证.md#5-平台能力与权限)。本轮不新增系统 API，复用已有 API 26 适配器。
- 普通对话控制器由 Ability 管理，与只读启动检查分开；独立库避免两种入口共用运行记录。
- 当前只构建 HarmonyOS API 26 包。OpenHarmony 设备和版本仍未明确，不能据此宣称真机或跨系统验收通过。

## 6. 验收方式

| 路径 | 用例 | 预期 |
|---|---|---|
| 正常 | 启用、公开问题、连续两次提问、新对话 | 启用不请求；每次发送只调用一次模型；显示回答；不携带历史 |
| 异常 | 请求中取消后再提问；停止；切页；后台；存储拒绝；迟到响应 | 结束等待；不自动重试；旧响应隔离；存储失败不显示成功 |
| 权限拒绝 | 不启用；空 Key；release 入口；尝试调用工具 | 不发送模型请求或拒绝越界；工具始终不可用 |
| 模型失败 | 401、429、截断响应、无效结果、超时 | 固定安全提示；不显示供应商正文，不伪造回答 |

宿主测试使用真实 Runtime、Provider、协议、对话存储与 UI 状态服务，网络和设备 RDB 由隔离替身提供，**不等同于真实模型或模拟器验收**。复现入口：`node entry/src/test/run-direct-model-tests.cjs`，需设置 `DEVECO_SDK_HOME`，经 `scripts/capture-test-log.sh` 归档。构建复现沿用 `.local/direct-model/verify.ps1 -Check build` 的本机 Hvigor `assembleHap --no-daemon`。

2026-10-24 自动验证结果：

| 检查 | 结果 | 证据 |
|---|---|---|
| 应用 host | 104/104，通过；包含新增普通对话 14 项，网络均为替身 | `.cache/test-logs/2026-10-24-runtime-chat-host-22861a2-7/`；详细日志 `.cache/direct-model-test-20261024-182114-364.log` |
| 产品构建 | API 26 `assembleHap --no-daemon` 通过，81 任务（35 执行、46 最新），未签名/安装 | `.cache/test-logs/2026-10-24-runtime-chat-build-22861a2-4/`；详细日志 `.cache/direct-model-build-20261024-182337-150.log` |
| 来源校验 | 固定来源及既有本地覆盖记录校验通过，本轮未修改导入模块 | `.cache/test-logs/2026-10-24-runtime-chat-imports-22861a2/` |
| 差异检查 | `git diff --check` 通过，未提交 Git | 本机命令结果 |

构建过程有一次停在 Hvigor 启动且无编译输出，已停止本轮进程后重试。最终命令显式设置 `NODE_HOME=C:\Program Files\Huawei\DevEco Studio\tools\node`，未修改全局环境，也未清缓存/改签名。环境没有 `arkts_check` / `build_project`，采用既有本机 Hvigor 备选入口；ArkTS 编译实际执行通过。无须将这次构建停滞归因于代码错误。

上述自动验证未运行模拟器、真机或真实计费请求；随后用户执行的模拟器检查反馈见第 6.2 节，不代表实际账单核验。原有全量 lint/CI 阻塞仍单独记录。ArkTS 实现沿用已认可的 `openharmony-development` 技能路由（核心 WORKFLOW、状态、表单和 Windows DevEco 构建），以本工程 API 26 编译器为准。

### 6.1 人工验收复现步骤

1. 在 DevEco Studio 构建安装新 debug 包，进入助手首页，确认配置入口和真实/演示标识可见。
2. 输入设备内的 Key 并启用，确认显示就绪且尚无模型请求；不用启动 Node 搜索服务，也不用 HDC 8787 转发。
3. 填入“提问样例”，点击发送，确认等待结束并出现实际回答。不要把 Key 或含 Key 的截图发到聊天。
4. 后续分别验证取消后再提问、离开助手页、后台返回与失败提示；最大字体检查独立记录。
5. 使用现有日志捕获脚本记录设备标识、包身份和脱敏状态；仅有人工口头反馈不补记为完整证据。

### 6.2 模拟器人工反馈（2026-10-24）

用户按对话中的逐项步骤执行，并分别回复“结果符合预期”：

| 检查 | 用户确认范围 |
|---|---|
| 正常提问 | 启用真实模型后发送提问样例，等待结束并显示回答，输入恢复可用 |
| 取消后再提问 | 等待期间取消，结束等待，不追加被取消请求的迟到回答；再次发送“你好”正常收到回答 |
| 后台返回 | 请求期间按 Home 进入后台后返回，不持续等待、不追加旧回答；会话停止，需要重新启用，不自动重发 |
| 鉴权失败与恢复 | 临时填写 `invalid-test-key` 后提问，明确提示失败并结束等待，不显示虚假回答；停止后换回正确凭据，重新启用并提问恢复正常 |

以上是用户人工反馈，AI 未操作设备或读取凭据。本轮尚未提供设备日志、系统版本、安装包身份及与测试对应的工作区指纹，因此依照 [协作约定第 7.0 节](../docs/01-协作与工程约定.md#70-测试日志必须落盘每次测试)，不将反馈标记为已归档的正式设备验收，状态保持“已实现待验收”。不能从页面表现推断凭据内存已清零、远端未计费或所有异常路径均通过。

后续按 `scripts/capture-test-log.sh <scope> [日志窗口] [设备]` 为实际复验留档，再补充对应路径、复现命令与设备/包身份；不以事后生成日志替代此前测试证据。暂不重复扩大测试范围。离开助手页、最大字体、读屏及 OpenHarmony 真机仍单独待验收。

## 7. 已知限制与未覆盖项

- 单轮普通对话，历史只在当前界面展示，不会发给模型；尚无 token 流式渲染、真实来源或知识库引用。
- Key 仅本次会话可用；异常关闭和进程被回收无法保证远端取消，失败不能推断免费。
- 暂不展示细分错误码和恢复历史；存储异常时可能需要关闭/重启排查，禁止清库“解决”。
- 四项主要模拟器交互已有用户反馈，设备日志尚未归档；实际 HTTP 与持久化的设备级取证、离开助手页、最大字体、读屏及 OpenHarmony 真机仍待验收。

## 8. 本机知识库回答后端增量（2026-10-26）

> 归属：本节只记录后端/应用服务实现。`RuntimeKnowledgePanel.ets` 与 `Index.ets` 的页面实现由前端负责；当前页面仍使用 `startLocal()` 的仅本机检索路径，尚未接入 Key、同意按钮与模型回答。前端契约见第 9 节。

- 本机工具链路为 `RuntimeKnowledgeSession → ProductionAgentRuntime → native://shuvi/knowledge.search.local → KnowledgeRuntimeSearchAdapter → UnifiedQueryRepository`，模型不决定是否检索。
- 工具只接受 PERSONAL 任务、零费用、无权限、无网络、低风险、无副作用和单次派发；严格匹配后由应用自动批准本机读取。授权、checkpoint、调用和结果通过独立加密库 `shuvi_knowledge_runtime_v1.db` 持久化，结果一致时零金额提交，不伪造账单。
- 检索只使用完整的本机 scope，默认排除归档，仅返回当前可见的 Direct 正文/OCR 命中；最多 5 条、每条 800 字符、总计 3200 字符。每条引用携带稳定 `evidenceId`、document generation、标题、类型与证据路径；Tag-only 命中不得进入引用。
- 后端已实现完整的“两段任务”接口：用户明确同意并调用 `start(toolFactory, answerFactory, key, true)` 后，任务 A 本机检索，成功并冻结证据快照后才提交任务 B PERSONAL 模型任务。启用本身不发送模型请求；`consent=false` 不启动会话。当前页面未接入这段 UI。
- 只有任务 A 成功并通过 `parseKnowledgeToolResult` 校验后才冻结证据快照；空结果、Tag-only、scope 不完整、归档/删除/失效 generation 或结果校验失败均不调用模型。
- 任务 B 使用独立 `KnowledgeAnswerRuntimeFactory` / `KnowledgeAnswerPlanner` / `KnowledgeAnswerModelAdapter`，隐私级别为 PERSONAL，禁用工具、搜索、日历、MCP 和自动重试；普通 `ChatRuntimeAssembly` 仍只接受 PUBLIC，未被放宽。
- 发送范围仅为本次问题、引用编号、截短标题和截短正文/OCR 片段（最多 5 条、每条 800 字符、总计 3200 字符）；不发送完整文档、文件路径、数据库标识、sourceHash、generation、evidenceId 或其他内部元数据。数据目的地为 DeepSeek API，处理、留存与费用以供应商规则为准。
- 模型输出必须为严格 JSON：`{"answer":"...","citations":[1]}`；回答非空且有界，所有 `[n]` 必须在 1..N、至少一个有效引用、引用片段非空；无效引用、空引用或 Markdown 包裹均不显示为成功。成功结果先写入独立加密库 `shuvi_knowledge_answer_v1.db` 再显示；失败/取消保留本机引用，可“仅重试回答”，重试复用同一证据快照，不重新检索。
- 如果模型明确回答“资料中没有足够依据”且 `citations=[]`，后端映射为 `insufficient` 非成功状态：保留本机引用、不伪造引用、不提供“仅重试回答”。系统提示禁止用方括号表示年份、步骤或范围。
- `recordOutcome` 结果写入被拒或抛错时，通过工厂回调立即结束检索/回答并保留引用，不再等待 120 秒 watchdog；派发前 checkpoint 拒写仍可能需要手动停止。
- 兼容入口 `startLocal(toolFactory)` 保留当前页面的仅本机检索行为：不需要 Key、不启动模型会话、不调用 DeepSeek。
- 2026-10-26 评审修复：仅本机/空闲停止不再误报“模型请求可能计费”；启动失败且关闭失败时保留 BLOCKED 的资源关闭提示；启动失败不再清空上一轮引用/回答。另修复知识库后端写入读回在并发归档时可能返回成功、工具结果解析再次校验 3200 字符总量、初始化失败后无法重试、关闭失败提前清 opened、取消等待期间完成任务仍派发模型、提交后订阅失败不取消孤儿任务、OCR 多 chunk 重复 evidenceId；新增 `onOutcomeRejected` 立即拒写反馈、`insufficient` 非成功状态和“禁止方括号年份/范围”提示；新增对应回归用例。
- 2026-10-26 自动复验：Runtime/模型套件 150/150，知识库统一宿主 182/182，完整知识库宿主 309/309，来源校验通过；HAP/HAR 207 个任务（129 执行、78 最新）通过，未签名。证据：`.cache/test-logs/2026-10-26-knowledge-answer-direct-host-final8-42101a3/`、`.cache/test-logs/2026-10-26-knowledge-answer-unified-host-final8-42101a3/`、`.cache/test-logs/2026-10-26-knowledge-answer-full-host-final8-42101a3/`、`.cache/test-logs/2026-10-26-knowledge-answer-build-final8-42101a3/`。一次归档构建 final3 以 exit 1 中断（167 任务，未作为证据），随后 final4-final8 均 207 任务通过。以上仍是 host 与未签名构建证据，不等同于真机、OpenHarmony 或设备数据库验收。

### 8.1 模拟器冒烟（2026-10-26）

- 设备：`Pura 90 Pro`，`127.0.0.1:5555`，HarmonyOS `7.0.0 (26.0.0)`，API 26。
- 操作：本机临时签名并安装 debug 包；启动应用 → 进入真实功能 → 打开知识库 → 启用本机检索 → 填入知识样例并发送 → 停止会话。
- 结果：应用启动与页面切换无崩溃；本机知识库返回“没有直接正文命中”，页面显示“未调用模型”；未调用 DeepSeek，未使用真实 API Key；停止后会话/凭据清理。脱敏日志摘要 `fatal=0`、`crash=0`、`js_exception=0`，有 4 条系统 E 级日志（图形/属性相关），未导致失败。
- 评审修复后复查：重新安装最终构建，打开知识库显示“尚未启用本机知识库检索”，空结果不调用模型，停止后显示“未发送模型请求”，不再误报模型计费。证据：`.cache/test-logs/2026-10-26-device-smoke-final-42101a3/`、`.cache/test-logs/2026-10-26-device-smoke-final-logs-42101a3/`、`.cache/test-logs/2026-10-26-device-smoke-final-summary-42101a3/`；截图 `.cache/device-smoke/postfix-stopped.png`。
- 最终构建 final6 复查：启动、真实功能、知识库、启用本机检索、停止会话均正常；初始/就绪/停止文案符合预期；脱敏日志 `fatal=0`、`crash=0`、`js_exception=0`（有系统 E 级日志，未导致失败）。证据：`.cache/test-logs/2026-10-26-device-smoke-final6-42101a3/`、`.cache/test-logs/2026-10-26-device-smoke-final6-logs-42101a3/`、`.cache/test-logs/2026-10-26-device-smoke-final6-summary-42101a3/`；截图 `.cache/device-smoke/final6-stopped.png`。
- 最终构建 final8 复查（安装时间 19:07:25）：安装后强制停止并重启，启动 → 真实功能 → 知识库 → 启用本机检索 → 发送“休比是什么” → 停止；空命中显示“本机知识库没有直接正文命中；未调用模型”，停止显示“会话已停止；凭据已清除，已显示的引用保留；未发送模型请求”。应用 PID 日志 `fatal=0`、`crash=0`、`js_exception=0`、`error=0`；全缓冲区 7015 行中的 8 条系统 JS 异常均不属于应用。安装捕获 `run_cmd_exit=0`，其设备日志阶段因未显式指定 `DEVECOCLI_BIN` 以 127 结束，另以 `hdc hilog` 全缓冲脱敏摘要复核。证据：`.cache/test-logs/2026-10-26-device-smoke-final8-42101a3/`、`.cache/test-logs/2026-10-26-device-smoke-final8-logcheck-42101a3/`；截图 `.cache/device-smoke/final8-enabled.png`、`.cache/device-smoke/final8-result.png`、`.cache/device-smoke/final8-stopped.png`。
- 未覆盖：新的 Key/同意/两阶段模型回答 UI 尚未由前端接入；final8 模拟器冒烟只走 `startLocal()` 本机检索，没有真实模型请求、账单、模型引用或真机/OpenHarmony 验收。
- 证据：`.cache/test-logs/2026-10-26-device-smoke-42101a3/`、`.cache/test-logs/2026-10-26-device-smoke-logs-42101a3/`、`.cache/test-logs/2026-10-26-device-smoke-summary-42101a3/`；截图 `.cache/device-smoke/home.png`、`.cache/device-smoke/knowledge-empty.png`。
- 复现：`BUNDLE=com.example.shuvi RUN_CMD="bash scripts/dev-run.sh --emulator 'Pura 90 Pro' --product default --no-emulator" bash scripts/capture-test-log.sh device-smoke 30m 127.0.0.1:5555`。签名材料未入库，`build-profile.json5` 已恢复模板。

## 9. 前端交接契约

- 前端负责 `RuntimeKnowledgePanel.ets` 与 `Index.ets` 的页面/交互实现；后端负责 `RuntimeKnowledgeSession`、`KnowledgeAnswer*`、测试与构建。
- 完整接口、视图字段、阶段、同意文案、数据范围、失败/重试与生命周期约定见 [知识库回答 UI 交接契约](../docs/integration/知识库回答UI交接契约.md)。
- 当前页面仍为 `startLocal()` 的仅本机检索；前端接入前不得声称页面已具备模型回答或设备验收。
