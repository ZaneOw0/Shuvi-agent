# 知识库回答 UI 交接契约

> 状态：检索优先 RAG 已接入 debug 首页；2026-10-27 修复检索结果被丢弃并补齐面板、准备时机、检索历史与调用上限，同日在模拟器上以真实 SiliconFlow / DeepSeek 跑通端到端（见第 7 节）；完整落盘的设备证据、断网重试、最大字体/读屏与真机待验收。
> 归属：`RuntimeAssistantCoordinator` 负责同一 DeepSeek Key 下的普通聊天与 RAG 会话；知识库仍负责 Embedding 配置、问题向量化、本机 KNN 和证据生命周期。
> 当前页面状态：普通聊天输入一次 DeepSeek Key；点击现有“知识库”开关即检查并启用 RAG，不新增 Key 输入或逐问题确认控件。2026-10-27 面板改为“回答 + 来源胶囊 + 可折叠原文”、阶段合为一行，并调整证据排序（见第 4、6 节），宿主与模拟器自测通过，待开发者人工验收。

## 1. 边界

- 前端通过 `RuntimeAssistantCoordinator` 启停组合会话，通过 `RuntimeKnowledgeService.session.send(...)` 发送 RAG 问题；不直接调用 Provider、Runtime、RDB 或知识库仓储。
- 前端不记录 API Key；只有用户勾选“记住 Key”时，`DeepSeekKeyField` 才把它存入本机系统 Asset Store（`DEVICE_UNLOCKED`、不同步、可删除，见 spec 09 §8.5）。每次启用仍需用户点击；Key 以 `Uint8Array` 传入后端，后端消费并清零。
- 用户点击现有“知识库”开关即表示允许当前会话按既有 Embedding 设置处理问题；关闭开关立即撤销新问题的 RAG 使用权，但保留普通聊天会话。
- Embedding Provider 的 Key 与 DeepSeek Key 是两套凭据：前者继续由知识库设置和 AssetStore 管理，后者在会话中只存在内存，用户也可选择把它记在本机 Asset Store（独立别名，与嵌入 Key 互不共用）。
- 聊天 RAG 的问题与片段只显示在聊天面板、回答写入 `shuvi_knowledge_answer_v1.db`，**不写入知识库页面的检索历史**（`EphemeralQueryHistory`）。
- 后端不负责页面布局、视觉样式、动画、无障碍朗读和截图验收；这些由前端负责。

## 2. 后端入口

```ts
await RuntimeAssistantCoordinator.start(context, DEBUG, keyBytes);
const readiness = await RuntimeAssistantCoordinator.enableKnowledge();
if (readiness.ready) {
  await RuntimeKnowledgeService.session.send(question);
}
```

- `RuntimeAssistantCoordinator.start(...)` 在内存中生成两份隔离副本：一份给助手聊天（`ChatPurpose.ASSISTANT` / PERSONAL，可生成日程草稿，写入需确认后的原生日历工具），一份给知识库回答（PERSONAL）；调用方缓冲区和临时副本都会清零。它只准备 PERSONAL 回答会话，**不打开本机知识库**，因此启动普通聊天不会触发资料恢复或处理队列。
- `enableKnowledge()` 首次调用时打开本机知识库（获取 `KnowledgeAssembly` 租约），再做本机就绪检查；不发送问题、不调用 DeepSeek，也不调用 Embedding Provider。打开失败返回 `RagOpenFailed`，普通聊天不受影响，下次开启会重试；打开期间重复调用返回 `RagOpening`。
- `send(query)` 固定先加载本机正文/标签，再对当前问题调用一次已配置的 Embedding Provider，随后执行本机 KNN；只有得到可引用片段后才提交 PERSONAL DeepSeek 回答。
- `disableKnowledge()` 取消当前 RAG 并撤销新问题许可，但不会停止普通聊天或清除其 Key，知识库租约保留以便再次开启；`stop()`、退后台、页面销毁才关闭两条会话、释放租约并清除凭据。
- 旧兼容入口 `start(toolFactory, answerFactory, key, consent)` / `startLocal(toolFactory)`（Runtime 工具 `native://shuvi/knowledge.search.local`）仍在代码中，但当前页面已无调用方；是否删除待团队评审，新接入不要使用。

