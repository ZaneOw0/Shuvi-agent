# 知识库回答 UI 交接契约

> 状态：后端已实现待前端接入。
> 归属：本文描述的后端接口与状态由 Agent/应用服务维护；`RuntimeKnowledgePanel.ets` 与 `Index.ets` 的页面实现由前端负责。
> 当前页面状态：仍使用 `RuntimeKnowledgeSession.startLocal()` 的“仅本机检索”路径，不发送外部模型。前端接入本文的完整流程后，才会出现 Key 输入、同意按钮和 DeepSeek 回答。

## 1. 边界

- 前端只调用 `RuntimeKnowledgeService.session` 暴露的方法，不直接调用 Provider、Runtime、RDB、知识库仓储或 `knowledgeAnswerRuntimeFactory` 内部实现。
- 前端不读取、不记录、不持久化 API Key；Key 以 `Uint8Array` 传入后端，后端消费并清零。
- 前端不自行判断“是否同意外发”；必须把用户的明确同意作为 `start(..., consent=true)` 的前置条件。
- 后端不负责页面布局、视觉样式、动画、无障碍朗读和截图验收；这些由前端负责。

## 2. 后端入口

```ts
const session = RuntimeKnowledgeService.session;
session.start(
  knowledgeRuntimeFactory(context, DEBUG, (taskId) => session.toolOutcomeRejected(taskId)),
  knowledgeAnswerRuntimeFactory(context, DEBUG, session.answerContext,
    (taskId) => session.answerOutcomeRejected(taskId)),
  keyBytes,
  true
);
```

- `keyBytes`：`Uint8Array`，仅本次会话；后端 `ShuviRuntimeSession.start` 会消费并清零调用方的缓冲区。
- `consent`：只有用户明确勾选并点击同意按钮后才传 `true`；传 `false` 时后端不启动任何会话。
- 启用本身不发送模型请求；只有 `send(query)` 会先执行本机检索，再在检索成功后提交 PERSONAL 模型任务。
- 两个 `onOutcomeRejected` 回调必须按上面的方式接到会话；结果写入失败时后端会立即结束检索/回答并保留本机引用。不要省略回调。
- 旧页面兼容入口：`startLocal(knowledgeRuntimeFactory(context, DEBUG, (taskId) => session.toolOutcomeRejected(taskId)))`，仅本机检索，不启动模型会话，不需要 Key。

其他方法：

| 方法 | 作用 |
|---|---|
| `send(query: string): Promise<boolean>` | 新问题。依次执行本机检索和模型回答；同一时间只允许一个任务。 |
| `retryAnswer(): Promise<void>` | 仅重试模型回答，复用同一证据快照，不重新检索。 |
| `cancelCurrent(): Promise<void>` | 取消当前检索或模型任务；保留已显示的引用。 |
| `stop(): Promise<void>` | 停止两个会话、清除同意状态与凭据；已显示的引用保留。 |
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
| `answer` | 模型回答；`startLocal` 兼容模式下是确定性的引用计数提示；`insufficient` 时为空 |
| `citations` | 本机原始引用，含标题、片段、类型、证据路径；不得把 `evidenceId`/`documentId`/`generation` 显示给用户 |
| `consent` | 后端当前是否持有本次明确同意；`startLocal` 为 `false` |
| `clearEpoch` | 每次启动/停止递增；前端应在变化时清空 Key 输入框 |

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

1. **Key 输入**：密码输入、关闭自动填充/预览、组件消失时清空本地字符串。
2. **明确同意**：在启用前完整展示以下范围，并提供复选框 + 明确按钮“同意上述范围并启用”：
   - 发送目的地为 DeepSeek API。
   - 发送本次问题。
   - 最多发送 5 条知识片段。
   - 每条最多 800 字符，总计最多 3200 字符。
   - 不发送完整文档、文件路径、数据库标识、`sourceHash`、`generation`、`evidenceId` 或其他内部元数据。
   - DeepSeek 的实际处理、留存和费用以供应商规则为准。
