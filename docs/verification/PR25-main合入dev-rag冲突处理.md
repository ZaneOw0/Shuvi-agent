# PR #25：main 合入 dev/rag 的冲突处理

> 日期：2026-10-29。状态：冲突已解决，host 与构建验证完成，设备验证未执行。
> 输入：dev/rag `7deaeb3`；main `cd51569`（PR #24 语音消息）。
> 在独立工作区 `rag-main-conflicts/HarmonyPA` 执行合并，原开发工作区的锁文件、spec 草稿及其他未提交内容未参与。

## 1. 三个冲突文件

| 文件 | 处理 |
|---|---|
| `RuntimeKnowledgePanel.ets` | 保留 dev/rag 的知识库授权/状态/来源面板；不恢复旧独立回答面板。接受 hideQuery 参数但不展示原始问题，保留新问题切换时收起来源的 Watch。按实际 Keyword/Literal 类型标记来源。 |
| `EntryAbility.ets` | 销毁与窗口销毁同时执行 PDF.js 清理和语音资源释放；后台同时关闭 PDF 预览与停止语音；保留 main 的 Speech bind/foreground。 |
| `Index.ets` | 合并语音录制/播放订阅及知识库授权状态同步；返回键先取消活动语音，再关闭展开 PDF，之后沿用原导航。知识库状态面板与普通对话控件不再因旧 else-if 分支相互替代；搜索面板保留语音查询隐藏。 |

## 2. 非文本冲突的接口适配

main 的 `sendVoice()` 调用旧 `RuntimeKnowledgeService.session.send()`，dev/rag 的服务已使用 `ModelKnowledgeTools`，没有该接口。现将语音与用户补充文字组成一次请求，经 `RuntimeChatService.session.send()` 进入同一个 Agent loop；知识库是否检索仍由当前授权与模型工具策略控制。联网搜索保留搜索会话入口。

语音发送与纯文字使用同一个普通助手就绪/剩余额度门禁。显示消息仅含语音气泡和用户手输补充文字；后台转写不绑定输入框或消息正文，查询隐藏集合继续保留。调用抛错时移除未确认消息并恢复原始语音/补充草稿，不重复拼接，也不覆盖用户后来编辑的新输入。收到模型失败后的自动重发不在本次范围。

没有新增 API、依赖、权限或云服务；麦克风权限等来自已经合入 main 的语音功能。没有清理任何用户录音、日历或知识库，没有签名变更或实际模型请求。锁文件不提交。

## 3. 验证

以下日志均位于本独立工作区的 `.cache/test-logs/`，meta 保存合并父提交与工作区指纹。按用户指示不处理 Code Linter；ArkTS 以真实 CompileArkTS 构建为准。

| 范围 | 结果 | 证据目录 |
|---|---|---|
| 语音、草稿、隐私与页面返回键 | 56/56 | `2026-10-29-pr25-merge-speech-lifecycle-7deaeb3/` |
| 主对话 / Runtime / RAG 工具 | 254/254 | `2026-10-29-pr25-merge-model-7deaeb3/` |
| 统一知识库、L0/L1 与 PDF | 239/239 | `2026-10-29-pr25-merge-unified-7deaeb3/` |
| HAP 构建 | BUILD SUCCESSFUL；unsigned HAP，有既有警告 | `2026-10-29-pr25-merge-build-7deaeb3/` |

复现：先设置本机 SDK、CLI 环境，host 同时设置 `CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1`，构建设置 `CAPTURE_HOST_ONLY=1`。

```bash
RUN_CMD='node scripts/l0-host-summary.cjs --speech' bash scripts/capture-test-log.sh pr25-merge-speech-lifecycle
RUN_CMD='node scripts/l0-host-summary.cjs --model' bash scripts/capture-test-log.sh pr25-merge-model
RUN_CMD='node scripts/l0-host-summary.cjs' bash scripts/capture-test-log.sh pr25-merge-unified
RUN_CMD='node scripts/l0-verify.cjs build' bash scripts/capture-test-log.sh pr25-merge-build
```

独立工作区复用了本机既有 oh_modules，未引入新包；生成的锁文件变动保持未暂存。首次语音测试有两条旧 boolean 接口测试失败，已将注入适配器改为共享助手的异常语义，并用空知识库 send API 替身防止旧调用复发；失败日志 `2026-10-29-pr25-merge-speech-7deaeb3/` 保留，不算通过。

合并后的真实录音、播放、语音到模型、PDF 预览/后台及真机验收仍待执行。host 和构建不能替代设备结论。本次仅把 main 合入 dev/rag 以更新 PR #25，没有直接合并 PR 到 main。
