# Implementation Plan: 统一 ParsedDocument 与图片知识检索

**版本/状态**：v0.1，待阶段2设计评审。  
**输入**：`/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-unified-parsing/spec.md` v0.1已获用户阶段1批准，文件头保留生成时点。  
**PROJECT_ROOT**：`/Users/zane/DevecostudioProjects/Shuvi-agent`。  
**CONFIG_ROOT**：`/Users/zane/.local/share/deveco/`。  
**基线**：HEAD `c78d79839f9a16aeee71aa2f91a57a3c1df87112`及现M3/M4已修改/未跟踪实现；不回滚或重算旧生产资料。  
**当前操作**：只读接口、官方文档研究和规格编制，无源码修改/测试/构建/设备/业务请求。

## Summary

新增真正格式中立的ParsedDocument生产合同和公共消费管线：四类现有入口在旧profile/逐字对应/人工覆盖确认/旧分块之前输出统一正文、顺序块、独立图片资产及真实解析身份；格式内部知识只留在上游适配器。新知识存储、公共分块、自动发布、视觉标注、文本向量和双组检索不再调用四套格式专用入库服务。

旧仓储/codec保兼容读与资产保护，新的统一关系表放现共享普通库，用独立精确布局；新文件根独立注册。先本机批量迁移生成统一内容和图片，再由明确历史批次升级执行视觉及新统一空间重嵌入。本机迁移与云端队列物理接口隔离，不因自动处理设置已开启而发送历史全集。

统一查询会话先增量发布Direct及本机tags；当前语义获准后至多一次问题嵌入，为正文和图片代理提供同空间候选。两组各自游标、状态及失败，图片全会话按字节hash与有效标注版本合卡，已展示前缀稳定，迟到结果只追加新卡或更新命中原因。

## Technical Context

| 项目 | 选择与约束 |
|---|---|
| 平台/语言 | 现HarmonyOS/API26、SDK26.0.0.105，严格ArkTS/ArkUI，phone/tablet、单entry。Python dataclass仅合同参考，不引Python。 |
| 架构/状态 | 沿domain/pipeline/application/infra/ui及V1、单pages/Index二级视图；不迁MVVM/V2、不重写导航。 |
| 依赖/权限 | 现ArkData/CoreFileKit/ImageKit/ArkTS taskpool/util、RCP、AssetStoreKit；不增包/权限/SDK/Native。视觉接收方DeepSeek为用户本轮明确指定。 |
| 存储 | 保现普通/向量/解析三库名；普通库新增`upd_*`精确表族，原件和包继续原owner；统一图/快照放`knowledge_unified_v1`新受管根。 |
| 文档生产 | TXT/MD本机生产、MinerU结果适配PDF/图片/DOCX；普通消费端只认ParsedDocument，不按文件格式选择旧仓储。 |
| 图片资产 | 独立完整图片文件，原图/服务派生图/原件内media区分，字节asset与出现位置occurrence分离；相同字节不强合人工标注。 |
| 视觉 | DeepSeek deepseek-flash，独立配置/凭据alias、图片data URL、固定中文任务、非流式JSON；不附整篇/聊天/图注，不额外OCR。 |
| 嵌入 | 沿已有文本服务配置及能力证据，新增统一策略/空间`UNIFIED-KNOWLEDGE-TEXT-1`，不是改名旧向量。自动全量，不强制三块。 |
| 查询 | 一个可撤销会话/一个问题embedding Promise，新空间精确KNN；Direct/tags独立展示/分页，同图全局upsert。 |
| 测试 | 独立限定合成/公开兼容host；平台、真实服务、内容质量、UI与迁移全集另分证据；阶段3选择build-only/build+ui。 |
| 操作 | 初始真实业务请求0，不读Key/生产库调查/旧私料，不清库卸载新签强签/Git写，不覆盖旧报告。 |

### 技术保护线

这些是沿现有主流程的资源限额，不是完整格式安全验证项目，不限制正式入口为固定样本。

