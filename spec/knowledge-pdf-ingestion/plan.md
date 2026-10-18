# Implementation Plan: PDF 最小闭环原页标注与片段高亮

**更新时间**：2026-10-18。
**状态**：两项最小修复源码/host/构建完成。此前唯一阶段5部署受登录预检阻塞的报告保留；后续用户明确授权StudioCLI1.3.5/Node24.14.1隔离子进程环境补充构建部署，已成功安装，见ocr-profile-fix-studio-deployment.md。新PDFReview/发布/真实TaskPool由用户手动验收，未自动执行；旧报告不覆盖，不重委派旧验证。
**Input**：/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-pdf-ingestion/spec.md，当前B1–B2、FR-042–FR-048、SC-011–SC-014。
**PROJECT_ROOT**：/Users/zane/DevecostudioProjects/Shuvi-agent。  
**CONFIG_ROOT**：/Users/zane/.local/share/deveco。

## Summary

当前修复只处理已确定的两项：规范化显式支持 `3.4.4 / hybrid / medium` 的OCR boolean false变体；后台失败通过具名、可序列化且运行时校验的信封保留安全类别/阶段。页脚维持明确排除，不更改ZIP、结构/CRC/预算限制，不重发任何服务请求。

复用新33页PDF现存的一个Failed候选及原ZIP，只恢复到AwaitingCoverageReview，不批准/发布/向量化。旧true快照/343块/向量和原页展示源保留；本节及下列“当前修复”条目为本次设计，旧原页/高亮设计继续作为既有职责，不重做。

复用ROUND2已实施的单entry、V1及knowledge五层、普通库＋派生向量库架构，保留当前343块/向量/快照/原件身份，只补原页证据、片段命中分类/高亮、直接优先与相似明确标注。本次不做生成回答、不要求原PDF区域叠加、不跑完整16题质量、不重发MinerU或文档embedding。

历史完整设计的已实施职责仍适用：安全ZIP/typed JSON/结构表格与公式/TaskPool、严格快照读回、Asset Store隔离凭据、独立外发授权、普通库活动指针/向量空间/资格镜像、pin/读租约/持久cleanup、统一历史/截止与失败恢复。实现演进及历史取舍保存在本目录ROUND2各报告和round2-plan.md，不将早期“未实现/只差Key”状态作为当前事实。

## Technical Context

当前修复沿用下表技术基线；不新依赖/权限/SDK、数据库引擎或架构层。错误信封是线程内外的数据合同，不把普通对象原型保留当先决条件；所有7个PDF后台入口（normalize、chunks、seal、verify、encode node、hydrate node、hydrate header）采用一致失败合同，范围限这些现有入口。

| 项目 | 当前增量 |
|---|---|
| Language/Version | ArkTS严格模式，HarmonyOS26/API26/Stage，既有SDK/依赖不升级 |
| State Management | 保持@Component/@State/@Link V1；服务快照订阅，不迁V2/MVVM |
| Dependencies | 复用ArkData、PDFKit、ArkTS/TaskPool、ArkUI Text/Span及已有Kit；零新增第三方依赖/权限 |
| Storage | 既有shuvi_kb_user_v1.db普通库/扩展、shuvi_kb_vector_v1.db派生向量、shuvi_parse_stage_v1.db解析v3；新增独立页证据/展示历史侧表，不改内容/向量行身份 |
| Target | 当前获准Mate90Pro模拟器，执行前重新枚举对应serial；模拟器不当真机通过 |
| Testing | 保留现host257/counter32及既有suite；新增纯匹配/页证据/历史兼容及正式UI3直接＋1相似场景 |
| Performance | 查询总10秒/现取消与历史pending语义保留；片段最多现有块预算，匹配范围不拆Unicode代理对；额外来源读取计入本次预算 |
| Constraints | 不读Key/.local/签名/私人raw，不卸载/reset/清用户库、不HDC写文件绕过、不commit/push；新语义请求须单独授权 |
| Scope | 当前PDF30页、343块/1024维向量复用；既有20MiB/50页、1万活动PDF块、500MiB及其他保护线不扩大 |