其他方法：

| 方法 | 作用 |
|---|---|
| `send(query: string): Promise<boolean>` | 新问题。依次执行本机检索和模型回答；同一时间只允许一个任务。会话已用完回答次数时在检索前返回 `false`（不调用 Embedding）。 |
| `retryAnswer(): Promise<void>` | 仅重试模型回答，复用同一证据快照，不重新检索；计入会话次数，用完后拒绝。 |
| `cancelCurrent(): Promise<void>` | 取消当前检索或模型任务；保留已显示的引用。 |
| `activateRag(): Promise<KnowledgeRagReadiness>` | 首次调用时打开本机知识库，再检查 Provider、检测、设置、向量空间和当前目标；成功后允许 RAG 问题。 |
| `deactivateRag(): Promise<void>` | 撤销 RAG 许可并取消当前 RAG，不关闭普通聊天。 |
| `stop(): Promise<void>` | 停止 RAG 回答会话、释放知识库租约（若已打开）并清除凭据；已显示引用保留。打开知识库途中停止时，迟到的租约由 `activateRag` 在打开完成后释放。 |
| `clearConversation(): void` | 非忙碌时清空问题、回答和引用。 |
| `snapshot(): RuntimeKnowledgeView` | 读取当前视图投影；不要直接读内部字段。 |
| `attach(listener)` / `detach()` | 订阅视图变化；页面离开时 `detach`，后台/销毁由 Ability 调用。 |

## 3. 视图字段与阶段

`RuntimeKnowledgeView`：

| 字段 | 含义 |
|---|---|
| `lifecycle` | `IDLE / STARTING / READY / STOPPING / STOPPED / FAILED / BLOCKED` |
| `busy` | 当前有检索或模型任务 |
| `stage` | `idle / starting / retrieving / answering / complete / empty / retrievalFailed / answerFailed / insufficient / stopped` |
| `message` | 后端给出的状态说明，可直接展示 |
| `query` | 本轮问题 |
| `answer` | 模型回答；旧 `startLocal` 入口下是确定性的引用计数提示；`insufficient` 时为空 |
| `answerSource` | `answer` 的来源：`deepseek`（模型整理回答）、`local`（旧入口的本机计数提示）或空；只有 `deepseek` 才加“DeepSeek 整理回答”标注 |
| `citations` | 本机原始引用，含标题、片段、类型、证据路径；不得把 `evidenceId`/`documentId`/`generation` 显示给用户 |
| `consent` | 后端当前是否持有本次明确同意；旧 `startLocal` 入口为 `false` |
| `clearEpoch` | 每次启动/停止递增；前端应在变化时清空 Key 输入框 |
| `requestCount` / `maxRequests` | 本次 RAG 会话已派发的 DeepSeek 回答次数（含重试）与上限 10；只有新会话才重置 |

阶段语义：

- `retrieving`：本机检索中，尚未调用模型。
- `answering`：本机检索已完成并固定证据，模型调用中。
- `complete`：本机检索与模型回答均完成；`startLocal` 下仅本机检索完成。
- `empty`：本机无直接正文命中，未调用模型。
- `retrievalFailed`：本机检索失败或结果/证据无法安全固定，未调用模型。
- `answerFailed`：本机引用已保留，模型失败或取消；可显示“仅重试回答”。
- `insufficient`：模型按提示回答“资料中没有足够依据”且无引用；本机引用保留，显示为非成功结论，不提供“仅重试回答”。
- `stopped`：会话已停止，凭据已清除；引用/回答可保留展示。

## 4. 页面必须覆盖的内容

> 2026-10-27 起 `RuntimeKnowledgePanel` 已实现第 4、6、7、8、12 项，阶段文案与重试条件在 `RuntimeKnowledgePresentation.ets`；同日模拟器上已看到第 4、6、8、12 项的实际显示，第 3、10 项由用户确认（见第 7 节）；第 7 项“仅重试回答”、最大字体与读屏仍待设备验收。

