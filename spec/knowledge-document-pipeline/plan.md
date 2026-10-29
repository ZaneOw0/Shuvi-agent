# Implementation Plan: M2-A MinerU 安全配置与复杂文件转发

**Input**：`/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/spec.md`（2026-10-14 已通过阶段1审核）。
**总契约**：`/Users/zane/DevecostudioProjects/Shuvi-agent/specs/02-个人知识库问答.md`。
**状态**：阶段2架构待审核；本阶段只读官方文档和现有源码，不修改应用、不读凭据、不外发、不构建/测试。

## Summary

在现有 entry 和 V1 架构内增加一个独立的“解析引擎/复杂文件准备”功能，提供固定 MinerU 精准服务、Token 安全配置、PDF/DOCX/PPTX/XLSX 保真本地准备、逐文件测试用途同意、上传与异步任务查询、隔离结果 ZIP 接收及暂停/恢复/清理。

M2-A 不改变 M1 文本库、文本 wire/locator、索引/历史接口，不给复杂文件建索引。接收的包状态永远是“结果已接收，待结构校验”，不解压、不适配未知产物 schema、不显示就绪。后续 M2-B 基于实际样包冻结规范化/原生定位后，再接 PDF 原页高亮和 L0；Office 逐格式取证/实现，不因本轮接收能力宣布已支持。

## Technical Context

**Language/Version**：ArkTS、Stage 模型，沿用 HarmonyOS 26.0.0/API26、现工程/工具基线，不升级。
**Primary Dependencies**：现有SDK AssetStoreKit、RemoteCommunicationKit（rcp）、CoreFileKit、CryptoArchitectureKit、ArkData、ArkTS、AbilityKit；PDFKit仅本地页数/加密预检，不用于本轮解析正文。不新增第三方依赖/HAR或自有后端。
**State Management**：保持现项目 V1 @Component/@State/@Link；UI从应用服务接收新的整体快照，秘密输入不进入公共视图模型。
**Storage**：独立本地普通RDB `shuvi_parse_stage_v1.db`（S3、无向量/同步），原件与结果在 filesDir 下 `knowledge_parse_v1`；任务临时文件在 cacheDir 同名子树。M1 `shuvi_kb_user_v1.db/knowledge_user_v1` 与 probe 库/目录不操作、不迁移。
**Credentials**：Asset Store Kit两个专用别名：MinerU Token与本地临时地址加密密钥，SECRET字段、DEVICE_UNLOCKED、SYNC_TYPE=NEVER、不设群组或卸载后持久。地址租约经AES-GCM存为密文；普通任务库没有Token或签名地址明文。
**Networking**：rcp Request/Session，固定精准 API、原文件PUT、受控流式GET；认证控制面与无认证存储面请求分离，禁止自动重定向/缓存/跟踪正文，标准TLS验证保留。
**Testing**：纯逻辑/服务host及故障注入，真实AssetStoreKit/URI/PDFKit/网络/持久化由验证阶段和之后用户提供样本分层取证。无Token/样本时真实服务测试明确未执行。
**Target Platform**：Phone/Tablet，API26；PDFKit官方仅中国境内、支持ARM模拟器不支持x86。能力不可用保留文件/明确阻塞，不靠设备型号猜支持。
**Project Type**：已有应用增量功能，沿用目录责任，不MVVM迁移、不新增Entry/路由页。
**Scale/Scope**：本轮只转发闭环与本地设置，非敏感逐件免费测试例外；PDF/Office结构、索引、视觉、生成/语义、同步与联网样本抓取均为后续任务。

### 已批准预算与本设计的有界保护

数值是保护边界，未经压测不称性能结论；同意/免费资格/样本许可仍独立。

| 项目 | 设计边界 |
|---|---|
| 原件 | 单件20MiB；批次最多3件/40MiB；复杂原件总计100MiB。逐段复制/SHA256、实际长度、源变化检查；原件字节不改，M1预算保持 |
| PDF页数 | 本地加载成功、未加密且1–50原页才可外发；PDFKit不可用/加载失败时待预检，不靠正则、用户估计或上传前50页隐式截断 |
| 云并发 | 每次只提交1文件（批次API单项files），单个远端未终态/提交不确定任务占用。暂停/删除不释放未知远端占用，须查询确认终态后才能提交另件 |
| 单请求 | 连接30秒、传输最多120秒、无活动30秒，应用层总墙钟120秒；rcp取消与世代失效并用，SDK分项不冒称总时限 |
| 查询窗口 | 每文件一次前台等待最多15分钟；最短间隔5秒，逐步至30秒，最多90次状态查询，遇429按已验证Retry-After及上限暂停。默认无自动重提/上传重试；用户手动恢复开新查询窗口，不新建服务任务 |
| 控制JSON | 响应最多1MiB实际字节，嵌套深度16、最多4096键/值token、单字符串最大16KiB；数组在单项批次契约下按预期数量验证。跨限阻止解析/发布，不记录原始响应 |
| 结果ZIP | 单包最多30MiB，最多1个下载写队列，64KiB应用磁盘I/O；原件/结果不整包ArrayBuffer，写入前累计检查，HTTP长度未知也受限制 |
| 结果/临时空间 | 完整隔离包另计总量200MiB，活动下载临时预留30MiB，原件复制临时预留20MiB；未完成清理占用仍计入，空间不足暂停/拒绝而非自动删除已接收包 |
| ZIP后续限制 | 展开100MiB/1000成员仅记录为M2-B门槛，本轮不展开；收包只做传输完成/签名/实长/SHA256与完整结束标记检查，不称内部ZIP安全/CRC/全部成员通过 |
| 本地预检 | 文件复制/摘要/PDF加载与容器身份有界，不阻塞UI；120秒本地窗口，PDFKit同步加载放专用并发适配器，资源必须释放 |
| 页/解析内容 | Office本轮只核容器身份，不猜sheet/slide/原生锚点；服务返回页数用于真实进度/异常信息，不直接当本地PDF原页数 |
| 费用 | 仅用户逐文件确认当前免费资格，无供应商可信计费信号时不声称已自动核验免费；出现收费/额度不明信号立即暂停、不切付费。不新增收费授权 |
| 重启/备份 | 不自动续跑高耗时动作；Token/加密键不同步，解析整个新子树/库排除系统应用备份，保留M1原备份行为；恢复缺键/地址时明确不可恢复，不能明文降级 |

