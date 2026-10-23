# Implementation Plan: M1 文本知识库 L0 全链路

**Input**: `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-text-pipeline/spec.md`
**权威总契约**：`/Users/zane/DevecostudioProjects/Shuvi-agent/specs/02-个人知识库问答.md`
**日期/状态**：2026-10-12，阶段 2 设计审核中；未实现、未构建或运行测试。

## Summary

在现有 `entry` 内增加独立用户知识库的领域模型、纯文本处理、应用服务和平台适配器。真实选择器导入 txt/md 原件后，完成 UTF-8/结构/原文映射校验、版本化快照与关键词索引，提供文档管理、检查点恢复及 L0 历史/引用；旧探针库和目录不改不迁移，用户入口不再自动运行 `KnowledgeLab`。

沿用现有目录和 V1 状态管理，不引入 MVVM 迁移、HAR、依赖、权限、云服务、伪向量或生成模型。M1 的本地能力/预算/固定语料门禁先完成，MinerU、视觉、语义和同步对应门禁保持后续阶段。

## Technical Context

**Language/Version**：ArkTS，沿用 HarmonyOS 26.0.0/API 26 及仓库工具基线，不升级。
**Primary Dependencies**：现有 SDK 的 ArkData、CoreFileKit、AbilityKit、CryptoArchitectureKit、ArkTS；不增加 OHPM 包。开发测试继续使用现有 SDK 转译器、Node host runner 与 Hypium。
**State Management**：现项目 V1 `@Component/@State`，保持同一代；页面快照整体更新，避免未观察的嵌套字段突变。
**Storage**：独立普通关系库 `shuvi_kb_user_v1.db`，S3、无向量；原字节/规范化大产物在新沙箱子树 `knowledge_user_v1`，旧 `shuvi_kb_probe*.db` 与 `filesDir/kb` 不触碰。
**Testing**：纯逻辑/应用服务故障注入 host，原六份 fixtures，设备真实选择器/持久化/恢复/清理；构建/部署及是否 UI 验证在阶段 3 固定到任务文件。
**Target Platform**：Phone/Tablet；只有真实目标设备结果才形成平台/资源质量结论，模拟器仅机制。
**Project Type**：已有 Stage 模型移动应用增量功能。
**Performance Goals**：用户已确认单文件 1 MiB、单批10个/5 MiB、库100篇/20 MiB/10,000活动块、索引60秒、查询10秒；这些是保护上限，不是已测试延迟保证。
**Constraints**：无网络/新权限，Kit 仅在适配器，文件/数据库异步且资源关闭，长文本处理不阻塞 UI；所有既有用户/探针/设备文件保留。
**Scale/Scope**：五个用户故事的 M1 文本 L0；不含语义/混合召回、L1、其他格式解析、图像理解或跨设备同步。

## Project Structure

### Documentation

下列文档在已批准目录内生成；前三阶段只编辑工作流文档，不修改源代码。