1. **Key 输入**：复用普通聊天现有密码输入；不增加第二个 DeepSeek Key 输入框。
2. **知识库开关即当前会话许可**：点击现有开关后允许以下固定范围，不再逐问题弹确认：
   - 发送目的地为 DeepSeek API。
   - 发送本次问题。
   - 最多发送 5 条知识片段。
   - 每条最多 800 字符，总计最多 3200 字符。
   - 不发送完整文档、文件路径、数据库标识、`sourceHash`、`generation`、`evidenceId` 或其他内部元数据。
   - DeepSeek 的实际处理、留存和费用以供应商规则为准。
3. **启用不发送请求**：开关只打开本机知识库并做本机状态检查，打开期间按钮显示“准备中…”；点击发送后才调用问题 Embedding，取得证据后才调用 DeepSeek。
4. **两阶段状态**：分别显示“本机检索”和“模型回答”的当前阶段（2026-10-27 起合为一行“本机检索 · … → 模型回答 · …”，两段文字与 id 仍各自独立）。
5. **原始引用常驻**：只要本轮有引用，无论模型成功、失败、取消或停止，都保留编号引用供用户核对。2026-10-27 起：有 DeepSeek 回答时，回答下方常驻编号来源胶囊（“[n] 片段开头…”），片段原文折叠在“查看 N 条来源原文”中；没有模型回答（失败、资料不足、停止）时原文默认展开。
6. **回答标识**：模型回答必须标注“DeepSeek 整理回答（依据下方片段，不是原始资料）”，不能与原始片段混同。
7. **失败与重试**：`stage=answerFailed` 且会话仍有回答次数时显示“仅重试回答”；重试不触发检索。
8. **资料不足**：`stage=insufficient` 时显示“资料中没有足够依据”，保留本机引用，不标记为成功，不显示“仅重试回答”。
9. **停止/取消**：忙碌时取消当前任务；空闲时关闭知识库开关即可返回同一普通聊天会话，不要求重新输入 Key。
10. **后台/切页**：页面离开、切换标签或 Ability 退后台时停止会话；返回前台不自动重试或恢复旧任务。
11. **无障碍**：Key 输入、知识库开关、取消/重试按钮均需可读标签和最小 44vp 点击区域。
12. **次数与恢复**：显示“本次会话 DeepSeek 回答 n/10 次（含重试）”；会话停止或用完次数后，说明恢复方式是“停止真实对话后重新输入 Key 启用”；被拒绝的问题放回输入框，不静默丢失。

## 5. 后端保证

- 助手聊天与知识库回答隔离：助手聊天（`ChatPurpose.ASSISTANT` / PERSONAL）不承载知识库片段，日程写入另需用户确认后的原生日历工具；知识库回答使用独立 PERSONAL profile、Planner、Adapter 和加密执行库 `shuvi_knowledge_answer_v1.db`。
- 每个 RAG 问题使用独立 `KnowledgeQuerySession`，不会取消知识库页面的查询；检索顺序固定为本机 Direct/Tag → 当前问题 Embedding → 本机 KNN → 合并去重。
- 空结果、Tag-only、失效证据、scope 不完整、结果校验失败：不调用模型。
- 模型输出严格 JSON，校验 `[1]..[N]`、至少一个有效引用、无重复/越界/未声明编号；持久化成功后才显示成功。
- 无引用且明确说明“资料中没有足够依据”的输出映射为 `insufficient` 非成功状态，不伪造引用、不标记成功。
- 模型失败/取消：保留本机引用，不伪造回答，不显示供应商原始错误正文；仅允许重试回答。
- `recordOutcome` 结果写入被拒或抛错时，通过工厂回调立即结束检索/回答并保留引用，不再等待 watchdog。
- 自动恢复/重发被禁用；重试只能由用户显式触发。
- 会话级回答次数在派发前检查：用完后新问题在检索前被拒（不调用 Embedding），重试同样被拒。
- 启动普通聊天不打开本机知识库；首次开启知识库才获取租约，停止会话时释放，打开途中停止也不会遗留租约。
- 聊天 RAG 使用不落盘的检索历史端口，不改变知识库页面的历史记录。
- Key 不进入提示词、数据库、日志或测试数据；停止/后台/detach 关闭凭据。

## 6. 已知限制