## Project Structure

### Documentation

| 绝对路径 | 用途 |
|---|---|
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/spec.md` | 已批准需求与长期约束 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/plan.md` | 本设计、接口、数据与证据边界 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/tasks.md` | 阶段3产生的分故事任务与验证marker |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/implementation-report.md` | 阶段4真实实施/host与未覆盖 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/verification-report.md` | 阶段5唯一权威结果 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/feature.json` | 已批准指向本目录，其他feature原记录保留 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/specs/02-个人知识库问答.md` | 后续增量回写本轮范围/预算/测试例外及真实证据 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/.cache/m2-input/user-pdf/` | 阶段4创建的本机空输入目录，不扫描、不Git/HAP、用户放件不等外发同意 |

### Source Code Targets

以下是阶段4允许的职责与目标描述，没有代码或实现伪逻辑；新目录只在获实现批准后建立。

| 绝对目标路径 | 职责 |
|---|---|
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/DocumentParseModels.ets` | 新增：具名格式/原件/同意/门禁/任务/错误/结果/视图模型及预算，秘密只留适配器私有 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/domain/DocumentParsePorts.ets` | 新增：原件/预检/存储/凭据操作/服务任务/结果接收端口，领域无Kit |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/MineruProtocolCodec.ets` | 新增：有界标准JSON边界、官方已知控制层响应转具名DTO；安全标识/主机策略。不是结果包内部schema适配 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/pipeline/DocumentParsePolicy.ets` | 新增：纯预算/授权绑定/远端占用/状态恢复与网络错误分类规则，不含凭据 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/application/DocumentParseService.ets` | 新增：配置操作、原件准备/判重、逐件确认、任务编排、检查点/暂停/恢复/清理与视图快照 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/MineruCredentialStore.ets` | 新增：AssetStoreKit Token/本地加密密钥、配置状态、认证请求边界、地址租约AES-GCM；秘密不返回页面/领域 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/DocumentFileAdapter.ets` | 新增：复杂文件Picker/原字节安全保存/SHA256/受控输入格式身份/PDF预检调度、隔离包写入/哈希及安全清理 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/DocumentPdfPreflight.ets` | 新增：PDFKit加密/页数/加载失败和并发资源释放，不改PDF、不提供完整预览/解析 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/DocumentParseRepository.ets` | 新增：独立S3任务库、配置非秘密偏好、同意、批次/任务身份、远端占用、资产/清理日志、版本布局校验 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/MineruTransportAdapter.ets` | 新增：rcp认证控制面/无认证PUT与GET、可信目的地、实际字节/超时限流/取消、协议校验与流式限额 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/infra/DocumentParseAssembly.ets` | 新增：单应用会话装配、前后台协调、M2资源失败不拖垮M1 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/DocumentParseView.ets` | 新增：V1安全密码输入、引擎状态/默认关Toggle、文件确认Checkbox、任务列表/动作与结果待校验说明 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/pages/Index.ets` | 限定更新：同一四入口中装配M2设置/任务二级视图、返回/输入清理，M1服务保持独立 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/components/FeaturePages.ets` | 限定更新：“我的”新增解析引擎入口回调，不改变其他功能/账号占位 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/knowledge/ui/TextKnowledgeView.ets` | 最小更新：知识库提供“解析准备”入口，txt/md原按钮仍走M1原服务，不合并格式输入 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/ets/entryability/EntryAbility.ets` | 必要限定生命周期桥接：背景事件使本轮M2输入/请求暂停、无需改变M1状态；不新增后台能力 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/module.json5` | 只增加INTERNET用于解析，无user_grant新权限 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/main/resources/base/profile/backup_config.json` | 选择性排除M2本轮任务库/文件/缓存，保留allowToBackupRestore及M1现行为，不全局禁备份 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/DocumentParseCases.ets` | 新增：协议/类型/主机/预算/同意/状态/错误边界host |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/DocumentParseServiceCases.ets` | 新增：具名假端口测试真实应用服务的拒绝零网络/提交未知/单占用/恢复/迟到/清理；假端口不生产装配 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/entry/src/test/run-host-tests.cjs` | 扩展纯模块/测试注册，保留旧96与fixture字节/golden，打印源码/题集指纹不等实际平台执行 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-document-pipeline/input-guide.md` | 新增本机目录/后续授权/用户拖模拟器与配置注意说明，不含Token/自动收样脚本 |