- 保原件单20MiB、现各入口批量及总原件预算、结果单30MiB/总200MiB和共享派生500MiB。统一根、旧新快照、实际图片、普通/parse/vector文件族、暂存与未物化预留同账；旧新物理副本均计，引用同一文件不重复计。
- 统一包选读展开≤100MiB、单成员≤32MiB；图片作为可预览/可视觉处理资产仍要求真实JPEG/PNG/静态WebP、单20MiB/2000万像素。超预算/不支持保明确图片占位，不把整个可用正文判失败；不执行外链/脚本或自动下载Markdown引用。
- 每文档顺序块≤20000、实际cell≤40000、图片出现≤1000，文字目标块≤2000，全库当前路由文字块≤30000；新旧同文档当前路由只计一次，不把保留旧向量/文件从物理账隐去。图像代理分块也纳全库当前输入计量。
- 快照采用小manifest与有序payload文件：manifest≤1MiB、每payload≤8MiB、单代总≤100MiB并服从共享预算，避免一份巨型JSON与整个文件重复驻留。单文本事件/模型响应等沿有界typed读取。
- 默认本机迁移/解包作业1个、图像完整解码持有1个、视觉请求1个、文本嵌入文档请求1个；问题请求独立优先，不能被长corpus队列/全局busy挡住本机Direct/tags。原生释放Unknown不放资源名额，不声称可硬杀在途。
- 视觉固定单图、原字节base64，`detail=original`；应用请求体≤32MiB、响应≤1MiB、HTTP120秒、连接/无活动30秒，默认关闭思考和stream、输出max_tokens=2048。描述≤2000 Unicode字符，tags≤20/每项≤64字符；这些是客户端默认而非供应商上限。不静默低清/缩图/转码原件，响应超限或HTTP拒绝暂停增强且保图/正文。
- 队列前台派发，进入后台停止后续发送并持久化检查点；本机提交窗口15分钟。普通视图离页解绑订阅，不自动等于撤销设置级授权；显式暂停/设置关闭/凭据变更使后续准入失效。Unknown不自动重发，retry需用户明确重试并接受费用；不后台无限续跑。

## Project Structure

### 文档及文件根

| 绝对路径 | 职责 |
|---|---|
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-unified-parsing/spec.md` | 已批准范围及旧契约替代关系。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-unified-parsing/plan.md` | 本设计及合同。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-unified-parsing/tasks.md` | 阶段3生成任务/验证scope。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-unified-parsing/implementation-report.md` | 真实交付/文件/checker清单与测试证据。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-unified-parsing/verification-report.md` | 本feature唯一权威验证。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/resources/base/profile/backup_config.json` | 增加统一files/cache根排除，保旧项；不擅改普通库既有备份行为。 |

运行期新根为`context.filesDir/knowledge_unified_v1/`及对应cache暂存，内部snapshots/images/annotations/history，文件名由受管ID生成，不用ZIP路径作为输出路径。scope通过现KnowledgeStorageScope提供独立测试根，不硬写生产路径。asset_dir由该根及document/generation相对绑定在运行期解析，不入确定性内容摘要。共享普通库仍可能纳入系统备份，这是既有行为；本次不更改M1备份语义，也不宣称排除了普通库内容，恢复后若图文件缺失按Missing展示，不伪造完整恢复。

### 新增职责落点

以下是实施目标，不是已经生成的源码；允许合并相邻职责，保持接口和单owner边界，不按每实体拆文件。