| 绝对路径 | 职责 |
|---|---|
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/feature.json` | 执行目录指针 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-text-pipeline/spec.md` | 已审核 M1 范围与故事/FR/SC |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-text-pipeline/plan.md` | 本设计与映射 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-text-pipeline/tasks.md` | 阶段 3 生成的实现/验证任务 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/specs/02-个人知识库问答.md` | 阶段4/5仅补M1执行范围与真实证据，保留五稿/历史失败 |

### Source Code Targets

这是阶段 4 的目标与职责描述，不是源代码或实现伪代码。完整路径以此表为准。

| 目标路径 | 操作与职责 |
|---|---|
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/TextKnowledgeModels.ets` | 新增：具名文档/结构/定位/任务/历史/视图 DTO、版本及试运行预算，与探针旧模型不重名 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/TextKnowledgePorts.ets` | 新增：应用边界所需持久化、原件、选择器、CPU处理端口；无 Kit |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/TextNormalizer.ets` | 新增：严格 UTF-8/BOM/换行校验与原文映射、行索引；纯逻辑 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/MarkdownStructure.ets` | 新增：有界结构节点、标题树、列表/围栏/表格/引用；纯逻辑，不渲染或联网 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/StructuredChunker.ets` | 新增：结构块/表头/标题与定位关联、完整索引输入和Unicode边界；纯逻辑 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/QueryPreparation.ets` | 新增：问题保留、条件保留/边界裁剪/提示、字面检索词与可测试排序规则 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/TextKnowledgeService.ets` | 新增：导入/判重/预算/任务取消恢复/发布、管理、查询历史与一致性；无 Kit |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/TextFileAdapter.ets` | 新增：系统选择器、URI元信息、异步原字节拷贝、SHA256、安全沙箱路径、读取/删除 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/TextProcessingAdapter.ets` | 新增：CPU TaskPool 包装与跨线程安全结果验证，不把数据库/Context传入纯逻辑任务 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/TextRdbRepository.ets` | 新增：用户库关系数据、FTS能力验证/LIKE降级、版本发布、任务/清理/历史；单写队列 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/TextKnowledgeAssembly.ets` | 新增：唯一Context/服务/适配器装配和生命周期，页面无平台业务调用 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/TextKnowledgeView.ets` | 新增：列表、导入/任务状态、查询/历史/详情、管理确认，V1和现有Theme |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/pages/Index.ets` | 最小更新：知识库入口装配用户视图、二级视图返回/切页状态，不改变日程/其他页行为 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/Chunker.ets` | 限定修复：旧纯文本切片的字符/空白偏移和标题边界缺陷，保留原签名/覆盖不变量，不改变探针数据 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/TextPipelineCases.ets` | 新增：字节/规范化/结构/定位/查询/预算单元测试 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/TextServiceCases.ets` | 新增：真实应用服务与具名内存假端口的状态/发布/取消/故障/历史测试，假端口不进生产装配 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/ChunkerCases.ets` | 新增严格Unicode/空白偏移回归，保留原18项语义 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/CorpusCases.ets` | 保留原语料回归/标题失败，增加新结构路径检查，不删难例 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/run-host-tests.cjs` | 更新纯逻辑源/用例加载、fixture SHA及结果记录；仍非设备/类型检查 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/eval/text-m1-golden.json` | 新增固定词句/否例/节点与原件范围金标准、fixture哈希；无运行时自动挑答案 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/fixtures/SOURCES.md` | 必要说明本地复用/设备副本/不打包不外发；原六份语料字节不改 |

**Structure Decision**：遵循现有 `knowledge/domain/pipeline/infra/ui`，只增加 `application` 责任层，不迁移全工程为 MVVM。新增约12个生产文件是纯逻辑/平台边界、任务恢复与多视图闭环所需；同类模型/端口/视图集中，不一实体一文件。保留一个 `@Entry`、原Theme与V1，不新建路由、HAR或图标依赖。`KnowledgeLab/RdbKnowledgeStore/PseudoEmbedding/SampleCorpus` 仍是独立旧探针，不由用户入口触发。

## Complexity Tracking

无平台、依赖或模块基线例外。复杂性来自原件保真、结构来源映射、异步任务发布、跨存储清理和历史失效；不能简化为页面直接写库/写字符串样例。旧探针与用户存储不合并，以避免误清空和伪向量污染；这不是第二套数据库技术，仍用 ArkData。

## Research & Decisions

### R1：真实选择器与临时授权

**Decision**：文件选择适配器使用已查的 DocumentViewPicker，普通文件模式、txt/md后缀提示、最多10个。URI读取为临时授权，先异步打开/读取并保存原字节；取消无文档、失败不改源文件。

**Rationale**：官方“选择用户文件”说明不需申请权限，URI临时，退出后台可能失效；后缀过滤不是内容类型校验。新用户库不能继续使用固定title/text输入。