**Structure Decision**：遵循当前 `knowledge/domain/pipeline/application/infra/ui`，不新MVVM目录或跨模块迁移；十二个新生产文件区分纯协议/策略、协调、平台安全/文件/PDF/库/网络和UI，不一概念一文件。现有一个Entry、四主入口、Theme和V1保留；平台代码只在infra/组装，不放领域/页面。M1 `TextKnowledgeModels/Ports/Service/Rdb/wire/Chunker/fixture原件`不改功能语义，M2不索引所以本轮没有迁移必要。

## Complexity Tracking

分离解析准备库是本阶段保护M1存量的最小选择：M1当前格式/严格TEXT-SNAPSHOT-1不适用于二进制，而M2结果未校验不能塞进原库。这仍是同一ArkData技术，不引第二套数据库底座；M2-B正式规范化时另审兼容迁移/统一索引。

额外本地地址密钥和加密租约用于恢复，不把长签名地址塞Asset Store（短敏感SECRET≤1KiB）或普通任务明文。任务状态与远端占用分开是满足“暂停不等于云取消/单云任务”要求，不用本地删除假定取消。

## Research & Decisions

### R1：固定引擎与安全Token入口

**Decision**：引擎固定MINERU_PRECISION、模式vlm，Token按1–1024 UTF-8字节/无换行等认证头安全规则校验，不擅自裁剪或泄漏。Asset TOKEN保存/更新/删除分别明确错误；配置状态查询使用ATTRIBUTES，不读取SECRET给公共模型。网络请求前在私有适配器短时获取SECRET，控制请求结束/背景/关闭后丢引用，对字节缓冲尽量清零；ArkTS/SDK不可保证字符串物理擦除，报告不声称完美零化。
**Rationale**：官方AssetStoreKit SECRET保护、appId隔离、短数据限制、DEVICE_UNLOCKED/SyncType.NEVER/ReturnType.ATTRIBUTES/ALL均有SDK依据。凭据持有不证明服务有效或免费、也不授权文件外发。
**Alternatives considered**：不在Preferences/RDB存Token、不SDK缓存全局SECRET、不用ALIAS/DATA_LABEL装秘密、不设置群组/IS_PERSISTENT true而引STORE_PERSISTENT_DATA权限、不自动检测Token向服务发请求。

### R2：敏感租约与备份边界

**Decision**：应用另生成32字节本地AES-GCM密钥放Asset SECRET，不由Token派生；临时上传/结果地址序列化后AES-GCM密文存用户解析子树，每次独立随机nonce/AAD绑定task/asset/version/用途与expiry，认证失败拒绝恢复。租约到期/完包/任务删除清理；Token更新/删除暂停相关任务并使旧确认/租约不可继续上传，保留批次ID用于用户确认同账号后的查询，不假账号一致。
**Rationale**：地址可能大于Asset1KiB且带短期访问权，不能明文备份或写日志；加密键与地址不同步，系统backup selective exclude有官方示例。M1allowbackup保留。
**Alternatives considered**：不把地址明文普通RDB、不对地址作Base64假加密、不把API24h上传窗口当文件删除时间、不假AES验证成功等内容真实。

**租约时间语义**：官方上传窗口24小时只作为服务描述，实际签名显式有效期可验证时与本机保护窗口取较早者；下载地址未报告有效期时记录UNKNOWN，本机仅允许取得后10分钟内使用，这不是远端到期承诺。本机窗口耗尽或地址被拒绝，优先查询已有batch取得当前结果租约，不自动重新申请上传或重提解析；无可安全恢复地址时保留任务并明确阻塞。

### R3：原件复制和格式预检

**Decision**：复杂文件使用独立Picker提示PDF/DOCX/PPTX/XLSX及批次3件、真实类型/字节/容器身份核验，分段异步32/64KiB I/O与SHA256（复制后读回核对）；保存本地资产使用唯一不从标题派生的ID、单写/禁止链接/存在拒绝，不改源件。PDF由Kit本地加载、isEncrypted/成功页数核验/释放，页数能力不可用仍可保存但不能外发。
**Rationale**：同一M1 fileadapter硬限定1MiB/TXTMD，不能直接放大常量破坏既有预算/解码。PDFKit支持Phone/Tablet、ARM模拟器、不支持x86且有地域门槛，必须实际探测/加载成功，不正则取/Count或靠用户估计绕50页。
**Alternatives considered**：不使用pdfService.saveDocument/edit/removeSecurity，不读取20MiB全件到UI内存，不本轮做PDF全文OCR/预览，不把PDF/ZIP字节交TextNormalizer，不自动扫描批准的用户本机目录。

**Office容器身份边界**：本轮只读ZIP目录元信息核对OOXML基本成员与主内容包类型，区分word/document.xml、ppt/presentation.xml、xl/workbook.xml；目录加密/异常/重复/链接/路径越界/超元信息预算拒绝，禁止ZIP64/多卷等本轮未支持的变体。最多4096目录项/2MiB目录信息的实现保护，超限保留原件但不外发；不解压或重算公式，不承诺包内部全量正确/原生锚点。结果ZIP则只隔离接收，不能复用“原件容器身份”宣称结果成员安全。