## Project Structure

### 文档

- 当前修复独立记录为 /Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-pdf-ingestion/ocr-profile-fix-implementation.md、ocr-profile-fix-verification.md；旧result-pages/ROUND2/冻结题集不覆盖。当前tasks生成前将旧已完成任务保留为独立历史文件。
- 当前spec/plan/tasks路径固定为 /Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-pdf-ingestion/ 下同名文件；本次tasks后续生成。
- 当前增量报告拟存 /Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-pdf-ingestion/result-pages-implementation.md、result-pages-verification.md、pdf-page-alignment.md。
- 冻结V1：/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-pdf-ingestion/round2-pdf-gold-candidate.md、.json、round2-pdf-gold-freeze.md，均不改；本次只将其中原件参照用于独立页身份核对，不要求整套题评分。
- ROUND2历史与总spec保留：/Users/zane/DevecostudioProjects/Shuvi-agent/specs/02-个人知识库问答.md 只增量当前范围/证据。

### 最小源码落点

当前修复只在以下现有边界及一个纯错误合同模块实施；下表原页/高亮文件为已有基线，不在此次重构。

| 绝对路径 | 当前修复职责 |
|---|---|
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/MineruPdfNormalizer.ets | 严格boolean OCR变体选择、false profile身份；true输出不变，页脚仍排除 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/PdfWorkerModels.ets | 新增具名版本化成功/失败数据与操作/类别/阶段合同 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/PdfWorkerPolicy.ets | 新增纯错误数据生成/校验、白名单与安全重建 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/PdfProcessingAdapter.ets | normalize/chunks/seal/verify的主线程校验和TaskPool系统拒绝分支 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/PdfSnapshotWorker.ets | encode/hydrate/seal/verify入口捕获为数据，不直接跨线程丢领域原因 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/PdfWorkerSupport.ets | 复用线程取消与受限数据传递，保留已有边界 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/PdfAssetAdapter.ets | 消费encode/hydrate后台结果时统一校验；图像验证与存储规则不放宽 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/PdfIngestionService.ets | 具体安全错误呈现/失败记录；成功false结果的job profile与当前检查点一致 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/PdfKnowledgeRepository.ets | 仅对允许的未发布检查点同步实际profile；不改旧活动世代或旧处理键 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/PdfStructureCases.ets | boolean true/false及非法profile负例、页脚明确排除 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/PdfWorkerCases.ets | 新增失败信封的版本/非法类型/未知异常/去敏/取消与超时用例 |

| 绝对路径 | 职责 |
|---|---|
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/KnowledgeSearchModels.ets | 直接/相似分类、片段内ranges、结果展示策略与已核页集合 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/PdfLocalModels.ets | 页身份对照证据/节点覆盖、跨页未核状态；不改变已有region模型含义 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/KnowledgePorts.ets | 只读页码解析与证据登记边界 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/KnowledgeMatchPolicy.ets | 新增纯逻辑：ASCII英文字母忽略大小写的词条匹配、范围合并/分类和旧历史兼容重建 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/KnowledgeSearchService.ets | 先本机直接、零直接才获准相似、结果绑定/页码解析/历史展示 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/PdfPageReferenceService.ets | 新增：块节点→已核原页集合，完整性/冲突/旧版校验 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/PdfKnowledgeRepository.ets | evidence正文direct候选、页证据/展示历史侧表增量迁移及来源读取 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/TextRdbRepository.ets | 统一入口新增evidence正文direct候选端口；保留旧M1原search/FTS/wire/历史 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/TextKnowledgePorts.ets | 新direct候选契约，旧candidates/search仍兼容 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/KnowledgeAssembly.ets | 注入只读页码解析与新端口，不重开或重建向量 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/KnowledgeResultCard.ets | 新增复用卡片：Span高亮、直接/相似标签、原页集合/未核提示，实时/历史共用 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/KnowledgeView.ets | 使用结果绑定的展示模型，不使用后来编辑输入；现有独立授权保留 |
| /Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/KnowledgeResultCases.ets | 新匹配/来源/查询路由与历史兼容测试 |