**Alternatives considered**：不采用持久化公共文件授权、宽泛存储权限、直接只留URI、将测试fixture打入HAP或自动写样例库。

### R2：原件验证与摘要

**Decision**：使用异步fileIo及SHA256原字节摘要；严格UTF-8验证后规范化BOM/换行，同时保存原始解码文本的位置映射，原件字节永不被改写。文件头/容器签名和UTF-8内容用于拒绝明显伪装二进制。

**Rationale**：官方fileIo支持fd/ArrayBuffer读取、stat元信息；CryptoArchitectureKit的SHA256支持分段更新。单个文件上限1 MiB可预检且逐段监控源变化，不能只看初始stat或文本哈希。

**Alternatives considered**：拒绝readText解码后才哈希、替换非法字节、把扩展名当类型证据、读取未选择的相对资源。

### R3：结构与分块不是全量Markdown渲染

**Decision**：纯逻辑处理Markdown常见块结构（ATX/Setext标题、段落、列表、反引号/波浪线围栏代码、管道表格、图片引用），不实现完整网页渲染。保留未识别原文/节点范围并报告限制；表格保留表头、行列与单元格范围，转义管道及代码内管道纳入测试。

**Rationale**：无新增依赖且平台不是Node运行环境；M1需要结构/定位而非HTML显示。模型包括可供后续格式消费的节点与locator，不把内容写成只有Markdown一份。

**Alternatives considered**：不引未经验证npm解析库，不把特殊HTML/Math等无提示吞掉，不先给Office构造假原生锚点。

### R4：关键词用户库与能力降级

**Decision**：普通非向量用户库，统一查询接口。CUSTOM_TOKENIZER/FTS仅在能力、真实建表/写入及中文/英文查询验证后启用，FTS变体记元信息且独立管理。任何选项不可用时维持同一用户原件/普通关系数据，显式LIKE字面关键词降级；不转新空库假成功。

**Rationale**：历史模拟器探测值与实际能力不一致，旧search没有异常级降级和归档过滤。M1只要本机关键词，不调用DataAugmentation/RRF/伪embedding。

**Alternatives considered**：不盲设vector=true，不用随机/哈希向量填语义成功，不把空结果与FTS错误混同。不承诺LIKE理解同义词或自然语言全部条件。

### R5：有界查询与实际相关度

**Decision**：完整问题/实际输入分开。符合总契约的512字符及1000 UTF-8字节限制，明确裁剪规则与保留条件；时间/范围/否定显式限定优先保留，仍超预算时列出实际未保留范围，不猜语义已完整。FTS输入转义且参数绑定；LIKE仅字面词/短语，不让用户%/_变SQL模式。排序基于实际关键词/FTS分数并确定性打平，不显示官方未返回similarityLevel。

**Rationale**：本轮无LLM查询改写，不能伪称理解任意自然语言；固定正负查询金标准能测真实范围。

**Alternatives considered**：不静默截断、不把查询异常当无答案、不用LIKE全查询作为中文语义证明、不在查询SQL拼接未校验用户内容。

### R6：提交、重建与删除

**Decision**：原件、规范化快照、索引世代独立；单写应用队列和短事务，FTS与普通表是否同事务以实际平台验证为准。新世代准备期间读旧活动世代，完整验证后单次发布活动指针。逻辑删除与清理记录提交后清文件；FTS分提交或文件删除失败继续屏蔽/清理，不复活文档。

**Rationale**：文件不可回滚、旧探针代码提交前删文件；仅一个INDEXING字段不足恢复。活动版本JOIN/存在性过滤确保孤儿FTS/旧块不成为证据。

**Alternatives considered**：不重建即清旧索引、不先删原件再提交、不把跨存储步骤称全原子、不以启动清库当对账。

### R7：前台处理与恢复

