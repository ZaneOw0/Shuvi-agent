# PR #26 合入 main 与 RAG 三链路回归

> 状态：2026-10-29 已实现，宿主回归与未签名构建通过；本次未执行设备、真实 Provider 或真机验收。
> 合并方向：在 `feat/multimodal`（`6f996c1`）合入 `main`（`ca7309c`，含 PR #25）。
> 用户要求：UI 以 PR #26 为准，保留 RAG L0/L1/L2 并运行三链路回归；锁文件不提交，不处理 Code Linter 报告。

## 1. 冲突处理

| 文件 | 处理 |
|---|---|
| `components/RuntimeChatSetup.ets` | 接受 PR #26 删除，由统一 API Key 管理与助手连接状态替代。知识库查询仍需另行授权。 |
| `components/RuntimeKnowledgePanel.ets` | 沿用 PR #26 卡片、折叠来源与重试布局；适配授权/来源展示，不恢复独立知识库模型会话，不重复展示主对话回答。 |
| `knowledge/ui/EmbeddingSettingsView.ets` | 保留 PR #26 API Key 管理入口和布局，接回配置/凭据绑定失效、重新确认与异步刷新隔离。 |
| `pages/Index.ets` | 保留 PR #26 默认真实助手、图片、历史对话、日程页及 API Key 界面；接回统一主对话发送、独立知识库授权和 PDF.js 资源生命周期。 |
| `services/calendar/AssistantIntent.ets` | 合并图片提示词与 main 的按实际工具/许可描述知识库能力，保留资料和图片指令均不构成授权。 |
| `services/model/ChatRuntimeAssembly.ets` | 保留 PR #26 图片/记忆预算和 main 的 `kit.extra` 注入，不丢失 `knowledge_search`。 |
| `services/model/DeepSeekToolTransport.ets` | 组合图片消息、持久普通记忆与 main 的 Registry 工具、修订、引用、取消及关闭流程。 |
| `entry/src/test/run-direct-model-tests.cjs` | 保留双方测试，更新普通助手预算，追加交叉回归。 |

表内前七项以 `entry/src/main/ets/` 为路径前缀。`EntryAbility.ets` 自动合并，保留 Speech 和 PDF.js 两类生命周期清理。

## 2. 授权、记忆与预算

- 知识库仍需显式授权。开启后，由同一主对话模型按需调用工具；授权不会自动触发入库或重新向量化。
- 允许语义查询与仅本机检索分开。仅本机检索不发送查询 Embedding，但命中片段仍按用户许可发送给 DeepSeek 回答；L0 不依赖 Embedding Key 或自动入库开关。
- 普通模型记忆归对话持有，继续使用 PR #26 的加密历史对话存储与摘要。知识库工具结果、使用这些结果的回答，以及随后沿用其上下文的轮次，只进入传输层当前授权会话的临时历史，不写入持久模型记忆，也不交给摘要模型。
- 撤销授权、新建/切换对话、删除当前对话使授权修订变化，后续模型请求清除临时知识上下文。关闭/后台/重启释放临时上下文，不恢复旧授权。UI 可以保留已展示的历史回答快照；这些快照不自动作为模型记忆重新发送。
- 普通助手采用 PR #26 的每轮 262,144 输入 / 8,192 输出 token、100,000 micros、110 秒调用截止及 120 秒 Runtime 墙钟预算；会话轮数不设旧上限。UI watchdog 与 120 秒墙钟统一。
- 已授权知识库的模型 loop 保留更严格的 90 秒、32,768 输入 / 2,048 输出 token、每轮最多 3 次模型请求、该模型会话累计 10 次知识库授权请求；每轮最多 2 次检索，与文档等工具共享 6 次工具总量。片段仍为累计 5 条 / 3,200 字符、单条 800 字符。普通助手外层预留预算不扩大这些内层限额。
- 语音、补充文字与图片走同一普通助手发送入口，转写不显示在气泡中；知识库授权开启时仍按 PR #26 约束拒绝图片发送并保留输入。

## 3. 本轮验证

