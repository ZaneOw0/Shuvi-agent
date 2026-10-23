# 整合 CI 门禁复核

> 状态：已实现待验收（门禁判定已修复；完整 lint 尚未通过）。
> 更新日期：2026-10-23。
> 范围：`chore/integrate-agent-gateway` 当前工作区；没有提交、推送或触发远端工作流。

## 1. 本轮发现

本机安装的是 DevEco Studio `26.0.0.821`，Code Linter CLI 由安装包 `plugins/codelinter/run/index.js` 提供，`-v` 实际输出 `6.0.240`。这是 CLI 自身版本，不是 SDK 或 IDE 版本。使用官方 CLI 支持的 `-f json -o <report> <project>` 全量检查，未使用自动修复。

首次正常运行的 CLI 退出码为 **0**，但 JSON 含 **14 条诊断**，ArkTS 分析器日志含 **18 条 ERROR**。因此“退出码为 0”或“报告为空”都不能单独证明检查成功；原脚本“退出码恒为 1”的描述不适用于当前安装。

内部错误包括 12 条 `Invalid rule name` 和 6 条 `getDeclaringMethod` 异常。安全规则在当前安装包的 `performanceAgent/tsauditrules.json`、规则文档中存在，HPAuditor 当前运行日志也显示这些规则已启用；与此同时 ArkPerfCheck 将同名规则记录为无效。此证据表明不同分析阶段的处理存在不一致，不能据此删除安全规则，也不能据单个阶段成功认定整个检查完整。

6 个抛出异常的文件：MockAssistantService、Index 页面，以及 MCP 的 McpClientManager、SseParser、ProtocolClient、Transport。日志还出现 `.local` 中历史资料资源路径不可访问的警告，说明仅配置排除目录不足以证明资源遍历没有受到影响。未修改已安装的检查器来掩盖问题。

## 2. 源码诊断与处理边界

| 规则 | 位置（当前导入基线） | 核对与下一步 |
|---|---|---|
| await-thenable，error | AgentApplicationBackend.ets:438 | `pending` 显式为 `Promise<void>`，经 undefined 检查后等待。保留等待行为，需复核分析器类型推导 |
| await-thenable，error | RdbMemorySnapshotBackend.ets:87；RdbSnapshotBackend.ets:101 | 三参数 `RdbStore.insert` 在本机 API 26 声明为 `Promise<number>`；不能删除 await 后把 Promise 当行号 |
| bad-deep-clone-check，warn，共 11 条 | ArtifactCollaborationPolicy:96/138/163/164/184/196；RuntimeCoordinator:352/791；RuntimeExecutionRecoveryBridge:134/636/640 | 当前使用 JSON 深拷贝保护输入、候选、检查点和预算快照。需要 Agent 同学审查显式复制或其他等价实现，覆盖嵌套对象隔离与字段完整性后再替换 |

代码根目录为 `modules/harmony_agent/`，具体源码可从 [模块说明](../../../modules/harmony_agent/README.md) 导航。本轮不更改上游业务源码、来源哈希、公共契约或诊断级别；三条 await 诊断有明确的 Promise 依据，但不以此擅自加入忽略清单。

SDK 依据：安装包 `sdk/default/openharmony/ets/api/@ohos.data.relationalStore.d.ts` 中 `insert(table: string, values: ValuesBucket, conflict: ConflictResolution): Promise<number>`（本机第 3956 行）。这是当前 SDK 声明，不是目标 OpenHarmony 设备验收。

## 3. 已修复的门禁行为

新增 [ci-lint.ps1](../../../scripts/ci-lint.ps1) 与 [verify-lint-report.cjs](../../../scripts/verify-lint-report.cjs)：

- 每次使用独立 `.local/ci-lint/<时间-随机标识>/` 保存报告、控制台和本轮内部日志。
- 工具共享日志不删除；运行前记录长度/哈希，运行后提取追加内容，或捕获被工具重写后的新日志。不要让其他 IDE 检查与该任务并发写相同日志。
- 报告必须是本次有效 JSON 数组且无诊断；缺失、旧报告、非数组、非法条目均拒绝。
- 要求三个分析日志更新，并包含完成标记；ArkTS 扫描文件数必须大于 0。
- 分析器 ERROR/FATAL、无效规则、文件分析异常、不可访问路径及控制台执行错误均阻止放行。
- 兼容旧 CLT 的 1 和当前工具的 0，但只有完整证据满足上述条件才允许；其他退出码拒绝。
- 支持 Windows PowerShell 控制台的 UTF-16 编码，防止因编码漏检错误。