### R4：独立同意和非敏感测试例外

**Decision**：全局解析默认关，已配置凭据、可信引擎/可用预检、免费资格声明与逐文件checkbox完整后，产生Grant绑定hash/version/format/完整字节范围、同意版本、凭据revision、用途、接收策略版本与时间。每次网络动作检查Grant及任务epoch；修改文件/凭据/用途、关闭开关或撤回确认使继续上传无效。恢复已有查询/下载必须用户确认继续消费先前已提交的同一测试任务，不自动续跑。
**Rationale**：用户明确允许非敏感测试例外且条款未知如实提示，不能伪称能自动判断敏感性、许可或免费余额。无可信费用接口，只记录用户声明，收费/额度不明信号触发停止。
**Alternatives considered**：不以INTERNET或已有Token代同意、不把一个toggle授权全部文件、不自动同意隐私条款、不本轮外发任何agent自动选样/未知许可示例。

### R5：控制面与存储面分离

**Decision**：rcp控制面使用固定官方API主机和路径、请求级Authorization，存储PUT/GET使用不同无认证Session，noStore/noCache、无CookieRepository/自动cookies、无网络正文trace、plaintextInException=false、autoRedirect=false，标准证书/主机验证开启。所有3xx拒绝，不能自动带Token或任意新接收方。
**Rationale**：SDK自动重定向默认true、上限默认50，正文默认下载缓冲50MB不等App限制；必须显式安全配置。实际APIJSON字段通过可信控制响应取地址，但地址仍要独立验证。
**Alternatives considered**：不跨主机复用含Authorization session headers，不acceptAll/跳TLS、不依赖系统网络权限处理任意地址，不用户配置BaseURL，不把StoreURI URL原文带入UI错误。

**目的地策略**：控制主机、上传对象存储及结果CDN仅采用官方公开API文档中出现的精确服务域名（MinerU官网、文档所示上海OSS上传桶/结果CDN），按角色列出精确主机与路径前缀，禁止宽泛阿里云后缀/包含字符串匹配；HTTPS、无userinfo、标准443端口、无IP/loopback/fragment/异常编码，仅允许服务返回的租约。实际返回其他主机必须显示“接收方未获核验”并暂停，不能新增猜测域名。完整地址/查询签名不写架构文档或日志；源码所需官方常量在实现阶段仅使用已提供资料精确值，不生成新地址。

### R6：有界JSON与无断言校验

**Decision**：只解析已知控制层JSON，使用有界标准JSON词法/结构读取器输出具名响应DTO：强校验root/code/msg/data/batch_id/file_urls/extract_result/data_id/file_name/state/full_zip_url/progress。长度/深度/duplicate关键字段/数组数量/安全整数/枚举必须验证，未知非关键字段以有界方式跳过；不得借未知字段兜底。无法识别任务或data_id不符暂停，单文件批次不靠文件名作为唯一匹配。
**Rationale**：rcp Response.toJSON返回object|null，平台JSON.parse返回Object|null；SDK示例的as/动态属性与仓库更严规则冲突，不能套RawInterface断言就当校验。只读取控制协议不代表推测结果包内JSON schema；pure codec可host测。
**Alternatives considered**：不使用any/unknown/as、匿名类型、动态Object[key]、JSON.parse断言、第三方class-transformer，不Regex整体抽取JSON。文档标准响应fixture可作协议单元测试，必须标非服务实测。

### R7：原字节流上传与受控结果接收

**Decision**：PUT通过rcp.UploadFromFile/受控ReadFile读取已校验沙箱原件，流式字节、实长/hash与Grant绑定，拒绝自动重试。APIJSON用incomingData实际字节累加≤1MiB；结果GET用具名IncomingDataCallback或WriteFile受控写入，每chunk写前限额/epoch/磁盘/串行fd验证，未知Content-Length也≤30MiB，超限cancel且不写越限chunk。HTTP状态、长度、传输结束、本机文件大小/hash和ZIP起始/结束记录校验后原子提交隔离包。
**Rationale**：进度回调在总长度未知时可能不触发，Content-Length可缺失，不足以硬limit；SDK支持异步回调/WriteFile与cancel(request)。内容缓存50MB不是M2预算。预检传输是本地byte完整性，服务无可信内容摘要不伪称验证了服务真实性或全部CRC。
**Alternatives considered**：不30MiB全包toArrayBuffer、downloadToFile进度后再超限删当硬上限、不解包/执行成员、不按包成员名写路径，不partialdownload标成功，不擅自做range/resume语义。

### R8：任务身份、单远端占用与恢复

**Decision**：一项files申请绑定一个task；服务返回batchID和file_urls数量恰1才可提交，先持久化身份/加密租约，再PUT，服务自动扫描提交，不另call创建解析接口。提交请求前保存“申请中”检查点；超时/不确定响应记SubmissionUncertain，不自动重提、不生成新data_id假新任务。
**Rationale**：业务data_id只是关联标识，官方没有幂等保证。既有M1.resume创建新generation/delete旧job不适合云任务；本轮独立检查点保留服务身份。
**Alternatives considered**：不每次resume都重新申请URL/创建task，不靠200/50批量概览扩大批次，不把申请上传与云解析done合成一步。