日志位于本机 `.cache/test-logs/`，不入 Git。目录元数据包含起点提交 `6f996c1`、未提交改动和工作区指纹；测试发生在冲突解决后的合并工作区。

| 范围 | 结果 | 日志目录（相对 `.cache/test-logs/`） |
|---|---|---|
| L0 关键词/FTS/字面降级专项 | 20/20，真实业务网络请求 0 | `2026-10-29-pr26-rag-lexical-6f996c1/` |
| L1 查询/历史空间/授权/历史保存 | 30/30，真实业务网络请求 0 | `2026-10-29-pr26-rag-l1-6f996c1/` |
| 主对话完整回归，含 L2 交叉用例 | 269/269，其中 L2 与知识端口图片交叉场景 24/24 | `2026-10-29-pr26-rag-model-final-6f996c1/` |
| 统一知识库完整回归 | 239/239，真实业务网络请求 0 | `2026-10-29-pr26-rag-unified-final-6f996c1/` |
| 语音与页面组合发送 | 57/57 | `2026-10-29-pr26-rag-speech-6f996c1/` |
| 原有完整宿主回归（含旧知识库链路） | 310/310 | `2026-10-29-pr26-rag-full-host-6f996c1/` |
| 最终未签名构建 | `BUILD SUCCESSFUL`，包含 ArkTS 编译 | `2026-10-29-pr26-rag-build-final-6f996c1/` |

L1 覆盖旧配置/凭据下正文和图片资格恢复、新旧兼容空间合并、Provider/模型/工作区/维度等不兼容拒绝、查询许可一次性消费、范围变化拒绝、历史写入不误失效、语义失败保留本机结果等。L0 复用真实应用索引/读回逻辑，host 的 FTS tokenizer 替身不作为设备 `customtokenizer` 证明。

L2 覆盖同一 Registry Runtime 回注、引用身份/范围校验、取消与撤销、共享片段限额、仅重试回答及真实适配器语义失败降级；新增来源与派生回答不进入可恢复模型记忆、新对话清理临时来源、授权会话请求上限以及未授权知识端口与多模态记忆共存。网络端口均为确定性夹具，不是供应商效果评测。

构建过程中保留失败证据：第一次受依赖缓存写入的沙箱 `EPERM` 阻止；随后修复四处 UI 遗留引用；一次 ArkTS 编译成功后，打包因 Hvigor 日志轮转 `EBUSY` 失败，重试成功。最终构建为随后 watchdog 修正后的成功记录，未把已有 HAP 或失败调用记作通过。未运行 Code Linter、签名安装、设备 UI 或真实云端请求。

复现时先设置已安装 SDK 的 `DEVECO_SDK_HOME`，并设置 `CAPTURE_SAFE_HOST=1`、`CAPTURE_HOST_ONLY=1`；在仓库根目录通过以下 `RUN_CMD` 调用 `scripts/capture-test-log.sh <scope>`：

```text
node scripts/l0-host-summary.cjs --lexical-only
node scripts/l0-host-summary.cjs --l1-only
node scripts/l0-host-summary.cjs --model
node scripts/l0-host-summary.cjs
node scripts/l0-host-summary.cjs --speech
node scripts/l0-host-summary.cjs --full-host
```

构建设置 `L0_DEVECO_CLI` 为本机已安装 CLI 的 `dist/cli.js`，使用 `RUN_CMD='node scripts/l0-verify.cjs build'` 经同一日志入口调用。仓库不记录本机安装路径和签名配置。

## 4. 文档与边界

PR #26 新增多模态和历史对话 spec 改为 15/16，保留 main 的 RAG spec 11/14，更新索引、交接链接、三链路图与本报告。main 的 `AGENTS.md` 替代 skill/CLI 约定随合并保留。

本报告只确认合并后的宿主逻辑回归和构建。真实语义质量、模型是否正确选择检索、设备上 FTS tokenizer、图片加语音、UI 以及真机仍需独立验收；此前任一分支的设备记录不能直接作为合并版本的验收结果。