[ci-windows.cmd](../../../scripts/ci-windows.cmd) 已改为使用新入口，不再仅检查 JSON 数组长度；CLT 工具使用明确路径，避免 PATH 命中其他版本。workflow 加入门禁回归测试及 `CODELINTER_LOG_DIR` 预检。

## 4. 本机证据

| 检查 | 结果 |
|---|---|
| 门禁单元测试 | `node --test scripts/tests/verify-lint-report.test.cjs`，16/16 通过；覆盖异常日志、旧报告、缺失证据、历史错误隔离、编码和诊断 |
| 新入口复跑真实工具 | CLI 返回 0、报告 14 条诊断，新门禁返回 1，正确阻止放行 |
| 产品构建复验 | `assembleHap --no-daemon` 返回 0，81 tasks（51 执行、30 最新）；`.local/ci-lint/product-build.log` |
| 来源与文档 | Agent 224、宿主/fixture 26、网关 281、归档 29 文件校验通过；213 个本地文档链接及 `git diff --check` 通过 |
| 真实检查证据 | `.local/ci-lint/20261023-162828-505-710276e6/`，包含 report、三份 evidence 日志和 summary |
| 首次直接复现 | `.local/ci-lint/report.json` 及同目录内部日志；初次默认日志位置写入受限，改用工具支持的本机日志配置后成功复现 |
| 远端 runner 查询 | GitHub REST `actions/runners` 返回 HTTP 403，当前凭据缺少所需读取权限；未取得在线状态或软件清单 |

“正确拒绝失败结果”是门禁修复通过，不是项目 lint 已通过。没有取得远端 CLT 的执行结果，不能将 IDE CLI 的行为推定为 runner 上完全相同。

## 5. 平台同学复核清单

1. 在 GitHub 仓库的 Actions runner 设置中确认 `[self-hosted, harmonyos]` 的 Windows runner 在线。
2. 按 [持续集成说明](../../deployment/持续集成.md) 确认 CLT/JDK、API 26 SDK、Node 24、.NET 10.0.302；不提供任何 API Key 或证书。
3. 用 runner 当前 Code Linter 执行一次检查，确认实际产生 `codelinter.log`、`arkPerfCheck.log`、`hpauditor.log` 的目录，设置进程环境变量 `CODELINTER_LOG_DIR`。它不是 JSON 报告的输出目录；不要直接套用开发机 IDE 路径。
4. 在本分支运行 `scripts\ci-windows.cmd`，保留本次报告与日志。如果 CLT 日志布局或完成标记不同，先提供脱敏样例适配校验器，不能直接去掉日志检查。
5. 复核上述规则分派、类型推导和分析器异常；若需升级工具，按平台规范单独评审。Agent 同学同时审查深拷贝实现，避免用浅拷贝破坏隔离。
6. 完整 lint 和后续构建/测试通过后，再更新验收结论、人工提交并运行 main PR 门禁；本轮不建议绕过失败检查直接合并。

可发送的交接摘要：

> 整合分支的本机构建及 Agent/搜索/网关测试已通过，但全量 Code Linter 未通过。当前 IDE CLI 退出 0，报告仍有 3 条 await-thenable 和 11 条深拷贝诊断，内部另有 12 条无效规则与 6 条分析异常。门禁已改为同时校验新报告及三个内部日志，不会误放行。请协助用 runner 的 CLT 复核，并确认 SDK、.NET 和 CODELINTER_LOG_DIR；具体位置及证据见本页。无需提供密钥或签名材料。

## 6. 同步 RAG PR #17 后的合并复验

2026-10-23，PR #17 已合入 main（`e040760`），PR #18 已创建为草稿。远端 #18 首次 CI 在工具链预检因 `DEVECO_SDK_HOME` 未配置或无效停止，尚未进入 lint；这与前文的本机 lint 失败是两个独立问题。以下记录对应 `1501c1b` 加本次合并工作区，尚未提交。