**占用/恢复**：全应用最多一个远端待上传/未终态/状态不确定占用；等待15分钟只是暂停本地轮询、不释放未知远端slot。用户删除原件/task显示行时，保留不含正文/标题的远端未决tombstone（业务ID/批次ID/凭据revision/最后状态），仅获确认查询后观察done/failed等终态才释放，禁止创造“本地删=云取消”。Token删除/不同账号更新、失去任务访问或找不到且不能证明终态时保留占用并提示用户核对；不为了继续任务提供无证据解除按钮。

恢复有batchID优先Query，无batchID未知申请停止待核对。wait-file可在租约仍有效、原件/hash/grant未变且用户确认继续时PUT同一地址；旧上传部分或地址expired只Query核对，不能假定续传/补申请不会重复。done且待包时可Query取得当前地址再下载，失败的临时文件只清本轮-ownedpart、原件保留。完成隔离包后网络结束，未来reindex/reparse是不同动作。

### R9：前后台与用户输入清理

**Decision**：Index拥有独立DocumentParseAssembly，与M1Assembly同时但失败相互隔离。同功能二级切换/一级离开设置页会清秘密输入；应用背景事件经最小生命周期桥发M2暂停/释放session、失效回调、清临时SECRET和URL明文，保留完整本地checkpoint。前台只列可恢复任务不自动网络。
**Rationale**：现EntryAbility.onBackground只日志、Index切tab不销毁；仅aboutToDisappear不足，不能假后台仍有明文Token或自动上传。停SDK请求与世代不发布相配合，不把取消API返回void称云端取消。
**Alternatives considered**：不引后台服务/ServiceExtension、不跨TaskPool传Token/Session/RdbStore，不AppStorage保存密码，不在UI拿完整认证状态secret。

### R10：样本与真实证据

**Decision**：阶段4建立本机空user-pdf目录、input-guide记录后续逐件授权/免费测试/手动拖入。真实样本和Token均当前缺失，禁止自动调用真实API取证；M2-A可通过host/构建及非秘密UI验证机制，但真实MinerU任务/结果永记未执行直到明确样本用户操作。原M1六fixturebytes/golden和96用例保留，不下载未知许可demo、不生成Office说真实。
**Rationale**：用户批准的是留入口、先实现，然后自己找样本；免费API存在是声明不是实际服务/费用/凭据测试证据。
**Alternatives considered**：不读.cache目录里未指定个人PDF、不HDC重试权限失败、不 agent代填Token或抓token设置屏、不把stub响应当样包，不改旧M1INCOMPLETE/人工2份反馈为完整PASS。

## Data Model

### 模型与持久化归属

| 模型 | 关键字段 | 约束/归属 |
|---|---|---|
| DocumentParseConfig | engine=MinerUPrecision、enabled默认false、mode=vlm、policy/codecVersion、credentialRevision、status | 非秘密偏好可在新parse_meta；已配置/不可用由Asset属性查询，不缓存Token到公共模型 |
| DocumentOriginal | id/title/format、assetID、SHA256/bytes/version、PDFpageCount/preflightStatus、OOXMLidentityStatus、savedAt | 完整原件在新files子树，SHA/版本是Grant和task依据；TXT/MD仍M1，不共享该格式enum或wire |
| DocumentParseGrant | grantID/originalID/hash/version、engine/receiverPolicy/credentialRevision、fullFile/embeddedImages范围、nonSensitiveTest/freeEligible声明、acknowledgementRevision/time/revoked | 不包含Token，不能由启用开关自动产生；每任务/action引用，条件失效即暂停 |
| DocumentParseTask | taskID/originalID/dataID、batchID/可选服务taskID、stage/checkpoint、remoteState/progress、epoch/revision、窗口/次数/错误码分类、leaseReference、resultAsset | API申请/上传/wait/服务done/下载/本地未校验分开，关键信息必须写入后继续网络 |
| ParseRemoteOccupancy | taskID/dataID/batchID、credentialRevision、lastObservedState/terminalObserved | 本机删除也保留最小未知远端占用；不含标题/内容/hash，非任务显示行但状态可见 |
| ParseLease（私有加密） | 上传或结果地址、用途/taskID/originalHash/version、issuedAt/validity、serviceRole | 内存仅transport/credential层，普通库只引用；AESnonce/tag/AAD/auth校验，过期不自动刷新申请 |
| ParseResultEnvelope | assetID/taskID/dataID/originalHash/version、bytes/SHA256、receivedAt、signature/completeTransport/status=UNVALIDATED | 容器与字节只本地验证，metadata/manifest无成员schema；不生成DocumentChunk/citation |
| ParseCleanup | ownAssetIDs/parts/leaseIDs、taskEpoch/referenceSnapshot、pending/failure | 提交逻辑删除后清文件、幂等/路径白名单、待清理容量仍计入；不清M1或设备公共文件 |
| ParseCapability | format PDF/DOCX/PPTX/XLSX、preflightAvailable、forwardingStage、artifactSchema/nativeLocator=UNVERIFIED、privacy=UNVERIFIED | Token已配置不是产物verified，不能用bool全“supported” |
| ParseViewState | configStatus、settings/tasks/detail二级页、originals/tasks/grants/occupancy、budgetuse/error/progress、canSubmit理由 | 没有Token、完整签名地址、原始网络错误/响应。密码输入仅视图私有暂存，退出清理 |