必要的定向来源导出/页审查动作复用现有安全审计与显式诊断入口，若需修改：/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/KnowledgePlatformDiagnostics.ets。仅允许本机资料/非秘密字段，不新增自动云入口或把诊断生命周期接成清库测试。

**Structure Decision**：遵循现有五层，不重构。新增3个小职责源码文件（纯匹配、只读页码服务、统一卡片），其余必要模型/仓储/服务接缝增量修改；不拆更多页面、不新建模块、资源仍属entry/src/main/resources。

## Complexity Tracking

当前修复新增两个纯职责文件（线程模型、校验策略），目的是避免各后台入口独立解释失败；不新增通用全应用错误框架。原快照wire和数据库表布局不更改，不增加新的profile迁移表；仅复用已有job policy字段在未发布检查点事务记录当前实际profile。

无新增依赖、权限或架构违例。两个必要取舍：

| 取舍 | 必要性 | 不采用 |
|---|---|---|
| 来源/展示元数据侧表 | 不修改已发布snapshot/embedding输入及343向量身份；历史增量兼容 | 重做chunk/全量embedding、重写旧M1wire |
| 页级与区域级证据分开 | 当前只要真实物理页，不需要未取证的坐标变换 | 将region验证的geometry条件当页身份必要条件，或provider idx直接+1 |

## Research & Decisions

### F1 明确false变体而非删校验

- **Decision**：版本/后端/effort仍精确校验，OCR必须为JSON boolean；true继续原profile `MINERU-HOSTED-PDF-3.4.4-OBSERVED-1`，false使用独立 `MINERU-HOSTED-PDF-3.4.4-OCR-FALSE-1`。false快照通过既有profile字符串承载实际标志，不向旧快照增加影响JSON序列化/hash的默认字段。
- **Rationale**：新包其余profile及v1/v2/audit全匹配，原版明确在OCR条件拒绝；true原hash/codec已经部署，不能为支持false重写旧快照。两者不是“取消OCR要求”或“接受任何schema”。
- **Alternatives considered**：不篡改包内false为true、不用truthy/字符串兼容、不删除profile校验、不改上游请求is_ocr来重新消耗解析额度。

### F2 跨线程只传失败数据

- **Decision**：PDF后台入口返回PDF-WORKER-RESULT-1信封，主线程验证版本/操作/成功分支及payload，失败只含白名单category/stage、可选安全整数SDK code及有限非敏感定位。业务错误在worker内部转数据，主线程重建KnowledgeFailure；TaskPool自身reject按安全操作阶段归类，不解析任意raw message或靠未知对象强制断言。
- **Rationale**：官方documentId `开发指南/ArkTS_方舟编程语言/ArkTS并发/并发线程间通信/线程间通信对象/普通对象/normal-object`明确普通类实例跨线程只传数据，原型/方法不保留。该资料不证明本件实际rejected Error已丢原型，所以修复处理的是已存在的不可靠契约，而非伪称实测丢失。
- **Alternatives considered**：不从raw error.message猜category、不将任意字符串显示到页面、不用as/any绕校验、不因更好提示自动重试或放松真正失败。

### F3 恢复身份与持久字段

- **Decision**：验证选择一个已存在Failed且无snapshot的候选，经现有resume路径更新epoch/租约并消费原ZIP。既有processingKey保持作为已登记尝试的幂等身份；得到完整规范化profile后，只有当前未发布Staging/Publishable检查点可将已有job profile字段同步为false变体，snapshot与job最终一致。其余Failed候选保留，不新增第四attempt。
- **Rationale**：三个尝试当前无asset/snapshot/chunk，可复用失败任务，无需清理或重解析。processingKey生成时尚未读结果profile，不能为纠正profile而找不到旧候选或创建重复任务。旧Published/Retained禁止回写。
- **Alternatives considered**：不批量迁移旧profile、不开新空库、不中途改ZIP hash、也不重封存旧true活动快照；新产生任务的旧legacy key解释与实际profile分开记录。

