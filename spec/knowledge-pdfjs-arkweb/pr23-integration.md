# PR #23 增量集成与 L1 核对

日期：2026-10-28。dev/rag 基线 `d5dd10f`，main `1f0cd49`（PR #23，功能提交 `68b2fcb`）。用户授权获取与增量合并 main、分类冲突、检查主对话知识库调用及 specs/02 的 L1 符合情况；本轮不推送、不部署、不操作模拟器、不外发样本或调用真实模型。

## 合并及保护范围

本地 main 已位于 `1f0cd49`，fetch 后确认与 origin/main 相同。`git merge --no-commit --no-ff main` 自动合并成功；**冲突文件数 0**。Index.ets 自动合并的是会话“轮数”和文档工具提示文案，保留 dev/rag 的 PDF 入口与生命周期。

与 `d5dd10f` 比较，`entry/src/main/ets/knowledge/`、`entry/src/main/resources/rawfile/pdfjs/` 和 `specs/02-个人知识库问答.md` 差异均为空（git diff --quiet RC 0）。原解析、入库、向量、检索与 PDF.js 保持字节一致。本轮没有为接新工具复制或改写 RAG。

虽无冲突，增量按性质审阅：

| 类别 | 文件范围 | 结论 |
|---|---|---|
| 对话与模型工具调度 | RuntimeAssistantCoordinator、ChatRuntimeAssembly、DeepSeekToolTransport、AssistantTools、AssistantRuntimeSession | 普通助手可调用 document_create/read/update 或 calendar_propose；日历提议仍需用户确认；知识库是独立显式会话 |
| 本机文档与 MCP | services/documents、native_tools、agent_connectors、mcp_client | 文档通过受控 Runtime 保存到 Download/com.example.shuvi；未调用统一知识库导入，不能把文件保存当知识入库 |
| 构建与依赖 | build-profile、entry/oh-package 及 entry lock | main 注册既有本地 native_tools HAR 并增加本地依赖。entry lock 含真实 native-tools 依赖增量，随 main 保留，不能当旧 CRLF 噪音丢弃。只还原构建造成的纯行尾工作区变化到 index |
| 文档与测试 | 文档工具 spec、run-direct-model-tests、LOCAL_CHANGES、导入检查脚本 | 保留 main 增量，执行现有 RAG 与新工具受控测试，不删测试规避失败 |

## 主对话调用链

调用仍存在：RuntimeAssistantCoordinator.start → prepareRag → 用户开启知识库 → activateRag 检查配置 / 授权 / 向量空间 → Index.send → RuntimeKnowledgeService.session.send → retrieveRag → KnowledgeRagSessionAdapter → KnowledgeSemanticRuntimeSearchAdapter → KnowledgeAssembly.createRagQuerySession → 既有 KnowledgeQuerySession / UnifiedQueryService。

应用先做本机正文/OCR/tag 匹配，再复用现有 Query 用途授权、SiliconFlow/BAAI/bge-m3 问题向量和本机 KNN，不重新向量化整库。最多 5 条引用、每条最多 800 字符、合计 3200 字符；纯 tag 不作为断言证据。冻结问题与引用后，由独立 PERSONAL 回答 Runtime 调用 DeepSeek，校验结构和引用编号。

普通助手的新 tool_choice=auto 工具声明未加入知识库检索，因此没有将 L1 检索改为模型可选决策。文档读写工具不是知识库工具，也没有自动入库调用。关键词仍是 prepareTextQuery 的确定性处理 / 空白拆分，没有智能关键词抽取、查询改写或多轮检索；中文整句可能成为一个字面短语。关键词提炼不是 spec 规定的 L1 必经步骤。

## 对照 specs/02

结论：具备 L1 主干，**仍不完全符合 §4.4 / §4.5 / §5.8**；PR #23 没有修改或补齐原 L1 差距。

| 要求 | 当前情况 |
|---|---|
| §4.5 应用确定性先检索后生成 | 符合；知识库模式直接调用检索适配器，不由模型决定查不查 |
| 用户开关 / 配置 / 授权 | 已有开关、Key、Embedding 配置 / 费用绑定守卫；已开启的会话内 review 后 allowSemantic(true,true)，无逐问题额外弹窗。本轮未改授权策略 |
| 语义不可用仍可 L0 | 明确差距：ragReadiness 强制完整向量空间与检测就绪；适配器要求 semanticState=Complete，失败抛错，已有字面命中未返回聊天侧。知识库页面保留原 L0，不等于聊天模式完成降级 |
| L1 调用失败降 L0 | 回答阶段失败或编号无效时保留片段与原因，可仅重试回答；检索语义失败降级仍缺失，不能声称全部失败路径完成 |
| 片段约束、编号校验、无证据不调用回答模型 | 已实现；编号合法不保证答案语义受原文支持 |
| §4.4 历史引用快照及来源更新 / 删除失效标记 | 不能验收：聊天引用主要在 RuntimeKnowledgeView / KnowledgeAnswerContext，查询用 EphemeralQueryHistory；加密执行 journal 不替代带完整来源版本 / locator 的历史引用快照和失效复核。KnowledgeRuntimeCitation 目前是 documentId/generation/excerpt 等有限投影 |
| D5 输入 / 输出基础敏感词校验 | 当前 Knowledge 回答链路未见专项敏感词校验，不能声明已完成 |

以上缺口只检查记录，没有借 merge 擅改业务契约、放宽约束或新增模型能力。代码级判断不等于答案质量评测或实云 / 实机验收。

## 验证与复现

- 统一 RAG 宿主 **214/214**：`.cache/test-logs/2026-10-28-rag-pr23-unified-d5dd10f/`，业务请求、私有文件读取为 0。
- Agent / 新工具受控宿主 **234/234**：`.cache/test-logs/2026-10-28-rag-pr23-agent-d5dd10f/`。包装器 `.cache/merge-rag-direct-tests.cjs` 执行 SDK Node `--test --test-reporter=tap entry/src/test/run-direct-model-tests.cjs`，原始输出留 `.local/merge-rag-tests/`，公共输出只含计数及去敏诊断。
- 完整构建 **RC 0**（含 CompileArkTS）：`.cache/test-logs/2026-10-28-rag-pr23-build-d5dd10f/`，工程模板字节不变；未签名 HAP 20,627,029 字节，SHA-256 `7500d512625a58e96b5aead9bc93eef8792ee3c87f2197895fb7f9dd18f72f3e`。构建工作区指纹 `1c70dbb0463cb0cfe0b41df8a69567ef2374592df6318e7d0a208e070f7f90b7`；此后仅补本文结果、还原纯行尾工作区变化并完成合并提交。无额外 ETS 手工修改，未独立运行 ArkTS checker，不以完整构建冒称独立检查执行。

复现使用 `CAPTURE_HOST_ONLY=1 CAPTURE_SAFE_HOST=1 DEVECO_SDK_HOME='D:/Huawei-DevEco-Studio/DevEco Studio/sdk'`，经 `scripts/capture-test-log.sh <scope>` 执行 SDK Node `entry/src/test/run-host-tests.cjs --unified-only` 及上述受控 Agent 命令。构建用 `.cache/pdfjs-hidpi/build.cjs` 包装 `devecocli build --product default --modules entry`，不使用签名缓存或设备接口，构建结论另行追加。