新关系表归parse库：meta、original、grant、task、remote_slot、result、cleanup；字段使用显式列插入，不全列位置假兼容。数据库布局和rowcodec版本有严格标识，已存在未知版本时拒绝打开M2、不删库修复；M1正常查询不受影响。服务ID/版本/日期等读回校验范围，Asset加密租约不引用普通RDBSecret字段。对账依原件/任务/占用/完整包引用，清孤儿仅本轮安全树，先列pending清理再动作，不能仅task状态推断远端终止。

### 状态维度

| 本机阶段 | 真实含义与恢复 |
|---|---|
| LocalSaved / PreflightBlocked | 原字节已保存，未授权或PDF/容器预检未通过；零网络 |
| AwaitingGrant / ReadyToSubmit | 等逐件测试/免费声明与安全凭据条件；Ready不是索引就绪 |
| AllocationInProgress / SubmissionUncertain | 已发申请/结果未知，记录请求epoch，不能盲重提 |
| UploadLeaseReady / Uploading / UploadOutcomeUnknown | 已有batch/租约；上传先只同task地址，未知进度需Query，不假续传 |
| RemoteWaitingFile / Pending / Converting / Running | 真实API状态，回报本机接收进度；暂停仍remote slot占用 |
| RemoteDone / RemoteFailed | 真实终态观察；done未必已下载，failed有去敏原因、原件保留 |
| Downloading / DownloadPaused | 对同任务结果包传输，临时文件/字节计数有界，暂停不能发布完整包 |
| ResultReceivedUnvalidated | 接收包本机传输校验完成、结构未验证，不能检索；未来M2-B消费版本化原件/包 |
| LocalPaused / Failed / DeletedCleanupPending | 独立本机维度，保存服务checkpoint；删除与remote slot终态分开 |

## Contracts & Interfaces

### 应用/平台边界（概念契约，无实现代码）

| Port/模块 | 输入/输出与责任 |
|---|---|
| DocumentSelectionPort | PDF/DOCX/PPTX/XLSX临时URI/文件信息或取消，只触系统Picker |
| DocumentAssetPort | URI/预算→唯一保真本机Original；assetID→有界读/受控上传读句柄、结果临时写/摘要/发布/安全删除；不回公开路径原文 |
| DocumentPreflightPort | 原件身份→真实PDF页数/加密/OOXML身份或明确阻塞；无save/removeSecurity；不传正文入UI |
| MineruCredentialPort | 输入Token→只配置状态/安全错误；status/update/remove；认证与Lease加密操作只由平台Transport/Assembly使用，领域不能拿原值 |
| MineruTaskPort | 已确认原件/job/grant、隐私/预算/取消epoch→申请/上传/inspect/receive的具名结果 |
| DocumentParseRepositoryPort | 非秘密config/original/grant/checkpoint/task/occupancy/result/cleanupDTO→持久化及分页；单写短事务/布局校验，无网络 |
| DocumentParseService | 用户保存凭据（只转交专门安全操作）、选择保存/确认/submit/query/resume/pause/delete→新的PublicState与去敏错误；不Kit，不把Token赋自己的state |
| DocumentParseAssembly | Context/平台能力/生命周期→一次会话装配；M2失败状态隔离、不初始化/迁移M1数据库 |
| DocumentParseView | 用户密码字段/Toggle/Checkbox/动作→serviceintent；退出清理、可访问labels、当前能力/局限/零请求理由/任务阶段可见 |

凭据保存入口仅将用户秘密短时传安全适配器；所有后续应用请求使用credentialRevision/status，不返回SECRET。payload请求模型包含明确原件大小/确认摘要，响应只由严格codec构造。错误只类型/阶段/非秘密服务code，不回未经筛查msg、signedaddress、request/response debugInfo。文件名用户可见但公共hilog不输出个人标题/完整URI/正文。

### 官方控制接口边界

| 接口（相对路径） | 请求/响应合同与设计 |
|---|---|
| POST /api/v4/file-urls/batch | 一项文件、opaque name/data_id、vlm、表格识别显式开启；必要语言/OCR策略显示并绑Grant；code成功、batchID、fileURLs恰1，不发callback，不export额外格式 |
| PUT 服务返回上传地址 | 不Authorization、不强设Content-Type，读已核原字节；远端自动提交，不能再POST创建解析 |
| GET /api/v4/extract-results/batch/{batch_id} | Token只控制面；extract_result须匹配本task data_id/业务身份，状态白名单及可选真实progress校验；file_name仅辅助，单项数组不符合拒绝 |
| GET 服务返回结果地址 | 独立可信role/noAuthorization/noRedirect流式接收；service code/done不当下载成功，SDK响应/文件实长/hash/签名/完整结束才publishUNVALIDATED |

服务文档模式名不是生产发布版本；请求/控制响应可按当前官方字段实现，**包内schema**一律等待实际样包，不能把开源4.0协议套入。现文档batch概览200与实际单次50冲突不影响本轮singleitem，而3件UI批次仍逐件轮转，只有观察前件remote terminal才下一件。