四个冲突文件的处理：

- `EntryAbility.ets`：保留来源服务绑定/释放、MCP 后台取消/销毁解除，以及 RAG 前台恢复、后台暂停和销毁清理。
- `Index.ets`：保留全部知识库子页面和设置入口，保留搜索状态、取消、引用与重试；页面销毁同时取消搜索、释放知识库会话；助手异常演示提示不显示在其他一级页。
- `run-host-tests.cjs`：同时登记原有日程/搜索 Mock 与 RAG 测试，不删除任何一边的套件。
- `specs/README.md`：同时保留搜索与知识库契约链接，既有编号暂不重命名，避免破坏引用。

本机 Node `24.14.1`，使用已安装 DevEco Studio SDK 与 Hvigor；未安装新依赖、未签名安装、未发起真实业务请求。当前没有可调用的 `arkts_check` / `build_project`，以 SDK 编译器的产品构建验证，不记作独立静态检查通过。

| 检查 | 结果 | 日志目录（均位于 `.cache/test-logs/`） |
|---|---|---|
| `hvigorw.bat assembleHap --no-daemon` | 返回 0，未签名产品构建通过 | `2026-10-23-rag-agent-merge-build-1501c1b/` |
| `node entry/src/test/run-host-tests.cjs` | 返回 7，固定语料校验阻断，未完成全量测试 | `2026-10-23-rag-agent-merge-host-1501c1b/`、`2026-10-23-rag-agent-merge-host-details-1501c1b/` |
| 同上加 `--unified-only` | 返回 1，白名单路径初始化失败 | `2026-10-23-rag-agent-merge-unified-1501c1b/` |
| 聚焦现有 Mock + 悬浮位置 + MCP 探针用例 | 20 + 9 + 13 项通过，不替代完整 RAG host | `2026-10-23-rag-agent-merge-ux-1501c1b/` |

均经 `scripts/capture-test-log.sh`、`CAPTURE_HOST_ONLY=1` 留存命令退出状态和工作区指纹；host 检查另设 `CAPTURE_SAFE_HOST=1`。过滤器对构建与全量 host 原始输出采取整体隐藏，保留真实命令退出码；host 二次排障详细日志在 `.cache/rag-agent-merge-host-details.log`，不提交。实际本机包装命令为 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .local/repository-integration/verify-rag-merge.ps1 -Check <build|host|unified>`；等价复现命令为上表命令，设置 `DEVECO_SDK_HOME` 到本机 Studio SDK，构建使用 Studio 自带 JBR 和 Hvigor。聚焦 Mock 用例从本轮已生成的 `.cache/host-tests/entry/src/test/MockAssistantCases.js` 与 `MockSearchCases.js` 加载既有用例，随后运行 `run-floating-placement-tests.cjs`、`run-mcp-probe-tests.cjs`，本机入口为 `.local/repository-integration/verify-merged-ux.cjs`。

阻塞定位：

1. `fixtures/apache-license-2.0.txt` 在 Windows 工作区为 11560 字节；只将 CRLF 还原为 LF 后为冻结值 11358 字节，SHA256 为 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`。当前 `.gitattributes` 对 TXT 只有 `text=auto`，未固定 LF。核验只在内存完成，没有重写语料或冻结值；后续需统一固定语料的检出字节策略。
2. `unified-host-entry.cjs` 使用 `path.relative(root,file)` 直接比较含 `/` 的白名单；Windows 返回 `domain\ParsedDocumentModels`，因此拒绝加载。后续应规范化分隔符并保留严格白名单，不能绕过校验。这两份文件相对 main 无内容改动，属于同步后暴露的 host 跨平台问题。

用户人工反馈（2026-10-23）：按随后给出的四项操作，搜索样例完成并显示来源、知识库与我的资料入口、悬浮助手返回后聊天保留、“我的”页 MCP 与知识库设置入口并存及设置页返回，均“无异常”。未提供设备日志、版本和包哈希，按日志规范仅记人工反馈，不记已归档的正式设备验收；没有据此认定取消、日程回归、真实解析/模型调用或真机通过。完整 RAG host、lint 和远端 CI 仍不能记为通过。