| 绝对路径 | 职责 |
|---|---|
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/ParsedDocumentModels.ets` | 六核心字段、具名顺序block/inline、images/occurrence、来源/覆盖和统一版本。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/ParsedDocumentPorts.ets` | 解析生产、受管资产、统一消费/迁移/生命周期端口，不引用格式内部模型。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/UnifiedKnowledgeModels.ets` | 下游输入/队列/设置同意、有效标注/空间资格和查询合同。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/ParsedDocumentCodec.ets` | UNIFIED-PARSED-DOCUMENT-1规范封存、运行时校验及payload摘要。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/ParsedDocumentChunker.ets` | 格式无关文字/OCR/公式文本投影与原block范围，非文字占位不造embedding。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/ParsedDocumentStoreLayout.ets` | UPD-STORE-1精确DDL/Committed、升级和旧表共存。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/ParsedDocumentRepository.ets` | 统一内容代/基础关键词/图片出现/tag/标注/作业/路由/引用/lease/清理账本。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/ParsedDocumentAssets.ets` | 原子实际图片/快照写入、读回、引用、预留与清理。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/ParsedDocumentAdapters.ets` | 四类上游输出适配集中注册；格式内部DTO止于此，不把原生对应当正文门槛。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/LegacyParsedDocumentReader.ets` | 精确旧codec/资产读取、本机统一投影、旧ID和hash追踪，不发网络。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/ParsedDocumentIngestionService.ets` | 新导入统一基础校验/发布与自动阶段调度，接现解析任务。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/ParsedDocumentMigrationService.ets` | 冻结本机批量范围/检查点、逐文档迁移切路由，构造不接远程端口。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/VisionModels.ets` | 独立视觉配置/同意/响应/标注版本、cache/attempt与typed端口。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/VisionPolicy.ets` | DeepSeek固定请求/JSON业务校验/finish与usage合同、去敏阶段错误。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/VisionCredentialStore.ets` | 独立AssetStore alias及内部认证fetch，状态只取attributes，Secret不向上返回。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/VisionTransportAdapter.ets` | RCP/base64受限单图请求、网络计量/错误、无额外OCR或上下文外发。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/ImageKnowledgeService.ets` | 自动标注/cache、用户overlay/删除、有效描述tags和索引/语义失效。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/UnifiedProcessingQueue.ets` | Import/LocalMigration/ExplicitUpgrade来源隔离、设置级准入、自动全量、Unknown/暂停。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/UnifiedVectorRepository.ets` | 正文/OCR及图代理统一输入/空间/完整读回/资格，不继承格式仓储或全局旧free假设。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/UnifiedEmbeddingService.ets` | 复用数值/计数能力的设置级费用准入及全量嵌入，保旧workflow兼容。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/KnowledgeQuerySession.ets` | 单问题embedding Promise、撤销epoch/路由、两组游标、全局合卡与幂等页。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/UnifiedKnowledgeHistoryRepository.ets` | 新双组历史快照、固定记录追加revision、旧历史只读桥接。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/ParsedDocumentView.ets` | 统一任务/基础内容/图公式占位、来源级别、自动处理进度。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/VisionSettingsView.ets` | DeepSeek独立配置/密钥输入/设置级自动与可能费用确认，不隐式探测。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/ImageKnowledgeView.ets` | 原图/OCR/描述tags/用户编辑及多父来源，纯图可打开不假OCR locator。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/KnowledgeMigrationView.ets` | 本机迁移与显式历史云升级分栏，固定范围/缺失/费用/进度。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/unified-host-entry.cjs` | 独立精确限定合成套件，不加载旧私料全量runner。 |

### 必要既有修改接点

| 绝对路径 | 边界 |
|---|---|
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/KnowledgeAssembly.ets` | 新仓储/引用保护/队列/查询装配及启动顺序，基础能力独立失败不静默封入口。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/KnowledgeStoreHost.ets` | 同普通库单写队列和统一extension readiness，不新开写者。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/TextKnowledgeService.ets` | M1基础open后先建统一引用保护再旧reconcile/cleanup，TXT/MD新导入统一生产。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/PdfIngestionService.ets` | 新生产出口在旧profile/coverage确认/分块之前，旧任务恢复保原身份。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/PdfAssetAdapter.ets` | V1/V2图片payload原字节导出/流读，旧manifest/hash/parts不写改。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/DocxProcessingAdapter.ets` | 接解析正文及原件media/结果images生产，原生结构仅增强，不旧对应硬筛。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/DocxResultReader.ets` | 已证blocks/Markdown及images提取，未知JSON明确占位/范围而非猜字段。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/DocxNativeReader.ets` | 保原生image/formula/未知object occurrence和顺序，不静默删纯对象段落。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/ImageIngestionService.ets` | 独立图片原件/OCR统一生产，移除新流程人工coverage发布门槛。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/DocumentParseService.ets` | 继续原件/ZIP/远程task唯一owner，接统一引用保护与结果出口，不重申请已收任务。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/KnowledgeDerivedBudget.ets` | 新根、upd元数据/预留与旧文件物理共账，容量不足不清用户资料。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/KnowledgeLifecycleService.ets` | 全部旧owner清理前核新引用，多父图/用户overlay独立生命周期。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/VectorRdbRepository.ets` | 新owner域的独立资格同步及可续KNN页，不因统一升级关闭旧空间同原文档资格。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/EmbeddingTokenAdapter.ets` | 新policy显式计数证据，保旧profile/token算法不改名。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/EmbeddingModels.ets` | 新设置级费用/用途和统一空间/准入模型，旧free/grant字面只读兼容。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/EmbeddingBasisPolicy.ets` | 新policy/profile绑定不拿旧PDF proof直接授权统一文本。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/EmbeddingTransportAdapter.ets` | 保Query发送前guard，新policy当前持久同意/配置复核；不能新purpose绕过guard。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/KnowledgeSearchService.ets` | 新会话增量通知/组级操作，旧路径仅兼容，不Direct排他。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/KnowledgeSourceRegistry.ets` | 新统一策略receipt/候选覆盖/单次准入，旧noDirect不恒置true。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/QueryConsentSession.ets` | 当前实际问题、统一space/费用和会话epoch，编辑/取消/范围配置变更撤在途资格。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/KnowledgeSearchModels.ets` | 双组/原因/卡片/多父/游标/历史新wire，不改旧RESULT1/2/3。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/KnowledgeMatchPolicy.ets` | 只有正文/OCR可Direct高亮，tag/description不冒Direct。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/KnowledgeRetrievalPolicy.ets` | 同space融合/稳定append/卡身份去重，替代全局top5和Direct排他。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/KnowledgeView.ets` | 两组各自加载分页/错误，不用全局embedding busy封本机结果。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/KnowledgeResultCard.ets` | OCR/tag/vector多原因和多父，卡key用图片hash+有效版本，不chunkId。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/EmbeddingSettingsView.ets` | 新统一自动全量与费用确认/工程基线本机设置，保旧配置，不自动检测/列模型。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/pages/Index.ets` | 旧格式入口接新统一流程、设置/队列/迁移/图详情，加载错误可见可重试。 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/entryability/EntryAbility.ets` | 新会话/队列后台检查点，重开不自动升级历史。 |

**Structure Decision**：沿现项目五层及V1，不迁MVVM。本特性跨解析合同、资产仓储、独立视觉、统一向量/查询及迁移，需多职责文件；表中为职责上限建议，不强制一实体一文件。复用通用数值/文件/凭据模式，格式内部DTO止于生产适配器；不先造M5/M6、通用任务调度平台或整套安全框架。公共模型/迁移/生命周期先单owner冻结，其后独立policy/测试可并行。

## Complexity Tracking

六字段统一不能独自承载可核资产/顺序/版本、图级标注与多父关系，扩展具名blocks/images和元数据是已批准合同需要，不是让下游理解PDF/DOCX内部。旧兼容层和新统一消费短期共存，但新数据不再写四套格式仓储；新旧索引通过单一活动路由消重。

对系统备份只新增新文件根排除，不擅改旧普通库备份语义；对旧metadata/space同意保原字面，新增策略而非重命名。复杂格式缺可靠表示时占位/partial，不恢复旧逐字门槛阻全文，也不以无限兜底伪造图公式内容。无新增依赖或权限例外。

## Research & Decisions

### 1. 统一合同位于旧筛选之前

**Decision**：四producer在旧格式专属profile/原生对应/coverage人工确认/旧chunker前输出同一合同。新消费端只接规范化文本、具名顺序block/inline、图片引用、公开来源类型和可选定位；parser_signature准确绑定已知生产者/参数/adapter版本，不强求供应商未报告版本。blocks缺失时明确Markdown文字投影，图/公式引用仍有occurrence。

**Rationale**：现DocxStructureChunker跳过无correspondence节点，旧仓储读回又重算同一路，字段包装不能解决25块覆盖问题。PDF严格profile亦不应成为新公共知识的格式硬门禁。

**Alternatives considered**：统一结构内部继续调四旧服务、删除所有校验、把Markdown包为M1、擅自给原件定位均拒绝。保原件/包身份、必要typed结构与资源检查，来源降为块级而非造原生证据。

### 2. 图片实际文件与出现位置分离

**Decision**：asset按实际字节hash/真实格式持有独立完整文件，occurrence按父document/generation/block/inline顺序、OCR/图注/来源定位和provenance保存。PDF V1/V2通过已有manifest/parts完整核验导出原JPEG，不转码；V2容器manifest hash和图payload hash分别记录。DOCX原件media与结果images分别提取、同字节可关联但不因同名或相近文本猜唯一位置。无引用但有效图可文档级未知位置保存；缺资产或编码不支持仍有occurrence及原因。

**Rationale**：PDF已有分片资产，DOCX只有hash没有文件，单assetId无法承担跨父/多OCR/用户overlay归属。物理字节共享不等于人工标注共享。

**Alternatives considered**：仅保ZIP、把图文件在模型调用时临时解出即弃、按文件名认同图、扫描全页等同原生嵌入图均不采用。相同图hash有不同有效标注lineage时不强合，原生与服务派生provenance不可升格。

### 3. 独立新表族和本机批量迁移

**Decision**：共享普通库新`upd_*`表族+UPD-STORE-1布局/DDLhash/Committed，旧`kb_*`和parse精确表数不改、不加第五legacy source。统一路由表以(namespace,legacyDocumentId)或新documentId追踪当前generation，旧ID不变，不按原件hash合并文档。迁移冻结清单和输入身份，先持有→旧codec校验→新产物/图文件→公共索引读回→逐文档CAS切路由；失败保旧active。写入账本恢复rename与DB非原子阶段。

**Rationale**：旧扩展严格DDL/registry，任意加kb表会使opener失败。当前M1启动立即cleanup，新引用保护必须在旧清理前建立，否则迁移链接可能被回收。

**Alternatives considered**：新开第四库、重命名旧表/重封旧wire、忽略任意未知表、迁移构造注入网络端口、缺包自动重解析均不采用。新根实际占用与旧副本共账，缺恢复图片可Partial迁移文字并明确失败，不缩分母。

### 4. 设置级自动工作流与历史隔离

**Decision**：视觉与文本嵌入各自独立设置快照包含enabled、recipient/model、输入类别、自动处理、可能费用、revision/policy；旧free不伪设true。自动新导入作业标Import；LocalMigration不可被自动远程调度；ExplicitUpgrade才可发送被冻结历史批次。工作项按图/实际inputHash/有效版本/space/prompt/config形成幂等键。后台停派发、前台可续，显式暂停保检查点；已开始结果不确定为Unknown，用户明确重试才能再发，不后台盲重试。

**Rationale**：用户已拒逐图和前三块门禁，但不是无限外发或配置改变后沿旧同意。历史本机迁移0网络与默认新导入自动必须在端口和持久来源上分清。

**Alternatives considered**：把设置开启当历史全库许可、在页面渲染触发请求、逐图反复确认、先三块后续跑作生产前置均不采用。恢复只执行当前有效已授权工作，不因此重启MinerU旧task或新增OCR。

### 5. DeepSeek视觉合同

**Decision**：独立视觉alias/配置，不加入嵌入provider枚举复用秘密。通过用户指定文档确认的Chat Completions消息和image_url data URL，单图+固定中文任务；非stream、关闭thinking、JSON object、detail original、max_tokens2048。只接finish_reason stop后继续typed校验description/tags，允许tags空数组不强凑；不接OCR/confidence/分类/模型回传资产身份。成功缓存含实际imageHash、recipient、model、prompt/schema/有效参数版本；用户覆盖另层。

**Rationale**：指定文档已核支持deepseek-flash和图片JSON方向，但无具体单图/请求体/计费/保留完整限制；JSON模式只保语法不保业务字段或内容正确。Base64增量约4/3，20MiB图约26.7MiB，必须计请求字符串瞬时资源而非强制PixelMap。

**Alternatives considered**：用MinerU vlm当tag模型、整篇/聊天上下文一起发送、默认low缩图、Files API上传或远端URL拉取、把reasoning_content当description、截断JSON修补成成功均不采用。HTTP错误/length/filter/tool_calls/resource/aborted等暂停单项，usage缺失记未报告、response ID非幂等凭证、fingerprint非权重版本。API页未给单价/账号免费/失败计费/留存保证，设置明确可能收费；本轮真实请求0，不请求balance/models/probe。

### 6. 当前有效标注不等于OCR内容代

**Decision**：Auto记录和UserOverlay/tombstone分开，effectiveAnnotationId是全局可比较lineage+revision/hash。编辑事务更新当前有效描述tags、tag索引、代理向量资格失效和幂等待嵌入项，不动未变正文/OCR代或Direct。重跑只更新自动层，用户修正/删除仍覆盖，删空不发空embedding。

**Rationale**：旧Image/Docx epoch同时影响正文可见性，简单复用会让编辑tag导致OCR命中消失。不同父文档的用户修正不能因同图hash默认互相覆盖。

**Alternatives considered**：同图各文档都叫版本1就合卡、把描述写进OCR、重跑覆盖用户修正、等新向量生成后才撤旧代理资格均不采用。相同自动cache和无覆盖可共享有效版本，用户分叉保独立卡身份和归属。

### 7. 一个统一语义空间与全量覆盖

**Decision**：新policy/preprocessing `UNIFIED-KNOWLEDGE-TEXT-1`，实际发送文本规则统一：正文/OCR是ParsedBlock确定文字投影；图代理是当前description、一个换行及以换行连接的有效tags，空字段不制造占位文本，tags按有效编辑顺序、trim后精确去重，显示与向量使用相同最终文本。上下文前缀不默认附加。长文本目标512scalar/2048UTF8有界切片保所属范围；非文字图片/未知占位不生成假文本向量。新baseline按(config,policy)存接受，计数复用现算法但绑定新policy/最终字符串，不改旧PDF基线。

**Rationale**：旧三种预处理空间不兼容，简单模型/维度相同不等于可混距。正文及图代理需新共同身份，现synchronize会关闭同document所有旧space，必须新owner域/独立sync不破旧活动。

**Alternatives considered**：复制旧向量并改space、旧free=true冒费用同意、沿旧手工dryReview/前三块限制、只实现ImageCorpus不给TXT/MD语义均不采用。正文body owner与图有效标注owner独立expected清单/向量代，逐输入身份/finite/model/dim/hash/读回，全expected后Pending→vector mirror→Synced，文档总体可Partial但每个owner就绪不缩分母。新空间未升级清楚报告，不能因单个旧资料未升级封新合格候选，也不能假全库覆盖。

### 8. 新purpose准入与一次query会话

**Decision**：传输仍以Query执行发送前guard，新策略版本 `UNIFIED-KNOWLEDGE-QUERY-1`贯穿review/approval/receipt/grant/admission。仅新策略取消Direct排他，保当前问题同意、费用范围、持久revoked/settings revision、credential/config、query epoch、当前候选清单和资格重核；单次消费。旧诊断trial策略不授权新查询。

**Rationale**：旧DirectNoEgress有reviewScope、registeredSearch、admission和directFirst四层，只删按钮或把noDirect恒true不可靠。当前大scope缺升级不是候选资格未知，应把Direct、升级覆盖与扫描一致性分开。

**Alternatives considered**：新增非Query枚举绕guard、每组/格式各embed、翻页再次searchReviewed、凭内存approved不查撤销均不采用。会话一Promise/一个成功query vector或一次物化候选，分页复用；失败/Unknown不因翻页重发，显式重新查询是新会话。问题编辑/清空/取消/范围配置变化递增epoch并撤在途采纳；网络await后再核身份，不让旧结果覆盖新问题。

### 9. 双组稳定分页与图卡全局归属

**Decision**：组1 LocalDirect，组2 LocalTags+UnifiedSemantic（正文与图代理同一vector路）；独立busy/error/cursor/exhausted。Direct和tags本机核验即emit，不等远程；语义失败只改语义子状态。页面默认每组10新卡；重复/失效候选消费上游位置但不占新卡位，继续补足直到真实耗尽或明确预算，不把尚在加载当耗尽。

**Rationale**：旧全局top5、每路top20、单busy/单10秒await会吞迟到结果和分页。旧KNN可复用数值存储但须可续候选/距离并列稳定顺序，不能事后排序弥补SQL任意截断。

**Alternatives considered**：每次重算整个RRF数组导致已展示卡跳位、向量失败清tags、只第一页去重、一次页全部图造成内存无限均不采用。精确同space KNN资格前过滤、固定64目标分区可保；候选缓存按新空间当前清单有界逐页/物化，稳定(distance,owner,chunkId)顺序，限制是当前全库3万输入而非任意top20。tag与vector融合先按卡身份去重，每路每图只一票，保原距离/证据。已展示前缀固定，迟到只原位追加原因/parents或向后追加新卡，不声称最终全局排序。

OCR Direct图片归组1需全查询范围成员集或每图本机Direct核定，不能因为Direct在第二页就先把图发到组2再搬走。会话全局cardKey=imageByteHash+effectiveAnnotationId；无标注有明确None身份，Unknown不补版本1。相同字节多父/不同OCR证据各保范围，标注分叉不强合。迟到证据只采同session/hash/effectiveVersion，编辑/删除后的旧卡明确旧版/不可用。

### 10. 新历史版本和生命周期

**Decision**：新 `UNIFIED-KNOWLEDGE-HISTORY-1`保存双组已展示卡/原因/父来源、查询策略/coverage/排序、页修订。固定recordId独立append revision幂等结算，失败不锁住查询/翻页；旧RESULT1/2/3和TXT history原reader桥接不重封。历史不保存可用来恢复新外发的query grant或隐式持有完整query vector。

**Rationale**：旧save同ID直接返回、最多5条，无法追加tags/迟到语义和多页。生命周期必须先保护旧owner引用，再允许旧启动清理，否则新迁移关系存在也会被删原件/包。

**Alternatives considered**：复用旧history overwrite、关闭页面就清原图、删父文档就删同hash所有图/人工标注、只靠可漂移整数refcount均不采用。引用事实表统计，父删除先tombstone/epoch/撤资格/停任务，释放其refs；有其他refs/lease在途仍保资产和标注，最后引用且无claim冲突才owner清理。用户overlay沿lineage，不随重新解析代覆盖。未知文件仅报告占用不自动删除。

### 官方资料与实证边界

- DeepSeek依据仅用户给定《Chat Completions API》页面：明确deepseek-flash、image_url data URL/JPEG/PNG/GIF/WebP、detail模式、json_object、finish reasons及usage定义；未核实际视觉质量/单价/留存/单图或base64请求限制，不猜免费或额外API。
- 已核平台document IDs：`API参考/安全/Asset_Store_Kit_关键资产存储服务/ArkTS_API/ohos_security_asset_关键资产存储服务_/js-apis-asset`；`API参考/ArkTS_方舟编程语言/ArkTS_API/ohos_util_util工具函数_/js-apis-util`；`API参考/网络/Remote_Communication_Kit_远场通信服务/ArkTS_API/rcp_数据请求/remote-communication-rcp`；`API参考/Core_File_Kit_文件基础服务/ArkTS_API/ohos_file_fs_文件管理_/js-apis-file-fs`。
- AssetStore沿DEVICE_UNLOCKED/SYNC_NEVER独立alias，不设置需额外权限的IS_PERSISTENT；Base64Helper异步BASIC无换行；RCP显式禁redirect、verbose及plaintextInException，auth只准确接收方，配置保存不触probe/list/balance。
- 备份官方目录`开发指南/Core_File_Kit_文件基础服务/应用文件/应用数据备份恢复/应用接入数据备份恢复/app-file-backup-extension`可用于核新根排除；不将目录排除外推为整个普通库不备份。
- ImageKit尺寸/静态能力、数值向量SQL、异步取消/跨线程、原子文件读回等实施前仍需精准官方/SDK复核及获准平台验证，不能把旧源码存在当本feature已测。当前所有业务请求/测试/设备0。

## Data Model

| 实体/版本 | 必需字段和验证合同 |
|---|---|
| ParsedDocument | 六核心字段原名；wire/version、documentKey/generation、sourceVersion、公开format、selectedOutput/nativeLocation/imageRecovery三类coverage、warnings、blocks/images。asset_dir运行期解析、不封本机绝对路径。source_hash为原件字节。 |
| ParsedBlock/Inline | stableId/parentId/order/kind、实际text/markdown范围、有序inline、表格cell/关系、imageOccurrenceId、formula表示、evidenceType、可选locator/limitations；容器与叶正文不重复索引。 |
| ParsedImageAsset | assetId/owner/root/path、payloadHash/bytes、实际mime/dimensions/processingState、可选legacyContainerHash/原件或结果member；真实文件Ready前无视觉资格。 |
| ImageOccurrence | parentDocument/generation/block/inline顺序、asset引用或Missing、provenance/可选native locator、独立OCR/caption版本、annotationLineage和当前effective版本；相同asset有多occurrence。 |
| ImageAnnotation | Auto、UserOverlay、Effective分层，baseAutoId/revision、description/tags、删除抑制记录、prompt/schema/model/config生产身份及response receipt；用户版不同不强合。 |
| ProcessingSettings | vision/embedding各自enabled/recipient/model/credentialRevision、自动模式、输入类别、costAcknowledged/policy/revision、paused；不是旧free=true。 |
| ProcessingJob/Attempt | origin=Import/LocalMigration/ExplicitUpgrade，batch/input清单、owner/effectiveVersion/hash/config/prompt/space、stage/checkpoint/expected/completed/attempt/outcomeUnknown、持久准入和取消世代。 |
| UnifiedTextInput | ownerNamespace/ownerId/content或annotationVersion、source/evidence、ordinal/actualText/inputHash、block或imageOccurrence关联；正文和代理都同文本policy。 |
| UnifiedIndexBinding | expected清单/hash、content/index/vector代/space/epoch、readbackHash、Pending/Synced/Partial/Invalid，资格核普通库当前版本与向量读回镜像。 |
| MigrationReceipt | 固定batch/inputIds/旧namespace与文档/generation/wire/hash、统一候选/asset写入阶段/CAS前后、Complete/Partial/Failed、缺缓存原因；没有云端permit。 |
| QuerySession | actualInput/hash/query epoch、config/space/queryPolicy、当前费用同意/撤销修订、候选资格快照/未升级coverage、唯一attempt/Promise/result、Direct/tag/vector子状态、全局card registry/已发布集合。 |
| ResultGroup/Cursor | groupId/session/candidateRevision/sortVersion/publishedSeq、上游消费位置、cursor/pageRevision、loading/error/exhausted；相同cursor幂等，新卡补足不计重复。 |
| KnowledgeCard/Reason | text或image身份、imageHash/effectiveAnnotation、OCRDirect/Tag/Vector原因各自text/range/version/distance及所有parents/locator/current-state；不把所有证据揉成一段原文。 |
| UnifiedHistory | 固定recordId、wire/快照assetHash、revision/幂等pageEvent、当时双组已展示卡与策略/原因/父来源/版本、保存状态，不包含Key或可恢复外发凭证。 |

### 最小关系表合同

`upd_meta`精确layout/DDLhash/Committed；`upd_document/generation/chunk/index_binding`承载统一活动内容和输入资格；`upd_asset/image_occurrence/asset_ref/asset_write/read_lease/cleanup`承载真实图片/出现/引用事实与恢复；`upd_annotation/tag`承载标注lineage/有效tag索引；`upd_settings/grant/batch/job/attempt`承载设置同意、来源隔离和持久请求意图；`upd_legacy_link/history`承载旧身份/新历史。vector数值仍在原向量库新space表，普通库的新向量任务/input/readback行可并入上述job/index_binding的明确子表，不借旧格式SQL。

所有表有完整具名DDL清单/版本，未知/缺表不清库修复，only新extension降级；关键引用同generation/owner，计数非负、state合法。大正文/blocks保受管快照，索引只必要文本；新metadata计共享普通库物理用量与待预留，精确前缀进入估算。旧数据库表/文件名/DDL、oldsnapshot/hash/oldspace不变。

## Contracts & Interfaces

### 统一生产和自动发布

producer只输出统一合同和受管asset写入请求，受管路径由assets生成；upstream接受parser-specific信息完成typed验证和对应证据，不向公共repository泄漏旧类。新content验证失败保原件/包，selected output有效则基础发布；画像/公式缺转换保placeholder，覆盖是可查看报告，不人工逐项gate。自动关键词后可立刻检索，视觉/嵌入分别排队；new-import设置未开标AwaitingConfig，不假全完成。

统一chunk正文按block/inline可读投影，OCR独立保image引用，描述tags只进代理而非Direct正文。解析来源精确度可Block/OriginalPage/OriginalParagraph/Cell等，必须附证据才能升级，适配器出错不“恢复旧严格gate”阻已提取正文。PDF实际生产不只调用旧strict normalizer再包装；DOCX原native/对应仅有则增强，否则正文仍可用且来源降级。

### 资产写入/释放与迁移

先登记owner/预留→有界写临时→fsync/hash/size读回→atomic rename→DB Ready/引用/CAS；DB和文件非同一原子事务，写入phase可重入。PDF分片先验manifest与parts再导出payload，新图hash核payload而非manifest。DOCX结果images及原件media分来源登记，byte-identical可共享文件，不猜一对一位置。asset_dir不持供应商路径，外链不访问。

迁移scope冻结旧namespace/document/generation及输入identity，逐件旧readers验证新投影，保旧代活动和全部请求账本；新路由发布后Direct不新旧重复。资料发生替换/删除/epoch变化CAS失败保候选并报告，不清旧记录。LocalMigration无network端口；开启vision/embed设置或重启不能把它转成Import；ExplicitUpgrade另有范围与设置/费用版本，失败不缩分母。新owner域确保统一vector资格同步不关闭旧空间同原document的旧eligible。

### 视觉与全量嵌入准入

视觉请求只处理Ready资产，固定模型参数和描述tag schema，Key通过独立AssetStore内部fetch；headers/Secret不出适配器，配置状态只attributes。response壳与JSON内容分层typed校验，model/role/index/finish/字段/长度正确才存Auto；语义准确性单独质量证据。usage缺省NotReported，不补0；unknown finish不采成功。cache依据实际发送图hash而非原文档hash，复用成功不发请求，用户覆盖不因cache更新覆盖。

所有发送在短持久准入核当前settings/费用同意revision、credential/model/recipient、输入hash/version、job origin/batch和未删身份，保存attempt后launch，不持host队列等待网络。自动full corpus遍历固定expected清单全部合格块，预算不够明确Paused不偷偷截断。关闭/配置变化停下一请求，已有完成输入读回可保；Unknown不因重开/翻页/queue自动再发。产品设置级批准不等本轮测试许可，本轮请求0。

### 同次查询和卡片分页

用户输入产生一个session；local正文/OCR扫描和tag召回分别publish，统一semantic only在当前实际问题许可下发一个Query，按新purpose策略重核而非old noDirect。只查当前合格统一space owner，记录未升级/失败覆盖；候选资格未知拒对应route，不把缺reader当空或混旧space。两组与corpus队列无全局busy相互锁死。

每组页大小10，卡global key去重并补页；一次vector可保内存至session结束，或一次候选排序快照，分页均0额外query请求。候选发生有效版本变化读页时复核，不采删除/失效图；问题/范围/配置改动创建新epoch、丢旧游标，旧history结算独立不覆盖新屏。第一组所有OCRDirect图成员集决定跨组归属，tags/迟到vector对同key只upsert原因/parents，已展示前缀不移位。未知标注版本不假合卡，文本语义候选不会被图片合卡误吞。

历史记录随本地页和迟到理由追加revision，固定record幂等重试，保存失败只标pending，不封搜索/分页。旧历史通过旧reader消费，附当前失效状态不改当时文本/命中原因；浏览历史不恢复云请求或偷偷持原图像素副本。

### UI、初始化和交付

现格式入口继续可选文件，选择后的后续任务转ParsedDocument统一页面；设置从知识库/个人页可达，当前正在加载、失败原因及重试明确，不因初始化失败静默不切页。正文/图公式顺序展示，图详情同时显示OCR/图注/AI描述/tags/人工覆盖和父来源。迁移与历史升级各有单独按钮和进度，无隐式后台整库外发。所有业务由service/ports实现，build/render无网络副作用，V1顶层typed state和可解绑listener。

启动顺序先M1基础bootstrap（不立即旧cleanup）→新layout/引用保护→旧extension兼容open→旧cleanup/reconcile→新queue本机恢复；可选embedding/vision配置失败不撤基础仓储ready，不再出现DOCX入口看似死按钮。关闭按query/queue暂停→来源真实资源释放→parse owner→共享store顺序，有Unknown保lease/可retry。

阶段4只实现/获准合成host，平台cases/设备/UI/真实业务留阶段5既定scope及测试许可。独立runner仅精确新源码/自制fixture/已审公开用例，不默认原全量runner、私PDF/ZIP/生产库；真实迁移全集/视觉/语义质量须另列scope授权。本计划不是设计即实现，部分交付报告具体缺口，不把未做adapter/queue解释成仅缺Key。

### 追踪和验收层

| 需求/故事 | 设计覆盖 |
|---|---|
| FR001–006/US1 | 生产出口前移、统一block/inline和images、公共codec/chunker/store、自动基础发布、精确来源降级。 |
| FR007–011/US2 | 独立DeepSeek配置/JSON、设置级费用、自动queue/cache/标注overlay、tag与统一全量embedding。 |
| FR012–013/US3 | 新共同space/owner域、LocalMigration与ExplicitUpgrade隔离、旧codec/hash/active保留和本机CAS路由。 |
| FR014–016/US4 | Query新policy/持久准入、唯一Promise、双组游标/独立失败、卡身份多原因多父/稳定append。 |
| FR017–018/US5 | 引用事实/lease/清理、标注独立修订、历史revision/旧reader只读、预算/新根排除。 |
| FR019–020/全部 | 必要typed资源边界/有据API、零本轮云许可、数据秘密/Git保护及分层报告。 |

必要确定性回归包括四producer同消费、正文不经Docx旧correspondence硬筛、PDF V1/V2图导出payload、DOCX纯图公式/缺图占位、多父/标注分叉、费用/关闭/Unknown/迁移0外发、全量超过3块、同次两组多页query≤1、有Direct仍semantic、迟到失败保本机、排序并列/补页/跨组Direct后页合卡、旧wire/hash/许可和新布局事务。系统文件/资产存储/RCP/Base64/native vector/TaskPool、真实DeepSeek及embedding内容质量、实际迁移/正式UI和真机容量均分别结论。阶段3先确定scope和真实样本/次数，不把build安装或mock向量当这些证据。