3. **启用不发送模型请求**：按钮文案和后端行为一致。
4. **两阶段状态**：分别显示“本机检索”和“模型回答”的当前阶段。
5. **原始引用常驻**：只要本轮有引用，无论模型成功、失败、取消或停止，都保留编号引用供用户核对。
6. **回答标识**：模型回答必须标注“DeepSeek 整理回答（依据下方片段，不是原始资料）”，不能与原始片段混同。
7. **失败与重试**：`stage=answerFailed` 时显示“仅重试回答”；重试不触发检索。
8. **资料不足**：`stage=insufficient` 时显示“资料中没有足够依据”，保留本机引用，不标记为成功，不显示“仅重试回答”。
9. **停止/取消**：忙碌时提供取消当前任务；空闲时提供停止会话；停止后必须重新输入 Key 并重新同意才能再次启用。
10. **后台/切页**：页面离开、切换标签或 Ability 退后台时停止会话；返回前台不自动重试或恢复旧任务。
11. **无障碍**：Key 输入、同意复选框、启用/取消/重试按钮均需可读标签和最小 44vp 点击区域。

## 5. 后端保证

- 普通 PUBLIC 对话未被放宽：普通聊天仍只接受 PUBLIC；知识库回答使用独立 PERSONAL profile、Planner、Adapter 和加密执行库 `shuvi_knowledge_answer_v1.db`。
- 空结果、Tag-only、失效证据、scope 不完整、结果校验失败：不调用模型。
- 模型输出严格 JSON，校验 `[1]..[N]`、至少一个有效引用、无重复/越界/未声明编号；持久化成功后才显示成功。
- 无引用且明确说明“资料中没有足够依据”的输出映射为 `insufficient` 非成功状态，不伪造引用、不标记成功。
- 模型失败/取消：保留本机引用，不伪造回答，不显示供应商原始错误正文；仅允许重试回答。
- `recordOutcome` 结果写入被拒或抛错时，通过工厂回调立即结束检索/回答并保留引用，不再等待 watchdog。
- 自动恢复/重发被禁用；重试只能由用户显式触发。
- Key 不进入提示词、数据库、日志或测试数据；停止/后台/detach 关闭凭据。

## 6. 已知限制

- 当前页面仍是 `startLocal` 的仅本机检索，未接入 Key/同意/模型回答；旧页面忙碌按钮仍调用 `stop()`，完整 UI 应按 §4.8 改为 `cancelCurrent()`。
- 每次启用最多 10 次模型调用（含失败重试）；达到上限后新回答会失败，需要停止会话、重新输入 Key 并重新同意。
- 回答执行库最多保留 128 个任务；达到上限后新任务失败关闭，不自动清理或覆盖用户记录；后续需要保留/清理方案。
- `recordOutcome` 拒写会立即结束检索/回答；`saveCheckpoint`/`beforeDispatch` 拒写仍可能等待最长 120 秒 watchdog，后续可补同类回调。
- 无有效引用的“资料中没有足够依据”映射为 `insufficient` 非成功状态；成功答案仍必须至少一个有效引用。
- 带数字的方括号（例如年份 `[2026]`）会被当作引用并因越界拒绝；这是严格 fail-closed 的已知取舍。
- 本机工具执行库没有容量上限/保留策略；长期使用需后续清理方案。
- 宿主测试使用替身网络与数据库，不等同于设备验收。
- 前端接入后仍需在模拟器/真机验证：同意边界、后台清理、Key 清空、两阶段展示、失败重试、最大字体与读屏。
- 不得把后端 host 测试或未签名构建宣称为前端设备验收。

## 7. 验证依据

后端测试与构建证据见 `specs/09-Runtime普通对话接入.md` 第 8 节和 `docs/08-项目进度与验收.md` 第 1.1 节；前端接入后应单独补充设备日志、包身份和工作区指纹。