**Decision**：一个应用会话服务持有串行可取消处理队列，UI仅订阅快照；纯CPU处理放TaskPool或明确有界异步分批包装，不传Context/RdbStore。跨线程使用具名可校验DTO；取消/超时以任务世代失效及不发布晚到结果保证。恢复从最后完整阶段，不强行承诺字节级断点续传。

**Rationale**：TaskPool函数直接execute模式不支持取消，Task模式与序列化约束需实施时查确切重载；即便物理任务继续，失效任务不能发布。切页不丢服务/输入，进程终止后不自动长跑。

**Alternatives considered**：不在UI同步整文解析、不无界开并发、不假设Promise超时已停止数据库/CPU任务、不页面销毁即删原件。

### R8：fixture与证据

**Decision**：host继续读取六份原fixture，来源字节不改；fixed golden事前登记。设备只添加唯一专用目录的副本，不打包HAP；测试假端口仅用于业务故障测试、不替代RDB/选择器实际证据。

**Rationale**：旧runner只测纯逻辑；第三方样本的本地测试许可不等公开分发/云处理许可。旧capture脚本可用RUN_CMD产出host.log，但设备日志状态/host状态需分别判定。

**Alternatives considered**：不删除标题失败用例、不重写golden适应错误实现、不执行样本命令/链接、不调用dev-run脚本隐式修改git config或读取签名秘密。

### 官方资料核对记录

只读取文档，未运行其示例、未访问设备或上传数据；不生成web地址。

| documentId | 设计依据 |
|---|---|
| `开发指南/Core_File_Kit_文件基础服务/用户文件/选择与保存用户文件/选择用户文件/select-user-file` | Picker不需权限、临时URI、普通文件模式、数量/后缀过滤仅选择提示 |
| `API参考/Core_File_Kit_文件基础服务/ArkTS_API/ohos_file_fs_文件管理_/js-apis-file-fs` | fd/异步字节操作、元信息/URI支持与关闭资源 |
| `开发指南/安全/Crypto_Architecture_Kit_加解密算法框架服务/消息摘要计算/消息摘要计算SHA256_ArkTS/crypto-generate-message-digest` | 原字节SHA256分段更新/digest |
| `API参考/ArkData_方舟数据管理/ArkTS_API/ohos_data_relationalStore_关系型数据库_/Interface_Transaction/arkts-apis-data-relationalstore-transaction` | 单写事务隔离、await提交、事务/结果集释放，API14+ |
| `FAQ/本地数据和文件/本地数据库管理/如何通过关系型数据库实现全文检索/faqs-local-database-management-64` | CUSTOM_TOKENIZER+FTS5，默认分词不保证中文；实际验证必需 |
| `API参考/ArkTS_方舟编程语言/ArkTS_API/ohos_taskpool_启动任务池_/js-apis-taskpool` | @Concurrent/可序列化类型、不同execute取消能力与避免无界任务 |

## Data Model

### 具名模型与关系

| 实体 | 主要字段/关系 | 约束 |
|---|---|---|
| TextDocument | id、title、TXT/MD、originalHash、originalBytes、documentVersion、originalAssetId、createdAt/updatedAt | hash唯一判重；归档独立布尔，位置不由标题派生 |
| TextSnapshot | id、documentId/version/hash、schema/parser/mapping/strategy版本、覆盖/警告、assetManifest、结构节点清单 | 不可变、对应原件；未知schema拒绝，不能未知字段硬断言 |
| TextSourceRange | 原始UTF-16起止、1起始/结束行号、规范化区间、标题路径/节点身份 | 起止范围闭开与单位显式，BOM/CRLF映射/来源核对 |
| TextBlock/Table | 类型、parentId、order、标题层级、正文/代码/列表、table行列/单元格span/表头、图片引用文本 | 不执行内联资源；超长结构保留完整快照而非只留碎块 |
| TextChunk | id、documentId/snapshotId/generation、ordinal、retrievalText、sourceRanges、blockIds、证据类型 | 索引文本<=512基线，附加前缀计入；synthetic前缀与证据正文分开 |
| TextJob | jobId、documentId/targetGeneration、stage、checkpoint、cancelGeneration、startedAt/timeout、failureReason | 同时最多一个活动写任务；完成阶段才更新检查点，恢复需现存文档 |
| TextCleanup | jobId、所属文档/世代、用户子树内路径/FTS清理范围、state/reason | 不保留删除正文，逻辑删除事务创建，安全路径不能指探针/外部文件 |
| TextQuery/HitSnapshot | queryId、完整问题、actualInput/preparationNotice、channel、createdAt、命中排名/文本/标题/版本/位置 | 历史不可重读不存在原件补快照；来源已删/旧版实时派生可达性 |
| TextCapability | FTS已验证/LIKE降级/不可用、reason/schemaMeta | 探测API不等结果；无vector或generation标注 |
| TextViewState | list/search/history/detail二级视图、文档/查询/任务/错误/确认、selection/filter | V1整体快照更新，UI不持数据库/原件字节 |

