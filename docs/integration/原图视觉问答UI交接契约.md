# 原图视觉问答 UI 交接契约

> 状态：后端已实现待前端接入；后端仅提供会话、状态投影、数据边界与宿主测试。
> 归属：`RuntimeVisionSession` / `VisionAnswer*` 由 Agent/应用服务维护；图片选择、缩略图、Key 输入、同意按钮、阶段展示与无障碍由前端负责。
> 当前页面尚未调用本契约；不得把本契约当作设备验收。助手页的发图能力走 [spec 15](../../specs/15-助手多模态消息.md)，不是本契约的前端接入。

## 1. 边界

- 前端只调用 `RuntimeVisionService.session`，不直接调用 `VisionChatTransport`、Provider、RDB、`VisionAnswerRuntimeFactory` 或图片解析内部实现。
- 前端不读取、不记录、不持久化 Key；Key 以 `Uint8Array` 传入，后端消费并清零。
- 前端不自行判断“是否同意外发”；只有用户明确勾选原图发送范围后，才以 `consent=true` 调用 `start`。
- 后端不负责页面布局、缩略图渲染、动画、无障碍朗读和截图验收。

## 2. 后端入口

```ts
const session = RuntimeVisionService.session;

// 用户明确同意后：
await session.start(
  visionAnswerRuntimeFactory(context, DEBUG, session.answerContext,
    (taskId: string): void => session.answerOutcomeRejected(taskId)),
  keyBytes,
  true
);

// 系统 Picker 返回 URI 与显示名后：
await session.attachImage(uri, displayName);

// 发送：
await session.send(question);
```

- `start` 只打开会话，不发送图片或问题；未同意时传 `false`，后端不启动会话并清零 Key。
- `attachImage` 只读取/校验/重编码图片，不调用模型；失败返回 `false`，`stage=imageFailed`。
- `send` 才提交 `vision-answer` PERSONAL 模型任务；没有图片、未同意或未就绪时返回 `false`。
- `retryAnswer` 只在 `stage=answerFailed` 时使用；复用同一张已固定图片，不重新读取/编码。
- `cancelCurrent` 用于忙碌时取消；`stop` 清除会话、凭据和图片字节，已显示回答保留。
- `attach(listener)` / `detach()`；页面离开时 `detach`，Ability 前后台由 EntryAbility 调用。

其他方法：

| 方法 | 作用 |
|---|---|
| `attachImage(uri: string, displayName: string): Promise<boolean>` | 读取、校验、重编码一张图片；不发送模型 |
| `removeImage(): boolean` | 非忙碌时移除图片与当前回答 |
| `clearConversation(): void` | 非忙碌时清空图片、问题、回答 |
| `send(query: string): Promise<boolean>` | 发送本次问题与已固定图片 |
| `retryAnswer(): Promise<void>` | 仅重试回答，复用图片 |
| `cancelCurrent(): Promise<void>` | 取消当前任务；保留图片 |
| `stop(): Promise<void>` | 停止会话，关闭凭据，清空图片字节 |
| `snapshot(): RuntimeVisionView` | 读取视图投影，不直接读内部字段 |

## 3. 视图

`RuntimeVisionView`：

| 字段 | 含义 |
|---|---|
| `lifecycle` | `IDLE / STARTING / READY / STOPPING / STOPPED / FAILED / BLOCKED` |
| `busy` | 当前有模型任务 |
| `stage` | `idle / starting / attaching / answering / complete / insufficient / answerFailed / imageFailed / stopped` |
| `message` | 后端状态说明，可直接展示 |
| `query` | 当前问题 |
| `answer` | 模型回答；`insufficient` 时为空 |
| `imageReady` | 是否已有可用图片 |
| `imageName` | 用户显示名；仅本机展示，不发送模型 |
| `imageMime` / `imageWidth` / `imageHeight` / `imageBytes` | 重编码后图片信息，供展示/排障；不显示内部路径 |
| `requestCount` / `maxRequests` | 本次会话已提交的请求数与硬上限（默认 10）；第 11 次 `send` 返回 `false` |
| `pricingState` | 当前固定为 `unverified`；不得显示为实际扣费或金额上限 |
| `consent` | 后端是否持有本次明确同意 |
| `clearEpoch` | 启动/停止递增；前端应清空 Key 输入 |

