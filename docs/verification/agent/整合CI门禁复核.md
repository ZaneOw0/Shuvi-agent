# 整合 CI 门禁复核

> 状态：已实现待验收（门禁判定已修复；完整 lint 尚未通过）。
> 更新日期：2026-10-24。
> 修复前远端复核对应 `chore/integrate-agent-gateway` / `32ad881`，PR #18；历史阶段结果保留。本轮提交包含后续代码与测试环境兼容修复，本机验证结果见下一节；远端结果需以包含修复的新一轮 CI 为准。

## 本机修复进展（2026-10-24，基于 32ad881 的工作区）

本节是代码修复后的本机结果；下面的远端运行与早期诊断属于修复前历史。修复随本轮提交交付，尚未取得包含修复的新一轮远端 CI 结果，完整门禁仍未通过。

### 已实施的修复

1. 对话检查点、视图、协作策略、预算和账单 DTO 改为显式复制。检查点的嵌套输入、工作流、事件、授权和调度状态均独立复制；不把 JSON 深拷贝直接改成浅拷贝。聊天日志仅复用内部不可变记录，写入时替换独立记录，不改变存储格式。
2. 搜索回执在异步调用前计算参数摘要，完成后按摘要绑定；读取回执返回独立值。MCP 的 `Object` 返回值仍需有界 JSON 解码并逐项校验：仅该解码行添加 `@performance/bad-deep-clone-check` 的行级说明与抑制。它不是业务 DTO 复制；保留 1 MiB 限制、结构一致性、请求标识和用量字段校验。没有关闭全局规则，也没有抑制引擎错误。
3. 三处 `await-thenable` 误报通过 `Promise.resolve` 归一化解决，保留等待真实 Promise 和异常传播。新增两项 RDB 延迟插入测试，验证插入完成前 CAS 不返回、插入拒绝向上传播。
4. workflow 的 checkout 设置 `fetch-depth: 0`，供原有 RAG 测试读取冻结历史提交 `9f5992c`。没有改变触发条件、PR 目标分支或门禁判定。
5. MinerU transfer host loader 改用套件私有模块缓存；模型类与适配器从同一模块图加载，保留 `instanceof` 校验。循环引用时先登记模块，编译失败则移除；不再复用另一套 SDK double。
6. `.gitattributes` 为字节敏感的固定 TXT/JSON 语料及源码契约文件固定 LF。本机只在证明差异完全来自 CRLF、且还原后等于已提交字节或既定语料哈希后恢复 LF。原有测试断言、冻结哈希和历史比较未修改。
7. `LOCAL_CHANGES.json` 更新为 15 个有记录的本地变更，保留不可变上游清单；不新增公共接口、依赖、权限或服务。

### 验证与复现

环境：本机 DevEco Studio `26.0.0.821`、API 26、Node `24.14.1`；没有可用的独立 `arkts_check` / `build_project` 工具，使用本机 SDK 编译器和 Hvigor。未调用真实模型、搜索供应商，未执行设备安装或真机验收。

所有证据目录位于 `.cache/test-logs/`：

| 检查 | 结果 | 本轮证据目录 |
|---|---|---|
| Code Linter 6.0.240 | JSON 诊断 31 → 0；工具退出 0、门禁退出 1，覆盖仍不完整 | `2026-10-24-ci-fixes-lint-32ad881/` |
| 产品 `assembleHap --no-daemon` | 通过 | `2026-10-24-ci-final-build-32ad881/` |
| 对话与搜索 host | 121/121 通过，含完整快照隔离、两种 RDB 插入等待/拒绝 | `2026-10-24-ci-copy-await-host-32ad881/` |
| Runtime / Storage Hypium 本机测试 | 134/134、57/57 通过 | `2026-10-24-ci-copy-agent-unit-32ad881/` |
| 完整 UX / RAG host | 304/310 通过；6 项因指定离线材料缺失失败，未跳过 | `2026-10-24-ci-mineru-portability-host-32ad881-2/` |
| Agent 来源清单 | 224 个基线文件、15 个本地变更、8 个模块校验通过 | `2026-10-24-ci-source-manifest-32ad881/` |

lint 明细：`.local/ci-lint/20261024-200014-945-ed9699f0/`；Hypium 原始结果：`.local/agent-tests/20261024-200622-400/`。构建/host 原始输出为 `.cache/direct-model-build-*.log`、`.cache/direct-model-test-*.log`、`.cache/ci-fixes-unit-*.log`，以对应 capture 日志内记录的精确路径为准。

复现时设置 `DEVECO_SDK_HOME`、`JAVA_HOME` 与 `NODE_HOME` 为本机 Studio 的 SDK、JBR 和 Node 目录，然后通过 `CAPTURE_HOST_ONLY=1`、`RUN_CMD` 和 `scripts/capture-test-log.sh <scope>` 包装以下命令（本机实际包装脚本为 `.local/direct-model/verify.ps1` 与 `.local/ci-checks.ps1`）：

```powershell
node entry/src/test/run-direct-model-tests.cjs
node entry/src/test/run-host-tests.cjs
node scripts/verify-agent-import.cjs
.\scripts\test-agent-unit.ps1 -DevEcoHome 'C:\Program Files\Huawei\DevEco Studio' -Modules agent_runtime,agent_storage
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHap --no-daemon
```

lint 复现使用下节同一 `scripts/ci-lint.ps1` 命令；不能改为只检查空 JSON。

### 仍需协作解决