### 本地存储边界

设计表名属于新库，仅本轮使用，不改总spec最终八格式DDL：文档、快照元信息、结构/块引用、世代、任务、清理、查询、引用快照及能力元信息。规范化大产物与原件在安全资产文件；单行严格<2MB，文本不得为绕过上限无限塞JSON。

原件总量按20MiB限额；一个活动新文档/重建世代，活动总块<=10,000、待发布世代也<=10,000且仅单文档，所有临时/快照按当前原件体积和有界结构数量验算；短事务批次例如100块以内为实现保护，不是吞吐承诺。历史每次只存真实top5及有界检索文本/定位，完整问题与大快照可走本机资产，读写分页；磁盘/行上限或I/O错误必须作为保存失败报告，不无声丢历史。原始20MiB上限不伪称包含全部派生产物/历史。

存储版本1必须可验证布局；以后新增版本按升级契约，不用用户库IF NOT EXISTS误判兼容、不删库重建修复schema。重建后失活快照/块经过引用与当前manifest对账清理，旧历史无需完整旧原件也可显示文本快照。

### 状态与发布责任

导入读取/保存、规范化、分块、索引准备、索引发布分别有完成检查点；未完成进入失败/暂停，不显示就绪。读取中取消尚未形成完整原件只清本轮临时副本；已保存原件/已完成文档保留。重建不覆盖旧活动指针；任务校验、发布事务检查现存文档/目标世代，取消/超时/删除失效结果不能提交。

归档/恢复不改处理结果；删除将文档/可查询身份移除，同时落清理任务，再删除字节/旧块/FTS。清空也是显式确认后逐文档处理新用户库，不删整库结构。应用启动只执行安全对账与列出可恢复任务，不自动恢复所有高耗时任务。

## Contracts & Interfaces

### 应用与端口（概念契约，不含实现代码）

| 边界 | 输入/输出 | 责任 |
|---|---|---|
| TextSelectionPort | 选择请求→已选URI/元信息或取消 | Picker临时授权，不写数据库，不自动选择或伪造路径 |
| TextAssetPort | 已选文件/预算→保真资产/SHA；安全资产身份→字节/清理结果 | 核验实际字节、关闭fd、独立用户目录；原件不更改 |
| TextProcessingPort | 字节/格式/策略→验证后快照/块或明确失败 | 纯文本逻辑与CPU调度分离、返回具名DTO/范围/警告 |
| TextRepositoryPort | 文档/世代/任务/历史/清理DTO→持久化结果/分页查询 | 单写、短事务、活动版本/归档/存在性过滤，失败可定位 |
| TextKnowledgeService | 用户意图→整体状态/导入结果/查询结果/详情/管理反馈 | 预算、判重、取消/超时、阶段发布、原件/库协调；无 Kit |
| TextView | 用户动作/服务快照 | 展示实际状态/通道、二次确认、二级返回；仅调用应用层 |

