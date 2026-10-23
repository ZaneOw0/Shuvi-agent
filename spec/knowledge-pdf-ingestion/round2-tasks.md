# ROUND2 任务

状态必须按完整实现与实际验收记录，部分实现不勾完成。父计划不回写。

## 当前交付（2026-10-17）

R025题集准备增量：用户已确认真实原PDF的16题、原页预期、多证据评分及12个定位抽检点，现冻结`R2-REAL-PDF-GOLD-1`；文件摘要见[冻结记录](round2-pdf-gold-freeze.md)。本次只本机原件阅读及文档冻结，无新检索/模型请求/生产修改。原页到块的独立对齐、正式评分及真实区域定位仍未执行；不是R025已通过，也不恢复任何旧外发授权。

本轮定向residual增量：暂停history settlement独立epoch（真deferred resolve/reject、页面重入retry及固定ID一次）、reviewed模型/400/413/422错误共享停用分类均修复，R007隔离双ZIP正式PdfIngestionView的rebuild/resume/abandon/retry/候选切换/retained cleanup/删除两序UI实际通过。当前最终host257/counter32/native11/local28/vector21/basis33/workflow32/fix18、build3次/run2次全PASS，零provider新请求；完整证据/本轮独立计数见 [收口报告文末增量](round2-closeout-report.md#两项-residual-与-r007-ui-结案)。下段八项收口为上一轮历史。

HEAD `9f5992c`，8项review实际缺陷均已修复并在模拟器验收，详情与精确case/证据/次数见 [交付收口报告](round2-closeout-report.md)。本轮 **零新增provider请求**，所有旧授权已用完；最终host255/counter32/native11/local28/vector21/basis33/workflow28/修复16全部PASS、成功build和增量安装。生产343active/Synced同readbackSHA、64图/M1history16/parse/原件ZIP、质量cached24与指标一致，全部release计数0。

下表completed指批准的当前实现及已列实测范围，不表示真机/无限故障矩阵。长期压力/掉电/私料gold统一列末尾，不再作为已实现项永远in_progress的理由。下方旧“最新结论”段为历史阶段。

历史质量轮增量（本轮收口前）：独立人工8规则/16题实际24请求及冻结gold检索质量PASS，hybrid Recall@5=1/MRR=1、改述补回8/否定4/无答案不生成4；缓存重开/真新进程/当时制品均requests0。当时host252/counter32/native11/local28/vector21/basis33/workflow26全部PASS，生产343同hash/Synced/M1/原件ZIP/64图保护通过。逐题原始证据见 [独立质量报告](round2-semantic-quality-report.md)。该时点R019/R021/R025/R026尚in_progress；当前状态以本表和收口报告为准，全部provider授权禁止重发。

| ID | 任务 | 状态 | 证据 / 剩余 |
|---|---|---|---|
| R001 | 范围、基线、存量保护、记录 | completed | 四份新记录；正式处理前后 M1 / 历史 / 原件 ZIP 身份一致；父计划及旧报告不改 |
| R002 | 隔离 scope、runner、fixture、断言、故障、安全日志 | completed | 已核 aa test 合同，采用批准显式诊断页；最终 native11/11、本机28/28，受控 Kit/metadata 日志；不是 ohosTest HAP |
| R003 | EXT-2 增量迁移 / binding / checkpoint / owner | completed | 当前契约/迁移回滚与重开、来源binding/checkpoint、chunk节点、typed多空间cleanup/ledger已实现并由LOCAL28/EMBED28/VECTOR21验收；旧不可证来源保持NotRecorded，非实现缺口 |
| R004 | 旧状态、恢复租约、会话关闭、入口绑定 | completed | 既有close/acquire/close-retry/lease失败持久化通过；新增来源adapter会话所有权、在途cancel/lateclose、source专用durable receipt与新对象重开retry实跑；最终leases/source_pending/vector_pending0 |
| R005 | TaskPool 分段 JSON / normalize / snapshot / chunk | completed | 有界TaskPool normalize/seal/verify/chunk/逐节点encode-hydrate、8MiB/cancel/deadline已有实测；typed有界整体返回不认定违约，未大重写。极限峰值/帧率另列长期 |
| R006 | 完整图片解码 / 资产关系 / 原子恢复 | completed | 已验JPEG本样64图解码读回、JPEG-1/1.4MiB/同世代复用/五资产边界/commit→checkpoint恢复与总账本；不承诺非JPEG，掉电压力另列 |
| R007 | 启动任务 / 重试恢复 / Prepared / rebuild / abandon | completed | 同source合成A/B两个真实ZIP走正式PdfIngestionView/service/repo：A发布、B故障原ZIP重试、新attempt按钮/报告确认/B发布切换旧A Retained、恢复同job/generation/chunks不重复、abandon确认/cleanup retry、Retained清理、删除先后两序无复活；来源3hash不变/lease0。生产未重建，详见residual-r007各UI证据 |
| R008 | 真会话自检 / 生产 inspect / typed capability | completed | 真实Archive/Vector当前进程自检；新增layout1持久audit，实际bundle版本/API/OS/ABI/impl/suite/结果/time/hash、环境Invalidated、新gate不跳selftest、FAIL/Releasing failclosed均真库实测；disk Available不授予 |
| R009 | 构建部署 / 模拟器真实 zlib suite | completed | 最终build成功、累计15增量run，最终native11/11，历史失败保留 |
| R010 | 真实 ZIP 覆盖审查 / 关键词发布 | completed | 用户明确确认原report，正式UI发布343块；真实快照/64图全重读+hash，346/340/46/7/248设备独立计数；两次真重启仍KeywordPublished；不等全文OCR/定位质量通过 |
| R011 | 查询 / 原件结构核对 / 历史 / 管理 | completed | 关键词/原件/历史/归档恢复既有通过；补repo文档/任务SQL分页、有界node/cell/公式详情，模拟器选择/分页和合成高亮像素实测；不推广私料区域正确性 |
| R012 | 重开 / 提交故障 / 租约清理 / M1 | completed | 已列提交故障/真进程重启/租约claim/cleanup新对象retry/M1保护完成，新增source失败receipt-reopen/lateclose通过；每边界真实kill/掉电单列长期 |
| R013 | 页区域证据 / 跳页高亮 | completed | 映射codec/CRUD/来源绑定、四rotation双区gold及实际crop90双高亮屏幕像素通过；node切换/公式/表cells UI实际跑。完成范围为机制+独立合成gold，私料gold仍R025未验 |
| R014 | 向量库 open / dimension / reopen | completed | 本机API26：先持久Planned→DDL→探针同事务回滚核布局/固定N→registry+Active原子提交；空space/DDL前后中断新对象与真进程重开通过；active缺表不建空；范围限当前模拟器，持续环境审计/极限压力不冒真机 |
| R015 | 向量平台 suite | completed | 本轮真实21/21（含empty-reopen、DDL before/after recover）+真进程2/2；固定N、复合键、回滚、异空间、余弦、readonly错维、missingactive拒绝，不等语义/真机 |
| R016 | 覆盖发布 / 镜像 / cleanup / 账本 | completed | 完整集合/343实际publish-mirror-ACK、SQL前滤、多空间typedclaim/reopen-retry/向量退役/Retained/物理文件族共享开销账本已实现验收；500MiB压力等另列 |
| R017 | 官方分词 / 可靠计数 | completed | 用户明确接受固定工程基线，真实资源3hash/TaskPool/完整textHash与bindingHash Kit核对、22设备golden；独立32/32两次+最终一次，共3次。verified始终false，local资格=Safe+已接受基线绑定当前revision；providerConsistency未披露持续保留，不等线上同版 |
| R018 | 文档向量作业 / 恢复 | completed | 2026-10-17按新授权同job续340请求全HTTP200，旧3不重发、Unknown0；343全identity/hash/维度有效读回→事务publish→镜像readback/ACK→SemanticReady，真新进程恢复PASS。范围为此343块实际闭环；最大规模/15分钟极限/故障全组合另列长期，不冒全压力 |
| R019 | query / KNN / RRF / 降级 | completed | 真实检索与人工质量历史保留；截止修复后再补暂停history deferred settlement/重入retry/固定ID一次，reviewed错误检测Failed/撤同意/下一request拒绝，workflow32/fix18真库+UI验证，生产Passed不改/无新云请求 |
| R020 | 独立授权 UI / 空间管理 | completed | 双向输入/clear/count/space/config失效，typed snapshot handler和workflow发前核验，真实UI与15组无grant/call对抗通过；文档与任务分页、原343输入12page保留。压力另列 |
| R021 | 无 Key 编排 / 独立 gold | completed | host255/counter32/basis33/EMBED28/修复16全部PASS；人工16题冻结gold真实结果及缓存复算保持，无Key配置依赖，不推广私料 |
| R022 | 跨库故障 / 切换 / cleanup | completed | 当前已列故障注入/lease释放retry/close/model/维度/预算边界/active缺表/DDL恢复/3+2机制验收完成；全规模/每提交真实kill单列长期 |
| R023 | 等用户应用填 Key / 免费与外发确认 | completed | 2026-10-17用户明确question已手动保存Key/清框离页，应用metadata确认Configured；SiliconFlow/BAAI/bge-m3 revision2/credentialRev1，当前同profile工程基线已重新接受。本次免费/用途仅models一次及列表有目标后probe一次；不含PDF/query/完整语义 |
| R024 | 真列表 / 固定句 / 小规模向量 | completed | 前轮models1/probe1不重发；本轮独立question授权首3块corpus3次+固定query1次，4次HTTP200/1024维、无重试；暂存readbackSHA/只3块KNN/来源/keyword对照/RRF metadata通过。expected343/Verified3/remaining340/active空/Paused；不是SemanticReady或语义质量通过，详见报告最新3+1章节 |
| R025 | 获准 PDF 语义质量 / 重开 | in_progress | 全文343机制/同hash/Synced/正式query及真重启PASS；新增独立人工8规则16题真实24请求PASS，hybrid Recall@5=1/MRR=1、改述补回8，缓存重开结果一致。该人工质量不是实际私料PDF质量；私料gold/regiongold仍未验，不标全done |
| R026 | 最终全回归 / 部署 / 结案 | completed | 八项修复交付，host255/counter32/native11/local28/vector21/basis33/EMBED28/修复16最终PASS，成功build+增量安装/343同SHA/64图/M1/ZIP/cache24/lease0/template审计；报告记录具体未验，非全功能宣传 |

## 独立未验清单

- R007 指定的同源双ZIP新attempt正式UI与删除两序/abandon/Retained cleanup现已实际验收，当前completed；无限故障/掉电矩阵不在此结论内，旧未验记载保留为历史。
- R025 真实PDF的原页题集已确认冻结V1，但原页到现有节点/块的独立对齐、正式检索评分及原件区域验证未执行。缓存人工质量PASS不替代；如需新真实embedding必须另获独立授权，所有旧请求授权仍已用完。
- 长期：真500MiB/max2000/每提交kill及真实掉电、所有资源释放故障组合、极端DB硬10s、其他ABI/真机、非JPEG等新格式不在本轮完成声明。此处不伪勾，也不反向打开已经验收的8项代码修复。

## 历史阶段记录

固定工程基线续做时点：已READY到R023用户设置阶段，不等全部M2-B完成。343输入Safe/eligible343、unproven0/invalid0、总bound41751/max459，set fe601268339387c7682653440a71d06cbf5ba872af5c6e6717c8ae32146f2a04；当时无外发grant/请求/生产vectors，生产343关键词和64图保持。长期极限/质量余项单列，不再把其混作Key前阻塞。

2026-10-17最新：已执行用户批准的models/probe各一次，两步PASS，停在probe结果。上段“无请求/Key Missing”仅为前阶段；本轮只有models/probe grant，仍无PDF/query grant或vector任务。R024等待父agent再question确认3块与具体query；本agent不自行问用户。

2026-10-17后续最新：本轮获独立3块与固定query授权，已真实3+1 PASS，全部停止；R024小规模链完成。生产现在只有3条eligible=false暂存向量，非生产active语义，全文343块未完整向量；父agent下一步另question完整范围及实际queryset，不沿小试授权续跑。

2026-10-17最终最新：用户另授权同任务剩340及全文完成后固定query1；实际340+1全部PASS，旧3零重发，全文343active/Synced/SemanticReady、Unknown0、剩0。完整检索证据与新进程恢复均实测，无chat/16题质量请求。R025只全文机制通过、质量未验，后续父agent讨论私料gold与真实质量授权。本轮真实额度已用完，严禁再点续跑/query/models/probe。