### F4 页脚保留明确排除

- **Decision**：33个page_footer保持Unsupported/NodeTypeUnsupported覆盖记录，不新增类型、不算正文。验证到达Review后检查这些排除仍真实可见；不能把“normalize成功”解释为全文识别完整。
- **Rationale**：页脚不是当前硬失败根因，用户选择两项最小修复。
- **Alternatives considered**：不顺带扩展metadata/图像格式/任意profile，也不静默删除页脚。

### D1 直接匹配针对展示正文

- **Decision**：直接候选按现有evidence正文匹配并评分，截断前判断，不以keyword通道/检索前缀替代。匹配策略LITERAL-ASCII-FOLD-1只折叠ASCII A–Z以保持UTF-16长度；中文和其他字符按原字面，现QueryPreparation完整问题/actualInput/terms语义保留。
- **Rationale**：现PDF retrievalText含标题前缀，hit.text是另一个字段；前缀候选可挤占top20，截后筛不能证明零direct。现`terms`是空白分隔短语，不是中文语义分词。
- **Alternatives considered**：不做新分词、不全Unicode长度变化casefold、不改嵌入文本、不把vector候选有词就冒全库direct完整性。

### D2 直接优先、相似独立授权

- **Decision**：可见范围本机direct存在时仅返回direct最终top5，并标vector跳过/无外发；只有direct确为零、非通道失败且当前问题审批有效时才调用既有semantic.searchReviewed。相似候选来自同空间KNN且片段无字面命中，标Similar。
- **Rationale**：符合用户已确认口径，减少不必要外发/工期；现服务授权typed snapshot/10秒截止/历史固定ID逻辑已验，应保留。
- **Alternatives considered**：不保持旧无条件keyword/vector混排默认入口；既有RRF纯策略/独立质量历史可保留用于诊断对照，但本轮生产UI服从direct优先。keyword读取失败不声称“全范围无direct”。

### D3 先核原页内容，保存受限证据

- **Decision**：实施首任务只读导出当前真实snapshot节点的按解析页短锚点/顺序/来源关系，在本机与已核原PDF30页逐页内容身份对照，生成版本化页证据清单，再审查登记。当前nonempty页逐页唯一内容锚点加独立结构/顺序锚点；跨页节点逐项核文本片段/多页，无法证明则部分未核，不猜页。
- **Rationale**：原件30页清单已独立读图，但缓存目前只有结构计数，未提供完整逐页parsed内容；服务内部v1/v2一致或同页数不证明原页。正文不同页反复提及同图号不能当该图在本页。
- **Alternatives considered**：不以向量相似/最近bbox/连续印刷页码自动批准、不把冻结gold反填为parsed事实、不直接开整本sourcepage+1。末页无块不补剩余页号映射。

### D4 页集合独立解析

- **Decision**：新增PAGE-IDENTITY-1证据，不依赖region points/crop变换；绑定原件hash/version、ZIP/hash、snapshot/id/hash、generation、protocol、provider页、原物理页及受审节点/片段hash范围。既有region evidence仍原义不动，任何冲突不取第一条强行通过。
- **Rationale**：当前PdfMappingPolicy对Page也要求region级geometry，且sourceview选中节点读取，不在卡片读取。页身份只需内容对应证据，不能因此宣称region已核。
- **Alternatives considered**：不把一node对应扩成整页/整本；页级证据只覆盖列明的节点及普通页同页完整内容，cross_page/merged节点必须另核。新PDF没有证据时保留审查机制与未核状态，不套当前样包数据。