端口保证明确的错误分类（取消/不支持/类型/编码/超限/I/O/结构/schema/查询/保存/恢复），不通过空数组统一掩盖。sdk错误归一化不能用as或虚构code，只有真实code/message才保留到去敏错误模型。

### 页面装配与 UI

沿用 `Index` 的一个Entry和一级导航，替换tab2的KnowledgeLab为TextKnowledgeView。应用装配对象由Index拥有，在上下文可用后初始化，切页/二级切换保持query和服务任务；`onBackPress`先让知识库返回详情→查询/历史→列表，再返回助手。不增加Navigation/router/page注册。

列表显示标题/格式/字节/状态/归档，文件导入按钮与多选管理；查询与历史为同入口二级视图，命中展示正文/标题路径/行号/实际通道。原文详情读取保存原件的解码内容、对应范围与说明，保留文字可缩放；删除/清空确认解释历史文本保留。沿用Theme、演示模式标签与实际数据状态分开，不新增营销说明或无意义装饰。

手机单栏，平板可在知识库功能范围内根据实际可用宽度左右分栏，不重排其他页；现Index maxWidth640约束仅在知识库tab采用可适配布局，日程/其他tab保持原样。状态与按钮文案不遮挡，长标题/错误多行，有稳定动作区。

### 测试与证据契约

旧host runner扩展加载纯逻辑文件/测试，保留原Mock/Chunker/Corpus用例；新的服务测试用具名假端口验证取消/发布/超时/事务故障，不把假端口放到用户装配。

固定golden在实现前先登记fixture SHA、查询/期望正文/源行范围/标题/结构、无答案与已删/归档等题型，核对后再测；定位金标准不能在运行时从实际输出推导“期望”。原六份fixture字节不改，来源许可说明保留；后续其他格式另外获许可加入。

每轮host/build/deploy落盘日志、命令/退出状态、提交/工作区指纹，补新增源码和fixture内容SHA、工具/SDK版本；capture脚本的log-failed与RUN_CMD状态分开判，不因脚本退出0称测试通过。源码不输出资料正文；测试日志只含获授权测试文件名/用例/结果/范围摘要，不含个人文件内容。设备只选唯一目标、不卸载、不清数据、不接受协议或自动登录、不新增git配置；签名材料不进AI上下文，需要手动/现有安全流程时如实报告阻塞。

### Requirements Coverage

| FR | 设计覆盖 |
|---|---|
| 001/003 | TextView、Index二级入口、未实现格式说明 |
| 002/004/007 | AssetPort、SHA/UTF-8、快照/映射/locator、原文详情 |
| 005/006/018 | MarkdownStructure、StructuredChunker及旧Chunker回归，真实fixture |
| 008/009 | Repository关键词通道/降级、QueryPreparation、安全字面查询/完整历史 |
| 010/013/014 | 任务世代/活动发布、单写/清理日志/启动对账、取消超时与故障测试 |
| 011/012 | 管理与二次确认、新库/目录、探针脱离入口、存量保护 |
| 015 | 查询/引用快照、旧版与失效、历史分页/详情 |
| 016/017 | 无外发/权限/依赖，entry现有分层/Kit仅适配器 |
| 019/020/021 | 事前golden、host/机制/真机分层、设备专用fixture、不打包/上传、不提前造其他格式 |
| 022 | 新旧工作区/fixture指纹、真实日志/失败记录、执行/总spec证据回写 |

### Verification Strategy

阶段4执行纯逻辑/应用服务host测试并留证据；阶段5负责静态检查后的构建、部署及由tasks.md固定的UI验证范围，不在此假定用户选择。每轮.ets编辑完成在构建前执行arkts_check，构建失败按输出修复后直接重试构建，不能在失败与重试之间再跑checker代替构建；release/应用运行仅在构建成功后。