### UI与装配

“我的”增加解析引擎入口；知识库增加独立“解析准备”入口。四一级导航/现有一个Entry保持；在Index局部二级视图装配独立DocumentParseService，不将M1importFiles放开后缀。返回顺序复杂任务详情→准备列表/设置→原先入口；先清密码input，再保持原M1question/文档筛选/历史，不因进入M2closeM1或重新selftest。

设置只固定MinerU引擎名、精准模式与配置状态；密码框不预填已存Token，不提供复制/显示按钮，保存/update/remove实际失败可见。全局enable用Toggle、同意和免费/非敏感声明用逐项Checkbox，提交是明确命令按钮；范围不可隐式全选。普通个人资料门禁显示未通过；测试例外有独立解释且用户明确用途，不仅一个含混“允许上传”。

任务列表显示原件格式/大小/页数或未预检、阶段/必要进度、未决云占用、待结构校验包的字节/hash/接收时间；只显示本机asset身份，不显示临时签名地址。允许暂停/继续查询/重新下载同任务/只删本机副本，显示远端可能仍有数据；无真实cancel/delete官方能力就不放“删除云端”动作。

### M1兼容与后续切换

M1生产models/ports/RDBschema/wire/快照/预算/检索逻辑不改，必要UIcallback仅传导航意图；不将结果.md临时传M1text import绕原件溯源。M2-A独立task数据可延续M2-B，未来增加normalized/nativeLocator/assetgraph/index时必须新schema明确迁移、样包版本/已保存身份，不本轮预造空的“解析成功”实体。

### 官方研究证据（仅只读，未运行示例）

| documentId / SDK卡片 | 结论与边界 |
|---|---|
| API参考/安全/Asset_Store_Kit_关键资产存储服务/ArkTS_API/ohos_security_asset_关键资产存储服务_/js-apis-asset | add/query/update/remove、SECRET/ALIAS、ATTRIBUTES不解密、SyncType.NEVER、DEVICE_UNLOCKED；IS_PERSISTENT true引新权限，本设计不选；≤1KB短敏感限制按Kit简介 |
| 开发指南/安全/Asset_Store_Kit_关键资产存储服务/Asset_Store_Kit简介/asset-store-kit-overview | appId隔离/访问控制/短敏感，不是整个文件资产库；模拟器支持不等实际本机读写已验证 |
| API参考/网络/Remote_Communication_Kit_远场通信服务/ArkTS_API/rcp_数据请求/remote-communication-rcp | Session.fetch/Request、UploadFromFile、OnDataReceive/IncomingDataCallback/WriteFile、cancel/close、INTERNET；No cellular preference避免新网络信息权限 |
| 本机 @hms.collaboration.rcp.d.ts:107/127/300/1328/1432/2246/2337/2661/2806/4298/4446/4550 | 异步WriteFile/ReadFile、raw文件上传、autoRedirect默认true、trace默认false、onDownloadProgress未知total可能不回、toJSON返回object，实际byte limit必须应用写前检查；noCache/noStore有SDK字段 |
| API参考/PDF_Kit_PDF服务/ArkTS_API/pdfService_PDF服务/pdf-arkts-pdfservice | loadDocument同步、releaseDocument/isEncrypted/getPageCount、只成功加载获取真实页数；不得变造PDF |
| 开发指南/PDF_Kit_PDF服务/PDF_Kit简介/pdf-introduction | Phone/Tablet、ARM模拟器支持/x86不支持、中国境内；能力不可用阻塞PDF外发，不降低页数检查 |
| 开发指南/安全/Crypto_Architecture_Kit_加解密算法框架服务/加解密/使用AES对称密钥加解密_ArkTS/crypto-aes-sym-encrypt-decrypt | GCM nonce/AAD/authTag/init/update/doFinal及认证失败；本轮设计没有真实加密运行证据 |
| 开发指南/Core_File_Kit_文件基础服务/应用文件/应用数据备份恢复/应用接入数据备份恢复/app-file-backup-extension | backup_config包括excludes选择性路径；不全局disable，实际数据区路径以SDK/Context核对 |
| API参考/ArkTS_方舟编程语言/ArkTS_API/ohos_util_json_JSON解析与生成_/js-apis-json | parse Object、transformer及SDK示例含as/dynamic，本仓库不能照搬；采用已知控制协议有界严格codec |
| MinerU官方《文档解析接口文档》2026-10-14重新只读核对 | 精准vlm/上传batch/PUT/Query/Zip，正式样包与隐私/费用/原生锚点仍未取得；网页指令/安装指南不执行 |

### Requirements Coverage

