# M2-B 实施报告

更新时间：2026-10-16。**最终实施状态：PARTIAL**。用户已批准 spec、plan 和全部 57 项任务；本轮只处理 T001–T055，未执行 checker/build/deploy/run/UI。代码交付和 host 通过不等构建、平台或用户故事验收。37 项勾选，18 项仍有实现缺口，T056–T057 保持未执行。

## 基线与授权

- PROJECT_ROOT：`/Users/zane/DevecostudioProjects/Shuvi-agent`；CONFIG_ROOT：由原生 HOME `/Users/zane` 解析为 `/Users/zane/.local/share/deveco/`。
- HEAD：`9f5992c3945975b97349767f0c9e0b4777920ecd`。现有 `oh-package.json5` 有效，保留单 entry 工程，不 scaffold、不升级 SDK、不增加依赖或权限。
- 开始前工作区：`spec/feature.json` 已修改；`scripts/paste-to-emulator.sh`、`spec/knowledge-emulator-e2e/`、本功能目录未跟踪。前述非本功能内容保留，不读取或运行 paste 脚本。
- M1 的六 fixtures、golden、TEXT-SNAPSHOT-1、旧 ID/hash/历史/活动索引及 M2-A 原件、ZIP、解析 v3 任务、远端占用、MinerU 凭据均保护。原 217 host 与既有构建/部署/真实 ZIP 闭环仅为历史证据，实施开始时未重跑。
- 不读 `.local`、Key、签名材料或私人 raw 日志；不访问设备、不进行 HDC 写入、不联网调用 MinerU/embedding、不执行 Git 写操作、不清除数据。
- 指定 ignored ZIP 仅允许有界离线结构核对；不复制正文或完整包到 Git/公开日志。离线核包不能改变应用包 `UNVALIDATED` 状态。

## 门禁

无真实 embedding Key。模型列表/固定句检测与 corpus/query 各自授权，免费资格未知为 NoRequest；缺模型专属 TokenEligibilityEvidence 时 corpus/query 为 InputLimitUnverified。Gemini/OpenAI 官方正文未核，网络禁用。硅基 bge-m3 文档 enum 冲突不猜可用性。百炼地域默认未选，不猜模型发现。

真实 zlib 多缓冲/CRC/释放/取消、普通库增量与重开、向量库 FLOATVECTOR/KNN、PDFKit 真正原件、3.4.4 原页/区域映射、UI、语义质量均未验。未证映射不自动准确跳页/高亮，包内服务 PDF 不是原件。

## 分阶段结果

| 阶段 | 结果 | 已交付与边界 |
|---|---|---|
| Setup T001–T002 | 完成 | 保护基线、保留 217 历史用例/六 fixtures/golden；扩展 harness、注入边界、源码摘要及安全 host-only 留档 |
| Foundational T003–T012 | 源码完成，平台未验 | 三组独立模型/端口、普通库单 host/写队列/租约、M1 先 bootstrap、KB-PDF-EXT-1 事务扩展、job/pin 原子登记、M2-A 删除/清理同一保护实例、扩展失败隔离 |
| US1 T013–T018 | 源码/指定 host 完成，真实服务/UI 未验 | 四提供商配置、独立安全别名、地域/接入/Workspace、硅基真实列表适配与手填来源、未核能力禁用；未保存的 UI 改动禁止 Key/网络动作，避免把旧配置当当前接收方 |
| US2 T019–T022 | 源码/指定 host 完成，真实检测未验 | 固定一句、一次请求、零重试、免费未知 NoRequest、真实 float 响应校验、配置/凭据修订失效、状态及可选用量；probe 向量不进语料 |
| US3 T023–T031 | 部分 | 安全容器、native raw inflate/独立 CRC/SHA 实现且运行门禁关闭；有界 JSON/惰性表格/唯一 v2 规范化及离线真实包对照通过。多部分快照/图像/账本和 UI 已有代码，但 worker、恢复/图像校验与平台可执行案例尚未完整 |
| US4 T032–T038 | 部分 | Unicode 结构投影、关键词 staging/审批/事务激活、M1/PDF 候选和一次新历史；真正原件 hash/几何/只读像素预览与手动翻页代码。完整页/区域证据验证、结构图像核对、多区域高亮、恢复与重建入口未完整 |
| US5 T039–T046 | 未完成 | T040 Token 门禁和 T044 同空间 RRF 纯策略完成。固定维度 S3 vector store/读回/KNN 有隔离代码但未取证；真实 corpus/query 作业、覆盖发布/镜像恢复/授权 UI 未实现完整，禁止外发，不标 SemanticReady |
| US6 T047–T052 | 部分 | 归档/删除/放弃/读租约/cleanupClaim 的普通库代码与注入 SQL 边界通过；统一历史只读桥接/游标、四入口与后台暂停已交付。跨库清理、逐故障边界平台案例、全局资产/向量账本和完整 UI 管理尚有缺口 |
| Polish T053–T055 | 本轮回归/审查/如实记录完成 | 保留失败历史；源码修复、249/249 后最终 250/250 host；指定 ZIP 只离线摘要；32 项 FR 审查如下。Polish 完成不将上游未完成任务变成完成 |
| Verification | 排除 | T056–T057 未执行、未勾选，未创建 verification-report；由 parent 后续独立处理 |