- 已在模拟器上用真实 Embedding/DeepSeek 凭据跑通端到端（第 7 节），但设备日志未完整落盘、部分项仅用户确认；真机未验收。
- 每个 RAG 会话最多 10 次 DeepSeek 回答（含失败重试）；用完后新问题与重试在检索前被拒，需要停止真实对话并重新输入 Key。次数是会话级，不是账户级预算。
- 问题发往 Embedding Provider 这一步在应用层执行，不经过 Agent Runtime，因此没有 Runtime 的授权记录、执行日志和次数上限；只受知识库开关、本机就绪检查与知识库自身的费用/授权约束。是否需要补 ADR 或改回 Runtime 待评审。
- 关闭知识库开关后知识库租约保留到会话停止，以便再次开启。
- 回答执行库最多保留 128 个任务；达到上限后新任务失败关闭，不自动清理或覆盖用户记录；后续需要保留/清理方案。
- `recordOutcome` 拒写会立即结束检索/回答；`saveCheckpoint`/`beforeDispatch` 拒写仍可能等待最长 120 秒 watchdog，后续可补同类回调。
- 无有效引用的“资料中没有足够依据”映射为 `insufficient` 非成功状态；成功答案仍必须至少一个有效引用。
- 带数字的方括号（例如年份 `[2026]`）会被当作引用并因越界拒绝；这是严格 fail-closed 的已知取舍。
- 旧工具路径的本机工具执行库 `shuvi_knowledge_runtime_v1.db` 没有容量上限/保留策略；该路径当前无调用方。
- 宿主测试使用替身网络与数据库，不等同于设备验收。
- 仍需验证：断网等失败后的“仅重试回答”（模拟器无法单独拦截 DeepSeek）、Key 清空的设备级取证、最大字体与读屏，以及真机上的全部项。两阶段展示、资料不足、次数上限与后台停止已有模拟器结果（第 7 节）。
- 知识库切分会把 Markdown 标题切成独立片段（模拟器验收 R-01 中 5 条有 3 条只有标题），切分本身属知识库既有行为。2026-10-27 起 `KnowledgeSemanticRuntimeSearchAdapter` 分两轮取证：先取正文，再用剩余名额取“像标题”的片段（全部为 Markdown 标题行、与文档标题相同，或 40 字内不含标点的单行），只降序不丢弃；同一问题在模拟器上重问时前 4 条均为正文（第 5 条未截图）。启发式可能把很短的正文句也降序，正文不足 5 条时标题片段仍会占位。
- 不得把后端 host 测试或未签名构建宣称为前端设备验收。

## 7. 验证依据

2026-10-27 复验（`feat/agent-grounded-qa` `1b9cb25`…`45f2e60`，Windows 本机 DevEco SDK）：`entry/src/test/run-direct-model-tests.cjs` 187/187；`entry/src/test/run-host-tests.cjs` 309/309；未签名 `assembleHap --no-daemon` 通过（0 ERROR）。新增用例直接组合真实 `KnowledgeRagSessionAdapter`、`KnowledgeSemanticRuntimeSearchAdapter` 与 `KnowledgeQuerySession`，不再两侧都用替身。证据目录见 [spec 09 §8.3](../../specs/09-Runtime普通对话接入.md)。

历史记录：2026-10-26 `entry/src/test/run-direct-model-tests.cjs` 175/175、`run-host-tests.cjs` 309/309、未签名 `entry:assembleHap` 81 任务成功；该轮测试未覆盖真实组合，检索结果被丢弃的问题未被发现。

以上均是 host 与构建证据，不等同于设备端真实 Provider 验收。

2026-10-27 模拟器真实 Provider 验收（`710d1c0` 未签名 debug 包，`Pura 90 Pro` / `127.0.0.1:5555`，硅基流动 `BAAI/bge-m3` + DeepSeek）：命中题回答正确并带引用、两阶段与 `n/10` 显示正确；无依据题为 `insufficient` 非成功；第 11 题在检索前被拒；退后台需重新输入 Key；知识库搜索历史不含聊天问题。11 项中 10 项符合预期（5 项有截图或日志、5 项仅用户确认），断网重试未验证；设备日志为即时输出转录，未完整落盘。逐项结果、发现与证据见 [spec 09 §8.4](../../specs/09-Runtime普通对话接入.md)。