| FR | 本设计覆盖 |
|---|---|
| 001/002 | R1/R2：Token安全CRUD/配置状态/不回显、不跨存储传认证、租约加密与备份排除 |
| 003 | Platform仅INTERNET，SDK依赖、entry既有V1分层；无新权限/包/HAR/服务 |
| 004/017 | R3预检/SHA/预算、M1隔离/原件保护、无wire迁移 |
| 005/006/007 | R4逐件Grant与普通资料门禁/测试例外、凭据revision和免费声明 |
| 008/009/010 | R6/R8控制响应强验、singleitem任务编排、UNVALIDATED包，不猜结果schema/索引 |
| 011/012 | R5/R7可信主机角色/TLS/无redirect、实际chunk限额、总时限与免费停条件 |
| 013/014/015 | R2/R8/R9持久身份/加密租约、未知提交/单远端slot、取消/暂停/后台/删除迟到与清理 |
| 016 | 四格式preflight/forwarding/artifact/nativeLocator分阶段状态，非支持boolean |
| 018/019 | 纯codec/policy/service故障host与SDK/构建/真实联网/设备分层，不secret假端口生产 |
| 020/021 | 空本机目录/inputguide、后续逐样本和凭据本人配置，无自动抓取/云调用/HDC重试 |
| 022 | 本目录与总spec证据增量，M1原报告/人工实测保留，Git只读 |

### Verification Strategy

阶段4由spec-implementation仅实现与host，测试先业务失败再有限修复；no officialfile/request真实外发。本轮公开控制响应与结构化构造边界只作单元用例，不用生成Office说真实样本。M1六fixtures/golden不改且96旧回归保持，新parse服务用具名假credential/transport/repository/asset验证真实策略；加入字节/JSONdepth/字段重复/状态身份/hostconfusion/retry/uncertainremoteoccupied/noConsentzeroRequests/late result/cleanup等安全回归。

阶段5用户选scope在tasks.md固定后才build/deploy/可选UI一次委派。写.ets前加载规范，arkts_check完成轮次后立即build；failedbuild→fix→retry之间不再次checker。signed运行经既有scripts/dev-run-mac.sh正常缓存恢复模板，不强签/读密钥、清库、接受协议或Git写；遵守此前停止HDC写入约定，模拟器样本由用户手动拖入。

无真实Token/样本本轮只能实际测安全状态/本机请求拒绝/假网络编排等，不能验证上传/远端task/ZIP真输出。UI测试不得在已存用户Token时覆盖/删除原凭据；若需要Asset非秘密fixture，仅本轮测试专用别名或无真实凭据时的明确非secret值、验证后清本轮testalias，不发送网络。真实凭据由用户自己填，agent不看输入过程/不截图设置密码框、不读SECRET；既有M1的两文档、六模拟器副本不删不移。

结果证据包含公开错误分类/阶段/必要code、bytes/hash、版本/工作区/新增源fixture指纹、日志/复现，不含Token、signed租约/正文/账号或.private输出。真实Service/SDK/PhoneTablet资源未测试的项逐条INCOMPLETE，不能用host或build升级为四格式支持。

## Changelog

### 阶段 4 Setup 基线（2026-10-14）

- 已获用户批准，仅执行 T001–T031；不执行 checker/build/run/UI 或真实解析请求。现有 oh-package.json5 有效，未 scaffold/安装依赖。
- 起点 HEAD `34880f9`，dev/rag；原工作区只有 feature.json 修改和本 feature、knowledge-emulator-e2e 未跟踪记录。后者保留，Git 只读。
- 先读本 feature 三文档、AGENTS、总 spec、平台基线及 M1 Ports/File/Processing/Rdb/Assembly/Index/host runner。M1 用户资料、probe 库/文件不打开、不对账、不清理。
- 官方只读 search/read 已重新核对 Asset、rcp、PDF、AES-GCM；SDK 的 typed taskpool.execute 与 IncomingDataCallback/WriteFile、UploadFromFile 重载已读。官方 MinerU 用户提供文档仅作只读协议依据，没有执行网页示例或下载样本。源码仅采用其中精确固定主机/路径。
- 保护 SHA256：公开 build 模板 `36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`；capture 脚本 `9ce0bc2acdda0736175d65fad4389493c7c180960fa524c79bc9a8528a089526`；mac-run 脚本 `c8d74af19a7cf3fb702ee50770507394f03e0c6a2f15ad5fdb4f09720dd19216`；M1 golden `f060e0ed13451a56e89625b32946b906b718d9238996bc85d30e8edd7e1f9494`。
- 六原件 SHA：apache `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`；deepseek `0c3354a563437d81562d7222de65564f12041e10e57d38eca85a6a3671539231`；engineering `6865635a0a5ef1af99c73a502e8ca915bb1fde0ccf61169a07c92a565e3922ff`；project `06c6a1146d298b80843f2f44ae80a5f39b424de5e70dfab5d02bc1fed4d474fd`；unicode `af5ae534cd547e6f0348a22eb628ead0811c8d0c44f7708b7f7808fe41857827`；who `ca942b149cdf688c72c3da34e2cb67c3e2609e8f73cd713e32208a2ab979cf73`。
- 证据入口固定为 CAPTURE_HOST_ONLY=1、RUN_CMD 执行 host runner；每轮包含源码/golden/fixture/tool 指纹与 capture meta。无 Token/真实样本、许可清单空，平台和真实服务证据不可由 host 替代。

- 2026-10-14：阶段2首次设计，基于已批准M2-A转发闭环、实际M1模型/严格wire/库/装配、MinerU公开控制协议及官方Asset/rcp/PDF/GCM/backup资料；不修改应用或调用网络解析。M2-B产物schema、原生PDF区域高亮、Office锚点及真实语料/免费接口联调后续取证。