### D5 高亮与历史

- **Decision**：片段内ranges为UTF-16半开区间，只对应hit.text；重叠/重复匹配合并，原串不改；卡片由Text+Span按段样式区分，不用WebView/RichEditor。结果保存match策略/terms/textHash/ranges/kind及来源页快照侧表，历史读回核当前来源有效性。旧记录用保存actualInput和片段兼容重建且显式标兼容，不改旧行。
- **Rationale**：官方文档已读`FAQ/UI框架/组件使用/行内文本高亮样式设置方案/faqs-arkui-884`，Span属Text子组件，可局部样式。高亮不能混用问题droppedRanges或原文件TextSourceRange。
- **Alternatives considered**：不根据当前输入框重绘旧结果、不把相似无词命中高亮成“命中”、不替换规范化文本/注入HTML。复用Theme做高对比前景/字重，具体Span可用背景属性实施前再核SDK，不编造链式方法。

## Data Model

### 当前修复数据合同

| 模型 | 内容 | 约束 |
|---|---|---|
| 既有snapshot.profile | 原true标识/独立false标识 | 不新增影响旧JSON/hash的字段，true字节回归不变；false实际身份可读 |
| PdfWorkerResult | wire、operation、status、payload或failure | 有且仅有合法成功/失败分支，缺/超长/未知版本拒绝；不依赖原型 |
| PdfWorkerFailure | category、stage、code（可缺）、有限定位元数据 | category/stage/操作白名单；数值必须有限安全整数；无正文/URL/认证或raw message |
| 既有job policy | profile与已有normalize/filter/chunk策略 | 未发布且身份/epoch有效检查点同步；旧Published/Retained及既有processingKey不改 |

| 实体 | 字段/关系 | 必须校验 |
|---|---|---|
| ResultMatch | policyVersion、kind=Direct/Similar、actualInput/terms身份、textHash、matchedTerms、ranges | Direct至少一非空合法range；Similar有实际vector来源且ranges空；仅前缀keyword不展示为二者 |
| ResultTextRange | start/end（hit.text的UTF-16）、term身份 | 有界、原串回读一致、不切代理对；合并后保持覆盖不串改文本 |
| ResultPageReference | originalHash/version、sourceGeneration/snapshot、physicalPages1Based、evidenceIDs、Unverified/Verified/Partial/Conflict | 无冲突且全部来源覆盖才Verified；Partial分别展示已核页及未核提示，Unknown不冒“原页” |
| PdfPageIdentityEvidence | wire=PAGE-IDENTITY-1、完整原件结果/快照binding、providerPage0、originalPage1、受审nodeIDs/fragmentHashes、uniqueAnchor/structure证据摘要、review版本与原因 | 对照记录和实际只读snapshot关系一致；不可只用任意非空evidenceSource。超出原件页数/身份漂移/冲突拒绝 |
| ResultPresentationHistory | queryID/citationOrdinal、actualInput/terms/策略、match快照、pageRef快照 | 与当前history/片段身份配对，旧版/已删只快照不假可跳；未保存terms的旧记录标兼容 |

页证据与展示记录通过可识别的附加迁移登记；现EXT-2/其他ROUND2子迁移、M1布局和解析v3不重置。保留所有原content/node/chunk/generation/snapshot/inputHash/space/vectorGeneration。

## Contracts & Interfaces

### F-K1 Profile与旧快照兼容

两个已观察OCR布尔分支继续同一结构reader、v1/v2页号/bbox/数量/顺序校验与全部预算；未知profile或非法字段明确拒绝。false用独立profile贯穿worker、seal、codec roundtrip及当前job检查点。旧true节点/coverage/快照封存hash以现30页包和冻结SHA回归，不能“更新golden”来适应不必要改变。

### F-K2 Worker边界校验