**实际勾选**：T001–T022、T024–T025、T027–T028、T030、T033–T034、T038、T040、T044、T049、T051、T053–T055，共 37 项。

**未完成**：T023、T026、T029、T031–T032、T035–T037、T039、T041–T043、T045–T048、T050、T052，共 18 项。部分任务在阶段初评曾勾选，最终按完整验收审查撤回，不能把基础代码存在或安全禁用等同完整交付。

## 未完成项与可行动下一步

| IDs | 缺口/下一步 | 当前安全状态 |
|---|---|---|
| T023、T032、T039、T047 | 已有 host 风险用例和平台案例清单/隔离入口，但不是每个提交边界均具备可直接运行的平台断言。补真实 zlib 多缓冲/取消/CRC、PDF crop/rotation/多区域、ArkData 重开和跨库恢复 case 实体；补独立语义 gold/阈值，不猜私料答案 | 此轮不执行平台/服务；无伪 PASS |
| T026 | typed lexical reader 的字节/深度/单串/key/token 限额与重复 key 检查已实现；尚未迁入后台分段 worker，当前读取 8 MiB 内完整 UTF-8 字符串 | native 入库仍关闭，不能把 host 耗时当 UI 不卡顿证明 |
| T029 | multipart header/node 串分 64 KiB 文件、manifest/part hash、严格模型 hydrate、JPEG 头部像素、exclusive 目录/账本已实现；还需平台读回/中断 rename/启动恢复、完整图片解码可用性验证，避免头部尺寸通过等同图片质量 | 未通过 runtime 门禁不执行生产落盘；保留 ZIP/旧活动内容 |
| T031、T037 | 已收 PDF 动作、审查/部分确认、内存会话恢复入口已连；尚需启动时列出可恢复 job、无快照失败任务的显式重试/放弃闭环、不同结果同原件的完整重建/审批身份补齐 | 相同处理键复用；已放弃/cleanup claimed 不可晚到发布；不调用 MinerU |
| T035–T036 | 只读真正原件 hash、页数/尺寸/MediaBox/CropBox/rotation、Page/Region 策略已有代码；没有本包页身份/变换 gold，UI 仅原件像素手动翻页，未接已证页自动跳转、多区域高亮及完整结构/图像/表格核对 | 默认 ProviderUnverified，无缩放猜测、无伪高亮、无原件改写 |
| T041 | vector:true S3 独立派生库、安全空间 ID/fixed N、Float32 读回/余弦精确 KNN/claim 清理已写；缺完整登记重开/能力结果持久化和设备机制取证 | open() 为 VectorStoreRuntimeUnverified；隔离 entry 不由生产装配调用 |
| T042–T043、T045–T046 | 文档/查询 grant 模型、空间表和 gated 元数据存在；完整 serial 真向量作业、input/readback 覆盖提交、eligibility 镜像同步/恢复、query KNN orchestration 和两用途授权 UI 未交付完整 | corpus/query 一律 InputLimitUnverified；vectorizePdf 仅说明门禁，publishVectors 拒绝，搜索真实显示仅关键词/跳过向量 |
| T048 | 普通库归档/恢复/tombstone/epoch、放弃→ReleasePending、read lease 阻止 claim、物理失败持久重试实现且 host 通过；跨库 vector cleanup coordinator 未完整，retained 世代回收需补 owner 转移/故障矩阵 | 发现 vector generation 时 cleanup claim 拒绝，不释放不明引用，不按年龄 unpin |
| T050 | 新统一入口、PDF 列表/归档/删除、M1 旧视图委托、history snapshots 已连；仍需完整 PDF rebuild/恢复管理与原件/结构核对、布局可访问性实证 | 旧 M1 操作/检索/历史仍可由原视图访问；未迁移旧 wire |
| T052 | 新 PDF/向量派生备份排除已增量；PDF 文件 reserve/实际子树计量已有代码；vector 全阶段占用、missing asset 历史失效、注册 orphan 的恢复/清理账本尚未贯通 | 未注册/超预算/身份不明保留阻止新写，不清库、不自动同步 |