阶段语义：

- `attaching`：图片读取/重编码中，未调用模型。
- `answering`：已提交视觉模型请求。
- `complete`：模型回答通过严格 JSON/引用校验并已持久化。
- `insufficient`：模型明确说明资料不足且无引用；非成功状态，图片保留。
- `answerFailed`：网络/模型/格式/持久化失败或取消；图片保留，可重试。
- `imageFailed`：图片读取、类型、尺寸或编码失败；未发送。
- `stopped`：会话停止；图片字节已清除，回答可保留展示。

## 4. 页面必须覆盖

1. 系统图片 Picker：JPG/JPEG/PNG/WebP；不新增相册权限；相机/多图/文件输入不在本契约范围。
2. 缩略图、移除、忙碌禁用；图片失败时明确“未发送”。
3. Key 密码输入，关闭自动填充/预览；组件消失清空字符串。
4. 明确同意文案：
   - 发送目的地为 DeepSeek API。
   - 发送本次问题与一张重新编码后的图片。
   - 不发送文件名、路径、历史消息、知识库、内部 ID 或 EXIF；实际留存/费用以供应商规则为准。
   - 启用不发送请求；点击发送才调用模型。
5. 两段状态：图片准备与模型回答分开显示。
6. `complete` 标注“DeepSeek 视觉回答（依据当前图片，不是原文识别）”；不能与 OCR/原文混同。
7. `answerFailed` 显示“重试回答”；重试不重新读取图片。
8. `insufficient` 不标记成功，不伪造引用，不显示“重试回答”作为成功入口。
9. 忙碌时“取消当前”，空闲时“停止会话”；停止后重新输入 Key 并重新同意。
10. 页面离开/切标签/后台停止；返回前台不自动恢复。
11. 无障碍：图片按钮、Key、同意、取消/重试均需可读标签和最小 44vp 点击区域。

## 5. 数据与隐私

- 只发送：一张重新编码后的图片、本次问题（≤500 字符）、固定系统提示。
- 不发送：文件名、URI、路径、EXIF/GPS、历史、知识库、文档、`evidenceId`、`generation`、数据库 ID、Key。
- 图片源 ≤20MB、≤20MP；重编码后 ≤8MB、最长边 ≤2048；仅静态单帧 JPEG/PNG/WebP。
- 重新编码去除容器元数据；方向处理依赖 ImageKit 解码，未单独验收。
- 会话 Key 只存在内存；停止/后台/销毁清零并关闭凭据；图片字节停止时清零。
- 独立加密执行库 `shuvi_vision_answer_v1.db` 只保存回答 checkpoint/结果，不保存图片字节或文件名。
- 2026-10-29 起助手聊天按 [spec 15 助手多模态消息](../../specs/15-助手多模态消息.md) 在统一工具循环中接收图片：复用本契约的 `VisionImagePreparer`（最长边 1600）与相同的数据边界，但不经过 `RuntimeVisionSession` 或本执行库；图片只随当轮发送。知识库/搜索路径不受影响。

## 6. 已知限制

- 当前页面没有接入本契约；前端接入前不得声称图片输入已完成。
- 每次会话最多 10 次模型请求；第 11 次 `send` 返回 `false` 并显示请求上限，需停止并重新启用；`requestCount` 在重新启用时重置。
- 单次 60 秒超时、120 秒 watchdog；执行库最多 128 条任务，无自动清理/恢复。
- `maxMonetaryCostMicros` 只是 Agent 预算门槛；没有图片计费单价，实际费用以 DeepSeek 账单为准。
- 本轮没有真实 DeepSeek 视觉请求、真实 Key、账单、模拟器图片解码或真机验收；宿主测试使用替身网络/图片。
- 文件（PDF/DOCX/TXT）输入不在本契约范围；后续单独设计，不复用本契约的图片字节通道。