先在worker同线程捕获领域异常为合法失败数据；未知异常映射WorkerOperationFailed及明确操作阶段，只有可通过已核具名SDK接口安全取到的数字码才保留，无法取到则不杜撰。主线程在各operation适配入口校验信封后重建本线程领域失败，页面/任务仍保存受控格式 `category / stage`，可增加经校验数字码但不拼raw message。

取消/timeout仍遵守原invalid/deadline/资源finally，不能因为信封结果就当成功；TaskPool自身调度/序列化reject也必须有操作名的安全错误，不被重包成成功。各payload沿现有严格模型/codec验证，不引入unknown/as探测任意字段。测试必须包含非法信封和真实后台领域拒绝；host只能证明纯策略，不能代真实TaskPool。

### F-K3 恢复与验证停止点

获准设备验证时只对新来源选择一个候选（优先当前attempt3 job `kb-4dd55b5a630d1479a70ec5a5a5db913f`，实际选择前重新核绑定和未终止/无快照），正常保数据增量安装后点击现有恢复入口。原件/ZIP身份与52CRC/展开8482133B核对，46图必须实际ImageKit解码/落盘读回成功才能称此阶段通过；随后保存新快照/report并到Review。发现后续不同真实错误应记录并在已批范围内修复，不能偷偷放松规则或自动发布。

不勾partial、不点击发布/向量化，不再申请MinerU、不发任何embedding。旧30页343active/Synced与原件ZIP/历史/凭据状态只做安全元数据读回，不读Key；新report/排除/原页未核保持真实。若用户仅选择build-only，则不点击恢复/做运行时探针，报告仅build/deploy通过，SC-011/013真实平台仍未验。

### 当前修复覆盖

FR-042/043→F1/F-K1；FR-044→F1/F3/F-K1；FR-045/046→F2/F-K2；FR-047→F4/F-K3；FR-048→原安全保护/F-K3。SC-011至014分别以真实新包Review、旧true与负例、真实后台错误边界、零网络及身份保护留证。实际验证范围在阶段3选择并记tasks，不在Phase5再询问UI授权。

### K1 原页对齐与登记

输入为指定只读原件、当前snapshot/节点与chunkSources及原件独立原页参照；输出page-alignment清单、逐节点已核/未核/冲突以及受限证据。脚本/工具若需读取ZIP或snapshot，必须有界、只在已获准的本机cache/应用内部读取，不运行旧不明helper、不扫描其他PDF、不输出整页私料到公共日志。必要受审短锚点保存为独立本机记录/hash，公开报告只最小必要摘要。

先完成对齐，再登记metadata和UI展示。生产source读取租约及epoch沿用；登记事务核原件/ZIP/snapshot/generation匹配，不改snapshot/reportHash，不触发重新确认整个覆盖报告或重新embedding。对齐无法证明时记录具体节点，不把全部功能重新卡成永久RuntimeUnverified。

### K2 检索路由与高亮

PDF与M1统一direct端口先依据evidence正文、当前可见性和词条取候选，完整正确判定在top20前；旧M1原search/candidates兼容保留。结果匹配从result.input构造，不读后来编辑state.question。

本次英文字母大小写折叠不变长度，任一空白term命中即Direct；范围合并和分段由纯策略负责，UI只呈现。直接结果最多5条；直接为空时用户可为当前actualInput计数/授权，复用既有searchReviewed，同空间KNN最多20再最终5；Similar无词条高亮、显示明确标签。零direct时未授权只说明相似查询未启用，不发请求。keyword部分失败则明确范围不完整，不冒全范围零direct。

### K3 页码解析与当前/历史卡片

页解析服务对每个最终hit依据chunkSources读取所有关联node的页证据；只返回已验证1起页集合/未覆盖/冲突状态。卡片显示文档名、Direct/Similar标签、片段内高亮、原PDF第n/总页数或多页、未核状态。历史用保存的actualInput/片段展示；删文档或原件缺失仍保快照和失效标记，不恢复可跳。