- **检查器覆盖不完整**：本轮仍有 12 条安全规则分派错误、9 个 `getDeclaringMethod` 文件分析异常，以及历史资料资源路径告警。`report.json` 为 `[]` 不代表这些文件通过。保留所有规则和 `verify-lint-report.cjs` 的失败判定。需 CI/平台同学用 runner 的实际安装版本核对原始引擎日志，评估可兼容的检查器修复或工具升级；本轮不修改安装包，也不设置引擎错误忽略清单。
- **RAG 私有离线材料**：完整 `run-host-tests.cjs` 需要指定 PDF 与两个既有解析 ZIP；本机缺失，不能用其他文件替代冻结材料。需 RAG 同学提供合法授权材料的本机/runner 放置方式并核对原有哈希，不能把缺失测试改为默认跳过。本轮 304/310 通过，剩余 6 项全部为 ENOENT；详细日志 `.cache/ci-fixes-ux-20261024-201454.log`。缺失文件为 `.cache/m2-input/user-pdf/02_第02章_模型评估与选择.pdf`、`.cache/new-pdf-ingestion-diagnosis/result-m2-6fe6c44120d215e2ec1a852235fb97a0.zip`、`.cache/m2-result-analysis/result-m2-7eaa150e269374313fd776f12a2ae9fa.zip`。并未核实 runner 是否已有这些材料；不能将本机缺失直接当作 runner 上已发生的失败。

自动审批曾拒绝“归一化源码再进行字节比较”的候选方案，理由是可能弱化门禁。该方案未执行；最终采用上文固定检出 LF 的方案，保留原有测试校验。


此外，自动审批拒绝了恢复回执解析异常吞没行为的候选改动；未执行该改动。当前参数摘要计算失败仍向上传播，无法建立关联的调用不被伪造成有可靠回执。

## 最新 CI 复核（2026-10-24）

[运行 40090824978](https://github.com/ZaneOw0/Shuvi-agent/actions/runs/40090824978) 于北京时间 19:40 开始，head 为 `32ad88166163c6c2ceee2c9ae5bdbe71d5a24cfb`，attempt 1。工具链预检、来源校验与 MCP fixture、搜索服务构建与测试通过；“门禁（代码检查 + 构建）”在 lint 失败，尚未执行该步产品构建；后续 Agent/Hypium/UX 和网关步骤跳过。

远端摘要：`issueCount: 31`，并报告 `Analyzer failed or coverage incomplete: arkPerfCheck.log`。证据目录是 runner 上的 `D:\actions-runner\_work\Shuvi-agent\Shuvi-agent\.local\ci-lint\20261024-194045-303-c43de09f`。此运行没有可下载 artifact，工作流也未配置上传这些诊断文件；下载到本机的失败步骤日志为 `.local/ci-review/run-40090824978/failed.log`。远端摘要不能用于逐条推断诊断位置。

同一提交的本机 Code Linter 6.0.240 复现 31 条诊断，分布如下（以下明细来自本机，不冒充 runner 原始 JSON）：

| 范围 | 诊断 |
|---|---|
| 原有 ArtifactCollaborationPolicy、RuntimeCoordinator、RuntimeExecutionRecoveryBridge | 11 条深拷贝警告 |
| 原有 AgentApplicationBackend、RdbMemorySnapshotBackend、RdbSnapshotBackend | 3 条 await-thenable 错误 |
| 新增 ChatExecutionStore | 7 条深拷贝警告 |
| 新增 InvoiceTypes | 2 条深拷贝警告 |
| 新增 RuntimeChatSession、RuntimeSearchSession、SearchRuntimeAssembly | 各 1 条深拷贝警告 |
| 新增 SearchUsageReceipts | 5 条深拷贝警告 |

合计 28 条警告 + 3 条错误，比旧报告多 17 条。当前门禁阻止任何诊断，不能因为 warn 就忽略。本机引擎另外记录 12 条 `Invalid rule name` 和 9 个 `getDeclaringMethod` 文件分析异常；不能将 31 条诊断视为全工程完整检查。9 个文件与交接报告所列范围一致。本机 HPAuditor 日志仍显示 12 项 no-unsafe 规则启用，而 ArkPerfCheck 报同名规则无效；只能确认多阶段分派不一致，不能凭 ruleSet 或单一阶段日志断言它们从未执行，也不能证明检查完整。保留配置和日志阻断，待核对 runner 原始证据后再决定修复或受控例外。

本机原始报告及日志：`.local/ci-lint/20261024-194918-815-b60fa440/`。统一证据：`.cache/test-logs/2026-10-24-ci-latest-lint-review-32ad881/`。本机检查器退出 0、门禁退出 1；远端摘要记录检查器退出 1，两者都因诊断与覆盖不完整而拒绝，不能混淆工具与门禁退出码。

复现（不发起搜索/模型请求）：

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:JAVA_HOME = 'C:\Program Files\Huawei\DevEco Studio\jbr'
$env:CAPTURE_HOST_ONLY = '1'
$env:RUN_CMD = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/ci-lint.ps1 -NodeScript "C:/Program Files/Huawei/DevEco Studio/plugins/codelinter/run/index.js"'
& 'C:\Program Files\Git\bin\bash.exe' scripts/capture-test-log.sh ci-latest-lint-review
```

处理顺序：修复 28 处报告中的深拷贝并覆盖嵌套隔离；保留 await 的异步语义并复现误报；单独处理规则分派及分析器崩溃。交接报告中的浅克隆历史缺失和 MinerU 测试缓存问题仍在代码中，但本轮 CI 未运行到对应测试，不能记为这次实际失败项。全量修复后再跑后续构建与回归，不以单纯重跑 CI 替代修复。

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