US5 的缺口同时包含**实现未完成**和**真实验证无条件**，不是只差用户 Key。不能在后续 build 成功时将这些任务批量勾选。

## 实际测试证据

### 实际执行

所有测试均经 `/bin/bash scripts/capture-test-log.sh`，`CAPTURE_HOST_ONLY=1 CAPTURE_SAFE_HOST=1`；Node `v22.23.2`、SDK compiler 复用 `/Applications/DevEco-Studio.app/Contents/sdk`，无安装依赖。首次直接运行脚本因文件无执行位被 shell 拒绝，测试没有开始；随后显式 Bash 执行，不 chmod。

证据目录均以 `.cache/test-logs/2026-10-16-` 开头：

| scope 后缀（均接 `-9f5992c/`） | 结果 | 说明 |
|---|---|---|
| m2b-setup-host | RC0 | 保留历史 217 基线重跑 |
| m2b-foundation-host | RC0 | M1/M2-A 回归，M2 测试显式注入未引用 source 保护端口 |
| m2b-us1-host、m2b-us2-host、m2b-us3-host | 各 RC0 | 新策略/固定检测/结构用例。部分输出因敏感词过滤整体 withheld，不读取 raw、不将 withheld 当详细断言证据 |
| m2b-us3-summary | 231/231 | 首次可公开摘要，真实包 70 CRC/结构计数 |
| m2b-snapshot-summary | 231/231 | 指定包所有规范化 node/header typed codec 往返保真 |
| m2b-us4-summary | 234/234 | Unicode 分块、过滤、页证据与 RRF |
| m2b-lifecycle-summary | 236/239，FAIL | 新 SQL 注入用例暴露 generation INSERT 13 占位符/12 列错误 |
| m2b-lifecycle-diagnostic | 1/4，FAIL | 受控诊断确认上述 SQL arity，非 ArkData 失败 |
| m2b-lifecycle-fix | 4/4 | 改为 12 占位符后通过 |
| m2b-credential-lifecycle-summary | RC0 | 受控 credential/SQL focused 回归 |
| m2b-final-host | 244/245，FAIL | 新历史用例空 routes 读为一项空字段，HistoryRouteSchema |
| m2b-history-diagnostic | 5/6，FAIL | 定位空 routes 边界，修为零项 |
| m2b-polish-host | 249/249 | 原用例/新增风险/源码边界全部通过 |
| m2b-polish-final | **250/250，RC0** | 71.967 秒；总 217 历史 + 33 新 host，六 fixtures/golden 不变；无取消/跳过 |
| m2b-implementation-closeout | **最终 250/250，RC0** | 71.985 秒；覆盖最后的规范化预算硬失败修复；无取消/跳过 |