打开原件可沿已核物理页跳页，但不新增region叠加验收；完整block跨多页不能只取首node。新metadata缺失时使用明确待核状态而非假page1。

### K4 验证/真实请求

实施阶段先host测试、资料只读对齐与代码交付，不运行独立验证阶段；验证由一次spec-verify处理build/deploy以及tasks记录的UI范围。若正式相似场景需1次真实问题embedding，在验证开始前由父agent通过question确认精确问题/次数/免费资格；不得在Phase5再question或借旧scope发请求。若没有授权则不发、记录该项未执行，不以注入结果代替真实相似链。

建议验证输入：三个直接词条分别覆盖正文中文、英文大小写、多词/重复高亮；一条取自冻结题集的自然改述，实施对齐后先证其在当前展示片段范围无字面匹配，再请求用户确认一次外发。禁止为保证验收命中而改题意或源内容。

### 需求覆盖

| 当前需求 | 设计 |
|---|---|
| FR-033/034 | D3/D4、页证据模型、K1/K3：先原页身份、全部节点覆盖、冲突和跨页显式 |
| FR-035/036 | D1/D5、匹配模型、K2/K3：正文直接判定、ASCII不变长匹配、真实range/Span |
| FR-037 | D1/D2、K2：截断前正文direct、存在则无云请求 |
| FR-038/039 | D2、K2/K4：同空间Similar、typed同意/免费/无伪高亮 |
| FR-040 | 侧表增量、K1/K3：保留343向量与全部身份/存量 |
| FR-041 | Summary、K3/K4：不做regionoverlay/LLM/整套私料质量，旧未验不改PASS |
| SC-007–010 | 3个direct＋1个获准similar，页集合/实际Span/不重传和新源码build/deploy回归分别留证 |

## Changelog

- 2026-10-18阶段5：14ets checker一次clean、实际default/entry/debug build1/10 RC0，无源码修复；只读复核唯一Mate90Pro/127.0.0.1:5555。原脚本一次RC1停在登录预检，未签名合成/内部build/run，无safe signed产物，不以login/新签/卸载绕过；模板前后SHA不变/diff0。T007构建PASS，T008已处理但部署INCOMPLETE，最终build-only INCOMPLETE；host沿用实施，零UI/runtime/恢复/生产profile更新/provider，新Review及真实线程未验。权威ocr-profile-fix-verification.md，不改F-K3范围、不reinvoke。
- 2026-10-18阶段4：按F1–F4/F-K1–3完成当前两项修复；成功payload以原codec字节分片及显式chunk reader细化，KnowledgeFailure仅加可选安全数字码，额外PdfLocalAudit直接verify调用方同步合同。14ets/299host/32counter/精确旧SHA/新包覆盖及零设备外发边界见ocr-profile-fix-implementation.md。无新依赖/权限/SDK或表迁移，T007/T008尚未执行。
- 2026-10-18：阶段1确认两项最小修复；新增明确false profile/true快照字节兼容、版本化worker失败数据、当前同任务未发布检查点profile同步与页脚明确排除。旧原页高亮设计及报告保留；本次无源码实现。
- 2026-10-17阶段5：按本轮build-only只执行17ets checker、2次实际build（含缓存signed脚本内部1次）和1次skip-build部署，全部成功；无源码修复，无UI/runtime/新provider/生产页登记或查询，模板字节恢复。记录当前最终制品/指纹/证据，不改变K4以后真实similar须独立授权与SC页面未验状态，不重新调用验证。
- 2026-10-16历史设计：已批准的M2-B安全解析、普通库＋派生向量、独立授权与生命周期架构；ROUND2演进和实际失败/修复结果见round2-plan/implementation/verification/closeout报告，未删除原报告或冻结题集。
- 2026-10-17当前增量：用户收紧为真实原页标注、结果内词条高亮、直接优先与相似明确标签；保持已实现架构/数据，新增匹配策略、页级证据/解析和复用卡片职责。实际原页对齐/代码/新验证仍未执行。