host证明解析/状态纯逻辑；设备证明真实URI、RDB和页面/恢复；真机/模拟器结果分开。无可用签名/设备等阻塞不能卸载、清数据、自动接受协议、读取密钥或假报通过。总spec保留历史S1/56-1，M1本轮结果带版本/文件/日志路径，只有确实通过的层标完成。

## Changelog

### 阶段 4 Setup 基线（2026-10-12）

- 工程有效：根 build-profile.json5 为 signingConfigs 空模板，oh-package.json5 为 modelVersion 26.0.0；不重建工程、不安装依赖。
- HEAD：7830319；实施开始 git status 仅 `?? spec/`。正式委派确认前三阶段批准，审核中标题保留历史。
- 本机 DEVECO_HOME：/Applications/DevEco-Studio.app/Contents；SDK 使用其 sdk。实际 PATH Node v22.23.2、devecocli 1.3.4，与文档基线不同，不升级。
- 不打开/迁移/清理 shuvi_kb_probe.db、shuvi_kb_probe_kw.db、filesDir/kb；仅新增 shuvi_kb_user_v1.db 与 filesDir/knowledge_user_v1。全部设备文件保留，本阶段不访问设备。
- host 使用 capture-test-log.sh 的 RUN_CMD，DEVECOCLI_BIN=/usr/bin/false 禁止抓设备资料，log-failed 与 host 状态分别记录。runner 输出新增纯源、适配器/UI、固定语料 SHA256，补足未跟踪文件指纹。
- 已读取官方 Picker、fileIo、SHA256、Transaction、TaskPool、FTS 文档；仅用已核对重载。构建、部署、UI及真实 RDB 协议证据归阶段 5。

### 阶段 4 实现细化与保护

- 新库使用普通关系行/独立 FTS5；FTS 仅在运行时中文/英文、提交、回滚、删除与既有活动行覆盖实际检查通过才启用；否则保持同库 LIKE。未采用未取证的 FTS 分提交特殊协议，旧模拟器现象未泛化。
- 原件及快照使用白名单资产 ID，不从展示标题派生路径；异步 32 KiB I/O、实长/EOF/stat/SHA256 核验、fd 关闭、NOFOLLOW、禁止链接/递归清理。SDK 无 EXCL，使用单写流程、唯一 ID、已存在拒绝及 NOFOLLOW；真实平台覆盖行为仍由阶段 5 验证。
- 快照使用显式 versioned percent-encoded wire（不是未校验 JSON）。节点、单元格、结构与定位保持完整；原始映射重建后逐项核对。RDB 单行是有界元数据、块、定位；完整问题按 16,384 UTF-16 单元分行保持原样。
- 原件 1 MiB/批次10个5 MiB/100篇20 MiB/10000活动块/60秒索引/10秒查询保持批准值。额外保护：20,000节点、40,000单元格、80,000原始行、完整快照12 MiB、线程载荷保守估算12 MiB、单篇待发布<=10000块、100块写批次、top5引用、20条历史一页。官方线程序列化硬上限16 MB，超保护线明确失败、不截断；保护值不声称已实测内存峰值。
- 重建期间旧活动指针不变；新发布检查文档存在、hash/version、job/cancel世代、完整标记与60秒窗口。失活世代清理持久化、启动对账只回收不自动高耗时续跑；待清理存在时拒绝新增处理避免无界残留。
- CPU 解码/解析/分块/快照编解码/查询准备使用 API13+ 具名泛型 TaskPool 重载；跨线程无Context/store/ValuesBucket，返回具名DTO后有界校验。函数 execute 无物理取消，单活动写任务保持到返回，失效结果不能发布。
- TaskPool/URI/RDB/ArkTS/页面与设备能力未在本阶段执行，host 仅纯逻辑与具名测试端口。证据与剩余责任见 implementation-report.md。

- 2026-10-12：首次M1设计，基于已批准需求、实际entry探针源码和官方选择器/摘要/文件/事务/TaskPool/FTS资料；不产生代码与运行结果。
