# main 增量集成与 Agent 知识库调用核对

日期：2026-10-28。用户明确授权：`refactor/rag-pdf` 合入 `dev/rag` 并推送一次，更新本地 main 后尝试合并到 dev/rag；保留既有 RAG 链路，冲突分类展示。

## Git 状态与边界

PDF 收尾提交 `97bd706 refactor(pdf): 统一预览入口并完善生命周期`，包含已验证的入口统一、预检移除及释放回执编码修复。`dev/rag` 已快进至此并推送 origin/dev/rag。随后 fetch 得到 main `4ac0a3c`（最新 PR #21）；本地 main 从 `42101a3` 快进至该版本。没有推送 main、force push、rebase 或清理用户资料。

main → dev/rag 的合并先以 no-commit 尝试；以下 3 个文件产生文本冲突，均以增量方式解决，不整体选取任一侧覆盖。此次集成结果只完成本地合并，遵守“推送一次”的顺序，不额外执行第二次 push。既有 CI 交接未跟踪文件不纳入，6 个锁文件仅行尾差异仍排除。

## 冲突分类

| 文件 | 性质 | 处理 |
|---|---|---|
| `entry/src/main/ets/entryability/EntryAbility.ets` | 平台生命周期与资源释放 | 同时保留 PDF detach / background close、新知识库与视觉会话、日历资源处理；原 PDF 窗口销毁清理保留 |
| `entry/src/main/ets/knowledge/infra/KnowledgeAssembly.ets` | 核心依赖装配与配置失效守卫 | 保留 dev/rag 的 attachConfigInvalidation → invalidateEmbedding，再增接 main 的 runtimeQueryRepository / runtimeSearch；同一实例不重复创建 |
| `entry/src/test/unified-host-entry.cjs` | 测试注册与证据哈希 | 合并两侧注册，保留 PDF / 生命周期 / 编码用例，添加 main 的 knowledge-database-adapter 用例与类型清单，不删测试规避失败 |

`Index.ets` 自动合并，人工检查仍挂载 PdfJsSurface、通过 PdfJsSourcePreview 打开旧来源、返回关闭预览、关闭库前 closeAndWait。

## 现有 RAG 保护核对

比较 `97bd706` 与集成工作区，原 `knowledge/` 中只修改已有 `KnowledgeQuerySession.ets` 与 `KnowledgeAssembly.ets`，其余该目录变更均为 main 新增适配层。QuerySession 只增加可选上游取消参数，原调用参数及检索逻辑兼容；Assembly 保留配置失效回调并增加 Runtime 接线。原件文件保存、MinerU 解析、统一正文发布、向量生成与存储、PDF.js rawfile / 高清屏 / 释放桥接均保持原版本字节，无新建替代 RAG 存储或删改旧资料。

## 主对话调用链

已经有实际接口调用，入口为真实对话页面的“知识库”开关；普通对话不会自动查询知识库。`RuntimeAssistantCoordinator.start` 启动普通助手并 prepareRag；开启时 `enableKnowledge → RuntimeKnowledgeSession.activateRag` 取得 KnowledgeAssembly 租约并检查 readiness，要求当前 SiliconFlow / BAAI/bge-m3 配置、检测、设置授权及完整向量空间就绪。

发送路径：`Index.send → RuntimeKnowledgeService.session.send → retrieveRag → KnowledgeRagSessionAdapter.search → KnowledgeSemanticRuntimeSearchAdapter.search → KnowledgeAssembly.createRagQuerySession → 既有 KnowledgeQuerySession / UnifiedQueryService`。先检索正文 / OCR / tags，再复用既有当前问题审批、问题向量与本机 KNN；main 的适配器在本次知识库会话授权下调用 review / allowSemantic(true,true)。没有另外实现上传、解析或向量入库。

结果最多 5 条、每条正文片段最多 800 字符、合计 3200 字符；引用取 BodyDirect / OcrDirect / Vector，纯 tag 不作为回答依据。冻结本次问题与证据后，交独立 PERSONAL 类型的 KnowledgeAnswer Runtime 调用 DeepSeek，校验 JSON 与引用编号，页面展示答案和来源。无引用、检索失败或无法固定证据时不调用 DeepSeek 回答。问题向量请求和带引用的回答请求均可能产生费用；本轮仅阅读源码及执行受控测试，没有触发真实请求。

RAG 查询复用同一个 repository / engine / config，使用独立临时查询会话和 EphemeralQueryHistory，不写知识库页面的搜索历史。关闭、取消和后台停止传递取消并释放租约。

另外 main 提供 KnowledgeDatabasePort / KnowledgeDatabaseAdapter（Backend 命名空间的受控读写与发布），已在 Assembly 装配；本次源码检索未发现主对话直接调用它执行写入。主对话当前接的是上述检索 / 引用 / 回答链路。

## 验证

- 合并后统一宿主 **214/214**：`.cache/test-logs/2026-10-28-rag-main-merge-unified-97bd706/`，包含原 PDF 用例及新增数据库适配器用例；业务请求和私有文件读取为 0。
- Agent / 模型受控宿主 **224/224**：`.cache/test-logs/2026-10-28-rag-main-merge-agent-97bd706/`。实际命令为 SDK Node `--test --test-reporter=tap entry/src/test/run-direct-model-tests.cjs`，由 `.cache/merge-rag-direct-tests.cjs` 包装，将原始输出存入 `.local/merge-rag-tests/` 并只公开测试计数与去敏错误。
- 独立 ArkTS 检查仍有 2 个 BuildProfile 生成模块无法解析的既有限制：`.cache/test-logs/2026-10-28-rag-main-merge-check-97bd706/`；不记为通过，完整编译另记。
- 完整构建 **RC 0**，含 CompileArkTS：`.cache/test-logs/2026-10-28-rag-main-merge-build-97bd706/`。执行 `devecocli build --product default --modules entry`，模板字节不变，未签名 HAP 20,275,439 字节，SHA-256 `b4af72ff5c32400c1929b3f554b3ff5d0867bda7f4cba10d8acf9a2c400bcbb9`。构建工作区指纹 `525082b2073fde4be862ecfc9859ba0bc4d966c1760ba48c6dacc2adb8e53c8e`；此后仅补本文结果、还原锁文件行尾并完成合并提交。

所有命令经 `scripts/capture-test-log.sh <scope>`，设置 `CAPTURE_HOST_ONLY=1 CAPTURE_SAFE_HOST=1`，宿主设置 `DEVECO_SDK_HOME='D:/Huawei-DevEco-Studio/DevEco Studio/sdk'`；统一测试命令为 SDK Node `entry/src/test/run-host-tests.cjs --unified-only`。不进行模拟器操作、样本回归、实际模型调用或真实云解析；宿主证据不等于完整实机 / 实云验收。