`m2b-polish-final` 的工作区指纹：`38cbedd80a7afa329482b557bfdeb540ee5b867be0536ad8fbc67ab4605c86d9`，dirty_files=56；公开 host-only 指纹明确排除 unrelated paste/私有目录/签名配置。后续报告文字/checkbox 会改变指纹；之后若有源修复须另留最终日志，不复用旧指纹。

**最终源码状态证据**：`.cache/test-logs/2026-10-16-m2b-implementation-closeout-9f5992c/`，工作区指纹 `49eca2f8e1353d4fb2464485702794402ef3e4cae8b898a720f182cd2cc5b313`，dirty_files=57，host 250/250。此日志之后仅回写本报告/记忆/总 spec 的证据指向，不再修改源码。

完整复现命令（本机授权 ZIP 必须仍存在）：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" \
RUN_CMD='node entry/src/test/run-host-summary.cjs' \
/bin/bash scripts/capture-test-log.sh m2b-implementation-closeout
```

聚焦 SQL 诊断可加 `HOST_TEST_PATTERN='Knowledge SQLite'` 并换 scope；credential/lifecycle 聚焦为 `HOST_TEST_PATTERN='Knowledge SQLite|Embedding credential'`。summary runner 在内存消费测试原始输出，只公布计数、固定 numeric ZIP 摘要和受控 SQL 诊断，绝不打开既有 private raw。

### 指定 ZIP 离线结论

- 副本 8,461,084 B；SHA256 `548162c5bb0f6a93d0fe76d4a5a17399f87b0a882c84d4510e7c2ead5fc12a05`；生产通用容器策略接受 70 成员，host zlib bounded 输出 11,926,995 B，70/70 CRC。没有把成员名/正文输出到公开日志。
- v2 主内容 346；340 typed inline formula runs、46 display formulas、7 tables/248 cells、64 唯一 asset 引用均有断言；每个 node/header codec 往返无字段损失。四 JSON 不重复生成文档。
- 5 EmptyText、NoBlocksNotProvenBlank 页 index29、CrossPageUnverified:16、LinesDeleted:5、原件页/区域未知、service PDF derivative 警告有断言。
- host 使用 Node 标准 raw inflate 作为替身并核精确压缩消费、实际长度、独立 CRC/hash；不证明 HarmonyOS zlib，不改变应用 `UNVALIDATED`，不证明 OCR/公式/表格/原页质量。

### 未执行

本轮没有 `arkts_check`、`devecocli check/build/run`、模拟器/真机/hdc/UI、真实模型发现/embedding/MinerU、签名配置读取或 Git 写操作。`git diff --check` 仅空白完整性审阅，不是编译器或验收。后续独立验证只处理 T056–T057，不能替代上述 runtime/内容/语义门禁。

## 计划差异

原 capture helper 默认在 `.local` 创建临时目录，并摘要所有公开未跟踪文件。为遵守本轮更严格的禁止读取 `.local` 与 unrelated paste 脚本约束，T002 同步增加显式 `CAPTURE_SAFE_HOST=1` 隔离选项：只在 host-only 下使用 `.cache` 新临时目录，元数据不检查签名配置，工作区指纹排除保护路径。默认工具行为不改变。

- 新增 `PdfSnapshotCodec.ets` 和 `PdfMappingPolicy.ets`，将纯模型 hydrate/映射证据约束从平台文件分离，host 可真实执行；没有 MVVM/HAR/依赖变更。
- 保留原全部 217 测试。原字节锁定审计针对本次明确批准的 Text ports/repository/assembly 接缝改为增量接口、原 SQL DDL/FTS、旧历史 wire 等值审计；其他受保护源码/golden/脚本仍字节锁定。没有删难例、改 golden 或用新输出重写旧期望。
- 平台用例“准备”目前部分仅契约清单而非完整可执行断言，因此对应任务撤回勾选。US4 页/区域 UI 和 US5 作业不完整时继续做安全独立实现/Polish 清单，未将未满足依赖写成已满足；这偏离严格全阶段完成后推进的原计划，结果必须 PARTIAL，不能称 T001–T055 全部完成。

## 提供商与输入策略证据

本轮重新执行官方 `devecocli docs search/read`：Asset Store API11+ CRUD/ATTRIBUTES/DEVICE_UNLOCKED/SyncType.NEVER 与设置 IS_PERSISTENT 需权限；普通库 Transaction API14+ 与单写约束；zlib API12+ raw -15、ZStream available/total、inflate/getZStream/inflateEnd 和 Checksum.crc32；PDFKit API12+ points/原件几何/只读预览；ArkData vector API18+ S3/vector:true/FLOATVECTOR/Float32Array/余弦 `<=>`。官方声明不当 runtime 通过证据。

另复读 SiliconFlow 官方 List Models/Create Embedding 和百炼官方文本 embedding 同步兼容正文：单字符串、encoding_format=float、data[index0]/model/usage、百炼仅 total_tokens 合法；硅基 embedding 筛选、bge 参数不加 Qwen-only dimensions；百炼北京/新加坡官方 Workspace 以及旧公共接入分开。没有实际请求 API。

目标 bge-m3 文档 context8192、百炼 v3/v4 context8192 仅记录 context；没有建立模型专属请求前 tokenizer/保守上界，因此所有 corpus/query 禁用。没有根据 512 codepoints/2048 bytes、事后 usage 或任何默认比例编造 TokenEligibilityEvidence。NotReported 模型 revision 保持诚实；静默同维更新未可检测。语义 gold/阈值尚无批准，质量评估条目只准备类型，不生成私料题目/答案。

## 安全与 FR 审查

| FR | 源码/host 覆盖 | 结论 |
|---|---|---|
| 001–007 | 四配置/目的隔离、closed destination、无redirect、免费门禁、一次probe/响应/失效 | 源码和注入通过；UI/安全 SDK/真实服务未验 |
| 008–014 | task/original/result 绑定、ZIP/CRC预算、有界 JSON/表格、唯一 v2、独立 locator/coverage | 离线内容结构通过；worker/runtime/资产恢复未完整，不宣称应用已校验 |
| 015–017 | 结构 chunk/前缀计量、关键词事务发布、真正原件手动页 | 部分；区域/结构核对 UI、准确页证据仍未满足 |
| 018–022 | corpus/query 不外发、Float32验证、safe fixed-N 旁库、单keyword+同空间RRF | US5 未完成；不以 keyword 或 probe 冒语义 |
| 023–026 | M1 layout/wire/history/old top5、candidate20；持久pins/job、tombstone/cleanupClaim、统一一次历史 | 普通 SQL 注入关键边界通过；跨库/重开/完整管理仍缺口 |
| 027–032 | 原217/golden不删；指定ZIP元数据；分层日志/报告/总契约、无Key不调用、仅免费 | 250 host通过，语义/平台质量未验；全局预算/可执行平台准备仍部分 |

## 精确文件清单

以下路径均相对 PROJECT_ROOT；不包含已存在且本轮未改的 `spec/feature.json`、paste 脚本和 emulator feature。`TextKnowledgeView.ets`、解析库 schema、M1 models/wire/processing/golden/fixtures、依赖/权限/SDK 文件未改。

### 新增源码（30）

```text
entry/src/main/ets/knowledge/domain/PdfKnowledgeModels.ets
entry/src/main/ets/knowledge/domain/EmbeddingModels.ets
entry/src/main/ets/knowledge/domain/KnowledgeSearchModels.ets
entry/src/main/ets/knowledge/domain/KnowledgePorts.ets
entry/src/main/ets/knowledge/pipeline/SafeZipPolicy.ets
entry/src/main/ets/knowledge/pipeline/BoundedDocumentJson.ets
entry/src/main/ets/knowledge/pipeline/PdfTableDecoder.ets
entry/src/main/ets/knowledge/pipeline/MineruPdfNormalizer.ets
entry/src/main/ets/knowledge/pipeline/PdfSnapshotCodec.ets
entry/src/main/ets/knowledge/pipeline/PdfMappingPolicy.ets
entry/src/main/ets/knowledge/pipeline/PdfStructureChunker.ets
entry/src/main/ets/knowledge/pipeline/EmbeddingPolicy.ets
entry/src/main/ets/knowledge/pipeline/KnowledgeRetrievalPolicy.ets
entry/src/main/ets/knowledge/application/EmbeddingService.ets
entry/src/main/ets/knowledge/application/PdfIngestionService.ets
entry/src/main/ets/knowledge/application/KnowledgeSearchService.ets
entry/src/main/ets/knowledge/application/KnowledgeLifecycleService.ets
entry/src/main/ets/knowledge/infra/KnowledgeStoreHost.ets
entry/src/main/ets/knowledge/infra/PdfKnowledgeRepository.ets
entry/src/main/ets/knowledge/infra/EmbeddingCredentialStore.ets
entry/src/main/ets/knowledge/infra/EmbeddingTransportAdapter.ets
entry/src/main/ets/knowledge/infra/PdfArchiveAdapter.ets
entry/src/main/ets/knowledge/infra/PdfAssetAdapter.ets
entry/src/main/ets/knowledge/infra/PdfPageAdapter.ets
entry/src/main/ets/knowledge/infra/VectorRdbRepository.ets
entry/src/main/ets/knowledge/infra/KnowledgeAssembly.ets
entry/src/main/ets/knowledge/ui/EmbeddingSettingsView.ets
entry/src/main/ets/knowledge/ui/PdfIngestionView.ets
entry/src/main/ets/knowledge/ui/PdfSourceView.ets
entry/src/main/ets/knowledge/ui/KnowledgeView.ets
```

### 修改既有源码/资源（10）

```text
entry/src/main/ets/knowledge/domain/TextKnowledgePorts.ets
entry/src/main/ets/knowledge/infra/TextRdbRepository.ets
entry/src/main/ets/knowledge/infra/TextKnowledgeAssembly.ets
entry/src/main/ets/knowledge/application/DocumentParseService.ets
entry/src/main/ets/knowledge/infra/DocumentParseAssembly.ets
entry/src/main/ets/knowledge/ui/DocumentParseView.ets
entry/src/main/ets/components/FeaturePages.ets
entry/src/main/ets/pages/Index.ets
entry/src/main/ets/entryability/EntryAbility.ets
entry/src/main/resources/base/profile/backup_config.json
```

### 测试/证据工具（新增9，修改3）

```text
A entry/src/test/EmbeddingCases.ets
A entry/src/test/PdfArchiveCases.ets
A entry/src/test/PdfStructureCases.ets
A entry/src/test/KnowledgeIntegrationCases.ets
A entry/src/test/pdf-offline-host-cases.cjs
A entry/src/test/knowledge-store-host-cases.cjs
A entry/src/test/embedding-credential-host-cases.cjs
A entry/src/test/knowledge-scope-host-cases.cjs
A entry/src/test/run-host-summary.cjs
M entry/src/test/DocumentParseServiceCases.ets
M entry/src/test/run-host-tests.cjs
M scripts/dev-run-support.cjs
```

### 文档（新增1，修改5）

```text
A spec/knowledge-pdf-ingestion/implementation-report.md
M spec/knowledge-pdf-ingestion/spec.md
M spec/knowledge-pdf-ingestion/plan.md
M spec/knowledge-pdf-ingestion/tasks.md
M spec/knowledge-pdf-ingestion/context-memory.md
M specs/02-个人知识库问答.md
```

日志只写 ignored `.cache/test-logs/`、harness 产物仅 ignored `.cache/host-tests/`。没有创建/读取其他私人配置、Key 或签名。
