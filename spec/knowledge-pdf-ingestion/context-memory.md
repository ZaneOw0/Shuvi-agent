# 工作进度记忆：M1 → M2-A → M2-B

## 当前补充部署：Studio 工具链（2026-10-18）

用户在此前唯一Phase5 INCOMPLETE结案后明确要求使用当前Studio路径重新构建安装，随后由用户手动验收。已独立执行成功，不重委派spec-verify、不覆盖旧失败报告：StudioCLI1.3.5/Node24.14.1，部署子进程去Agent认证覆盖和大小写proxy变量，登录预检成功；正常脚本复用签名cache，实际build1/run--skip-build1均RC0，14ets再次checkerclean，无源修改/失败重试。唯一Mate90Pro127.0.0.1:5555已重核。

signed HAP4234534B，SHA`6add1061167cb02e63ee172cc78af17f7c8f7f74b1a284c9a8bab22413456d2d`，部署前后对应；模板SHA36852083…a2fb7恢复/worktree+indexdiff0。证据`2026-10-18-ocr-fix-studio-{deploy-preflight-01,signed-deploy-01,deploy-audit-01}-a9092f0/`；部署指纹f5d6eaaff2024b28491cd3c42785a3f3edab7e8aac97d3085a2fb78384982bf2。新ignored专用限制器仅1build/1run、禁止签名生成，不复用旧guard。报告`ocr-profile-fix-studio-deployment.md`为当前补充安装记录，下面唯一Phase5失败为历史原时点。

用户功能手动验收未执行：不点击恢复/发布/向量化，不做UI/设备库探针，不发MinerU/embedding，不读Key/.local/签名raw，不卸载/reset/Git写。建议先在PDF本机任务刷新并恢复当前33页文件现有失败job，不新上传或新attempt；预期Review后由用户审查33页脚排除/19空文本并决定发布。部署成功不能保证所有新协议/超预算/损坏包都通过，仍需实际验证。

## 当前 OCR=false / worker 阶段5唯一结案（2026-10-18）

最终authority `ocr-profile-fix-verification.md`，当前build-only **INCOMPLETE**。T007/T008均已处理勾选，但分别构建PASS/部署INCOMPLETE，绝非全部验收PASS；本轮已唯一执行，不再spawn/reinvoke。14ets checker一次clean紧接实际build1/10 RC0，无源码fix/失败build/retry；host299/counter32仅沿用阶段4，未本轮重测。两次readonly清单/view均唯一Mate90Pro/127.0.0.1:5555/API26；原macOS缓存签名脚本调用1次RC1停登录预检，实际内部build0/run0、无signed HAP，不能安全部署，未login/新签/force/uninstall绕过。未读认证/签名原始输出，不能据此推断凭据真实失效。

unsigned HAP4174557B，SHA8e6443dcffc5dd14485145a0c5d1922c5aabfab2e96849e2bb803f1af0421000；模板SHA36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7前后相同、worktree/indexdiff0，脚本未进入签名替换。14ets集合SHA66b1c2e209e66261428f102de8842358c1ddf91725f4865cba909f0a2db16b03；构建/部署尝试指纹9b6a57d9a7c78edf607f332c3dec9d3d14735aef34e680931a9da69c1c64a302。capture scopes前缀`.cache/test-logs/2026-10-18-ocr-fix-phase5-`，target-01/build-01/target-predeploy-02/signed-deploy-01/artifact-audit-01/closeout-audit-01，均后缀-a9092f0、safe-host、log_exit=not-run。

无UI/截图/runtime/恢复/生产profile更新/发布/向量化/provider，不读Key/.local/签名/private/raw，不改ZIP/旧三候选/旧guard/journal/冻结gold/生产库/工具配置，不Git写。新33页包46图实际ImageKit、真实TaskPool去敏边界与Review仍未验，SC-011/013不得标PASS；旧SHA/343仅host及历史引用，没有本轮生产状态保持证明。下面阶段4是实施时点历史，不按其“待下一阶段”再次验证。

## 当前 OCR=false / worker 最小修复阶段4交付（2026-10-18）

当前权威 `ocr-profile-fix-implementation.md`；用户批准阶段1/2/3，本轮T001–T006完成，T007/T008未执行/未勾选，只交父agent下一阶段一次build-only。原result-pages/ROUND2结论与冻结gold保留，不重做旧任务。HEAD a9092f0，无Git写。

明确3.4.4/hybrid/medium严格boolean两分支：true原profile不变，false独立MINERU-HOSTED-PDF-3.4.4-OCR-FALSE-1；未知/缺失/null/string/number仍拒绝。PDF-WORKER-RESULT-1七入口具名数据/白名单category/stage/可选安全整数code，主线程沿原codec显式校验再重建；未知及调度reject按操作去敏，取消/timeout/finally/readlease/releasing保留。未发布Staging/Publishable checkpoint更新实际profile，不改processingKey/Published/Retained/活动向量。

最终host299/299（原278+21）73.859146541s，counter32/32。最终证据 `.cache/test-logs/2026-10-18-ocr-fix-host-closeout-03-a9092f0/` 指纹813430e646e0c456c59b85aeb90b8acf39588032938df3951f61b13fd4cbb10b；counter为ocr-fix-counter-01。所有实际host均safe-host/capture独占留档，红测试两轮保留。新ZIP6452636B/52CRC/展开8482133B/false规范化codec通过：342主项/346nodes/294validated/52excluded（33page_footer NodeTypeUnsupported+19EmptyText），46资产仅引用，**ImageKit/真实TaskPool/设备Review未验**。旧30页seal/verify仍snapshot7cc60225…e281/report6b57aaa8…c864精确SHA，343块及旧来源/高亮回归保持，不更新golden。

本轮checker/build/run/deploy/UI/设备动作/生产读写/provider均0，不读Key/.local/签名/private/raw，不恢复或删除三Failed候选、不新增第四attempt、不清库/卸载/reset。三候选身份与旧343实际状态只引用既有诊断/历史，本轮未读设备不冒保持实测。14个精确ets（含直接verify调用方PdfLocalAudit与准备平台case）及复现/安全审查见实施报告；下一阶段仅T007/T008，无UI/恢复/平台probe/新RPC。SC-011真实Review与SC-013后台边界仍未验。

## 当前简化增量阶段5唯一结案（2026-10-17）

最终authority `result-pages-verification.md`，本次build-only **PASS**；T010/T011已处理且构建/部署各PASS，不再spawn/reinvoke。当前tasks无currenttasks.md同名文件。17ets checker一次clean紧接首build；实际build2/10（直接1＋正常macOS缓存signed脚本内部1）均RC0，run --skip-build仅1次RC0，源码修复/重试0。Mate90Pro/127.0.0.1:5555唯一映射已readonlylist/view并部署前复核，未做任何runtime探针/UI/截图/生产页登记/查询/provider。全部旧请求授权仍耗尽，旧guard/journal未动。

签名仅原脚本内部复用既有cache，无login/license/generate/forcesign；模板SHA36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7恢复、worktree/indexdiff0。signed HAP4177165B，SHA8b6d26050b815e20553f9971a1d487a06d83b91a1e40889de494ebec6578ffd3。build/deploy指纹1bd6ac949b81d41cb5ac364cb843675744a35a81e0331d1a40a667c96db2e5c5；17ets集合SHA bf181e1132b47a21ae4d439d42c6e5aa454f88a4a6c565633332c5e0e7f25258。证据`.cache/test-logs/2026-10-17-result-pages-phase5-{target-01,build-01,signed-deploy-02,artifact-audit,closeout-audit}-9f5992c/`，全部safe-host、log_exit=not-run。限制器只属本当前增量、禁止签名生成/runtime命令及重复run，journal已完成不重跑/不删。

host278/278/counter32/32沿用实施已落盘证据，未冒本轮重测；无业务源码修改。生产343/64图/M1history16/KBhistory9/cache24及身份只引用历史基线，本轮没读库，不假称再次保持验证。SC-007–010真实页面/Span/历史/原页跳转、生产页登记与新similar仍未验；region/full16/真机压力不标通过。下方阶段4及ROUND2保留原时点，不按旧授权继续runtime。

## 当前简化增量阶段4已交付（2026-10-17）

用户已通过本轮阶段1/2/3并批准开始实施；当前tasks T001–T009完成，T010/T011未勾选只交一次spec-verify。没有重跑旧57任务/整个ROUND2。权威本轮报告`result-pages-implementation.md`、`pdf-page-alignment.md`；下面历史“未对齐/待授权”均为旧时点。

新源码：direct正文优先、ASCII fold/UTF16 ranges、Text+Span实时/历史共用、显式Similar/独立typed授权、KB-PDF-RESULT-1页证据/展示侧表、页身份与region分离。旧M1wire/search/历史和normalizer/chunker/snapshot/input/vectors未改。指定原件30页＋ZIP有界实际逐页内容对照，292受审文字nodes（287普通+5跨页）/343同adapter块，其中5块跨原页1/2、8/9、15/16、17/18、23/24；5空nodes及末页30未绑定。normalize完整节点SHA复算等冻结snapshot7cc60225…e281。受审rawfile清单SHA d99055bb…ee39，可显式导入并核actualsnapshot；**生产未登记、设备库未读，不声称343active实际复测**。

最终host278/278（原257保留+21）、counter32/32；失败两轮保留，最终`.cache/test-logs/2026-10-17-result-pages-host-final-08-9f5992c/` RC0，指纹8915f8e135dfb152b60a293275c4a9572e9036c8eddf0ee2ae945d3ec1b6a308。随后只文档任务更新。三direct建议过拟合/ROC或roc/查准率 查全率，完整离线正文计数8/25/18；冻结P03literal0，只建议以后独立授权一次similar，不是本次授权。

本阶段checker/build/run/UI/设备/新RPC全部0，没读Key/.local/签名/私有raw，没有Git写、清库或改guard。下一阶段仅default/entry/debug build-only：17ets精确清单见报告，checker紧接build、最多10实际build含wrapper、成功后重核唯一目标与cachedsign正常模板恢复run --skip-build；无UI/查询/provider/生产登记。SC-007–010页面与真实similar、region/full16/真机压力未验不标PASS。所有旧provider授权保持耗尽。

## 当前动作：真实 PDF 候选题集（2026-10-17）

- 用户随后明确选择“确认题集，先冻结不外发”：两份题集文档现冻结为`R2-REAL-PDF-GOLD-1`，JSON状态`FrozenAwaitingOfflineAlignment`、`frozen=true`、`cloudRequestsAuthorized=false`、`scoreComputed=false`。16题/原页预期/多证据方式与12定位点已确认；不得覆盖V1迎合召回结果。原页到块对齐另存，仍未执行；新云请求必须独立确认，R025保持未完成。下列候选状态为冻结前历史。
- 用户已同意先在本机拟定《02_第02章_模型评估与选择.pdf》的核对题集，再交其确认；该同意不授权任何新的模型请求、重解析、生产索引或定位修改。
- 找到并只读指定原件`.cache/m2-input/user-pdf/02_第02章_模型评估与选择.pdf`，SHA256核为`7f959de85fdab10b15e2aada044d9f1fbd75dbc90b2fabfca79eb9ecb4b3df3a`，读取30页原图。原页1无可见印刷页码，原页2–29对应印刷24–51，原页30目视无正文/有扫描痕迹；这不升级服务页映射或自动空页规则。
- 新增`round2-pdf-gold-candidate.md`和`.json`：8改述、4否定/范围、4无答案候选，19个原页内容锚点、12个定位/结构抽检点，当前`CandidateAwaitingUserReview`/`frozen=false`/`cloudRequestsAuthorized=false`/`scoreComputed=false`。
- 题目和预期只依据原PDF，未使用新的chunk/检索排名/模型答案；独立原页复核已校正ROC公式依据、噪声项ε²和表2.5表头表述。多要点题以all-required分组，不能命中其中一项就当整题证据充分。
- 下一步先展示候选题/原页及待确认评分口径，使用question等用户核对；冻结题集与执行云查询是两项不同授权。R025仍未完成，所有旧provider授权仍已用完。本步无源码修改/构建/部署/设备操作/检索或任何云请求。

## 当前增量：Residual 与 R007（2026-10-17）

HEAD仍9f5992c/dev/rag，无Git写。本轮按定向review修复KnowledgeSearchService暂停history：pending与fixed-record/writePromise settlement独立queryepoch、pause通知、resolve自动清阻塞、reject重入可见retry，同ID最终一条，不改result/id。EmbeddingWorkflow.searchReviewed补共享invalidateResponse，模型错/400/413/422使fixture检测Failed/ContractRejectedPaused/approval撤销/下一request拒绝/lease0；生产真实rev2Passed/basis保持。

R007已真通过并关闭：新隔离ResidualIngestionFixture合成原件+两真实STORED ZIP A/B（各3协议JSON），正式PdfIngestionView/service/TaskPool/仓储/资产走A发布→B故障重试→newattempt按钮→新报告确认B切换/A Retained→恢复幂等、abandon确认/cleanup retry、retained清理、delete/publish两序无复活；源3文件hash保持，生产无新report/ZIP/rebuild。额外deferred history UI resolve/reject重入/显式retry真库一次通过，无cloud。

本轮独立计数：checker2 clean/build3 PASS/run2 PASS；host2轮257/257（原255+2）、counter32/32；fix2轮18/18、workflow2轮32/32（原28+4）、native11/local28/vector21/basis33各最终1轮全PASS。最终signed SHA d2877ab60b07169f18f0b43451b496506e4e77814790a576f8412835a4bfdaf2，4022541B；模板36852083…a2fb7/gitdiff0；最终指纹64f120facb5327ca57b1eb6347a7b47d4f933099bef235a73877ecba53465722。失败只helper屏外/长链超时，报告留存，不冒通过。

生产343sameSHA/active/Synced/64图/M1history16/KBhistory9/parse/originalZIP/currentrev2/cred1Passed基线保持/全部lease与source/vectorpending0；qualitycached24/16/Recall1MRR1一致/requests0。最终生产账本60371524B，质量15568896B分别记，不把SDK日志文件族读数下降当手清数据。所有provider授权已用完，本轮新增请求0；旧guard/log不动，不索取新授权。R025私料内容/区域gold仍inprogress，真机/容量掉电等长期边界单列。当前权威见round2-closeout-report.md文末本轮增量与round2-tasks；下面八项收口及更早章节均为历史。

## 当前交付：八项收口（2026-10-17）

HEAD仍`9f5992c`/dev/rag，所有provider授权已用完，本轮**零网络调用**。当前权威为`round2-closeout-report.md`与任务表当前交付段，下面“最新状态”和2026-10-16内容均为历史。八项review缺陷均已实施+真Kit/UI实测完成，不能再称它们长期待办：typed双向query/trial consent、source新deadline/epoch、session持有adapter/close/durable receipt重开retry、最终hit/release/visibility/history截止、诊断不改配置/基线、node/cells/公式分页及合成双region像素、repo文档任务分页、实际版本环境持久capability audit且本进程不信diskAvailable。

最终host255/counter32/native11/local28/vector21/basis33/EMBED28/修复16全部PASS；build11次8成功3失败、run7次全成功，所有失败保留，未读.local/Key/签名、未卸载/reset/Git写。signed SHA `2109c77a4e700467bc0af0374e6b663daf481aed628632fbb902be6e9314e89a`，3903205B；模板36852083…a2fb7与Git一致。最终源码指纹`b8bae33609cf24784f381a99791496cca01016c080a30e14747187621c0ec453`，范围见capture meta。

最终生产343active/Synced/SemanticReady/1024/Unknown0/同readbackSetSHA `7fd6351e6ef82270a9e0213928a6c8aa5f784454c4510e583e9a52392b69a1b3`，64/64图、M1history16/KBhistory9、parse/原件ZIP/原snapshot/report均保持；rev2/credRev1/Configured/Passed-current/basisAccepted不变；leases/source_pending/vector_pending0。质量scope a220261017240001缓存24真实向量/16结果/Recall1/MRR1保持，未重发。最终生产账本151335378B，质量15552512B分别记录，不清资料降数。

R003迁移/来源/typedcleanup当前契约已验关闭；R004/5/6/8/11/12/13机制/16/19/20/21/22/26按实际范围完成，长期压力单列，不反向打开。R007同源不同ZIP新attempt完整UI/全竞争组合仍具体未验；R025私料内容/原页区域gold仍未验需另定gold和授权，人工检索质量不替代。真500MiB/max2000/每提交kill掉电/全资源失败/极端DB硬10s/其它ABI真机/非JPEG新格式单列。后续只按新任务处理，绝不重probe/query/quality或删除旧guard。

## 2026-10-17 最新状态

以下旧2026-10-16阶段记忆仅为历史，不再按“未填Key/未实现vector/待首次build”推进。最新权威为 `round2-implementation-report.md`、`round2-verification-report.md`、`round2-tasks.md` 和 `round2-semantic-quality-report.md`；父计划不回写，不恢复旧guard或重新提问已完成授权。

- 生产PDF已正式发布343关键词块、64图全读回，全文343真实向量active/SemanticReady/Synced/1024维，Unknown0/remaining0；doc `kb-60986788281e094aff01063dfcf764f1`、content `kb-e144c7dff2b309d638cfa10b14604e3b`、snapshot `kb-68c7504281b1a324817d2390b5c021e6`、job `kb-a559722e0fceb2006b145f2ad9e6c656`、space `kb-5f85a339550011dce2c68243d97e2b1f`。readback集合SHA `7fd6351e6ef82270a9e0213928a6c8aa5f784454c4510e583e9a52392b69a1b3` 最终仍一致。
- 当前SiliconFlow精确BAAI/bge-m3/revision2/credentialRevision1/Configured/Passed-current1；固定工程计数基线已用户接受并绑定revision。proof.verified=false/providerRevision=NotReported/providerConsistency=UnverifiedRevisionAndHiddenProcessing，不能称线上严格同版。Key只应用安全存取，禁止读取回显。
- 历史models1/probe1、首3corpus+trialquery1、续340corpus+正式query1均已执行停止；本轮另获人工fixture8document+16query独立授权，实际24次全HTTP200/1024维/无重试，reported usage222+238=460。所有历史授权均已用完，**不再发送任何provider请求，不删/换名guard/journal续跑**。
- 新独立scope `a220261017240001`：只F01–F08规则正文与原JSON16question，原MD SHA de11199f…e2201 / gold SHA 32daf326…86b09；未改冻结文件/gold/阈值。真实hybrid答案12题Recall@5=1/MRR=1、改述补回8、否定gold第一4/4；无答案4题近邻非空但未生成答案。N01相反F02仍第二、不得计正确；P03仅验F03的21/14证据，不验35天生成。
- 质量数据在独立普通/向量库，不入生产343/M1/历史，24真实向量与16结果持久，缓存重开、真新进程和最终制品纯本机复算完全一致。后续允许本机 `semantic-quality-evidence.cjs` 或显式缓存核验，不能再次点真实24请求。
- 最终host252/252、counter32/32、模拟器native11/local28/vector21/basis33/workflow26均PASS；本轮build3/run2全PASS，无卸载/reset/force-sign/Git写。signed SHA `1a0c3e642c23929accf841bb24d9471e07450cb34cebb4d98f98294db0f5edb5`；模板36852083…a2fb7与Git相同。
- M1摘要f2fc7436…dd2b、parse f9256fed…a8308/原件ZIPhash/旧history16/KBhistory9/64图/assets65/ledger1350219/leases0保持。生产预算107739236 B、质量scope15495168 B，文件族/WAL保守记录，不清资料降数。完整ID/hash/证据目录与复现命令见质量报告。
- 人工小语料检索质量PASS不等私有PDF内容质量/区域gold/生成回答正确/自动拒答/真500MiB/max2000/每提交kill或掉电/全资源故障/极端DB硬10秒/其他ABI真机。R025/R026等仍部分完成，禁止批勾。当前工作已停止provider，后续仅按新任务处理剩余边界。

更新时间：2026-10-16。阶段 4 最终状态 **PARTIAL**，以 implementation-report.md 为实施交付/证据权威。37/55 实施任务勾选、18项未完成；阶段 5 已唯一执行，T056/T057 已处理且构建部署各 PASS，整体 **INCOMPLETE**，权威见 verification-report.md。此文件不改变历史验收结论。

## M1

- txt/md原字节保存、结构切块、关键词检索、原文定位、管理/恢复、历史引用已实现。
- 用户已有两份MD资料检索可用反馈；M1用户库、原件、历史、wire和旧活动索引保留，不清库/不暗中送云向量化。

## M2-A

- 当前基线HEAD `9f5992c`。MinerU安全Token、PDF/Office转发、Query、ZIP接收已实现，精准raw PUT用单空格content-type抑制RCP默认类型的403问题已修。
- 已取得真实ZIP：8,461,084B、SHA256 `548162c5bb0f6a93d0fe76d4a5a17399f87b0a882c84d4510e7c2ead5fc12a05`，70/70 CRC通过；task/data `m2-7eaa150e269374313fd776f12a2ae9fa`、original `m2-731441b8eec54bdecc16effb0192c2c2`。task/data不等远端batch。
- 包346块/30页/7表248单元格/64图。包内重写PDF不等原件；5空文本块、跨页风险和末页无块未定为空白。应用内仍UNVALIDATED。
- 前台切页不暂停，后台/显式暂停等停止本机；解析库已到v3。旧失败/修复只引用 `../knowledge-document-pipeline/transfer-zip-content-type-fix.md` §8及历史报告，不重发MinerU请求。

## M2-B 本轮

- 用户已批准本目录 spec/plan/全部57项任务及 Start implementation；本轮已执行阶段4源码/host，未进入 checker/build/deploy/UI，实际 PARTIAL，不能恢复为“未授权”或“全部完成”。
- PDF链：既有ZIP → 安全容器/结构/资产校验 → 规范化/原页映射 → 结构分块 → 关键词入库 → 独立云embedding → 同空间向量存储/KNN/融合检索。图像只核对/图注召回，无视觉tag/聊天LLM/Office原生适配/同步。
- 嵌入UI四家：硅基流动、百炼、Gemini、OpenAI。真实Key由用户在应用填，不发对话、不读MinerU Token复用。
- 硅基BAAI/bge-m3为首验目标，官方列表可按embedding筛选；实际列表与固定短句真实embedding检测分开，服务文档枚举矛盾不猜可用性。
- 百炼显式北京/新加坡和官方接入方式，专属用WorkspaceID、严格官方格式；未核模型发现则手填官方ID。
- Gemini/OpenAI官方正文目前不可访问，允许先完整安全配置、真实请求/发现禁用待取证。Cohere不在本轮。
- 独立云授权只针对获准PDF校验块和问题，默认关闭、仅免费资格；保存/列表/固定句检测/语料外发不互相授权。不自动向量化M1。
- 内容规则：正文/标题、公式、表格、图注入检索；页眉页码元数据；参考文献/旁注独立类型默认排除可包含。缺失/未知映射可用户明确确认部分可用，未验证区域不伪高亮。
- 预算：PDF20MiB/50页、ZIP30MiB、展开100MiB/1000成员、单JSON8MiB、图片2000万像素、2万节点/4万cells、单PDF2000块/总PDF1万块、派生500MiB、本地阶段120s、查询10s、向量请求120s/窗口15min/单活动任务。超限保留旧数据，不截断假成功。

## 当前下一动作与保护

1. 先读 verification-report.md、implementation-report.md 与 tasks.md：阶段5已唯一处理 T056/T057，不再委派。构建/部署各 PASS，整体 INCOMPLETE；实施37项勾选、18项缺口保留，不能将 build/deploy 成功改写为全功能完成或仅缺 Key。
2. 优先查本目录spec.md，不重开M1或M2-A调试；坐标/结构/向量库等必须取证，不以开源4.0协议替当前托管3.4.4特征。
3. 没有用户真实embedding Key，本轮可代码/host/关键词闭环，真实语义必须记录未覆盖，等待用户配置实测。不能造向量或使用旧PseudoEmbedding。
4. 本轮更新约束为不读 `.local` 的任何文件，不读取Key/签名。保留 `spec/feature.json` 原脏变更及未跟踪paste脚本/模拟器feature；未读/运行paste，不设备访问/HDC写入/卸载/reset/Git写入。真实Key以后由用户在应用自行输入。

## 阶段2设计摘要

- 保持V1和knowledge五层；M1先bootstrap/验证，再对原普通用户库增量建kb_*扩展，M1Ready/扩展Ready独立；TEXT-SNAPSHOT-1/旧历史不改。新派生ArkData vector store避免原地转换旧vector:false库，不引第二数据库引擎。
- v2规范化为唯一内容源，v1/layout审计；raw-DEFLATE交系统zlib流，应用负责受限ZIP容器/CRC/实际字节与typed JSON/惰性表格。SDK流/取消仍需设备实证，不能无界解压替代。
- 具体原页/区域证据分别验证；未知本包坐标不高亮/不伪准确跳页，可显式部分发布。安全硬失败不可绕过。
- M2-A原件/ZIP通过持久pin保护；pin/job原子登记、checkpoint/active转移与显式放弃，发布/清理claim互斥；取消/删除epoch与幂等键阻止晚到复活。
- 统一关键词候选→同空间真实KNN→RRF；生产入口只写一次新历史，旧历史只读合并；M1不自动向量化。
- 目标模型还需完整输入Token保守上界证据；未证明时corpus/query禁发，不能把512代码点/2048字节保护线或服务usage冒Token证明。固定句检测仍可由用户独立确认触发。
- 以上为批准设计历史；当前已有阶段4源变更。没有本轮构建、部署或真实embedding请求，plan.md正文仍为设计基线，不能当实施完成说明。

## 阶段3任务摘要

- 共57项：Setup2、Foundation10、US1配置6、US2固定检测4、US3安全规范化9、US4关键词/原件7、US5向量8、US6统一生命周期6、Polish3、Verification2；P1共51/P2共6。
- T001–T055只委派实施agent；T056–T057只委派一次验证agent。验证段标记build-only，仅build/deploy，不做自动UI或真实服务请求。
- 平台zlib/PDFKit/普通库迁移/vector/KNN与语义改述/否定/无答案评估用例要准备，设备/真实Key/质量执行本轮延后。输入Token上界未知仍禁corpus/query外发，固定检测与模型列表不等语义就绪。
- 已收到明确 Start implementation，不再重复询问。若新增/改变需求，不能以本轮代码缺口为由擅自扩权。

## 阶段4实际交付与恢复要点

- 基线 `9f5992c3945975b97349767f0c9e0b4777920ecd`；现有工程保留，未scaffold。新增30个源码职责文件，额外纯 `PdfSnapshotCodec/PdfMappingPolicy` 分离；精确文件列表在实施报告。M1 models、处理/wire/旧历史、六fixtures/golden、解析库v3、依赖/权限/SDK均未改。
- Shared host M1先bootstrap，普通库KB-PDF-EXT-1独立失败状态、write queue/leases；job+pins同事务，原件/ZIP仍属M2-A；所有解析资产删除/cleanup走同保护，未知fail closed。
- 四提供商本机安全配置，AssetStore别名按用途/提供商/百炼地域接入分开；密码不预填、切页/后台清；未保存配置禁止Key和网络动作。硅基sub_type=embedding真实列表适配；硅基/百炼固定句一次float检测，真实provider从未调用。Gemini/OpenAI网络禁用。
- SafeZipPolicy通过指定真实ZIP通用metadata校验，native raw(-15)/incrementalCRC/SHA/实际预算有代码但 `PdfArchiveAdapter.inspect()` 固定 NativeZlibRuntimeUnverified，生产不入库；隔离平台entry待后续证据。无无界decompressFile/手写DEFLATE。
- typed JSON（8MiB/64/256KiB/256keys/1Mtokens）、惰性表格和3.4.4唯一v2规范化有host/真实包结构通过；JSON后台worker、图像完整解码验证/资产中断恢复尚未完整，不能假全量支持。
- 结构chunks、关键词staging/approval/epoch/cleanupClaim、统一M1/PDFkeyword、一次kb历史及旧M1cursor只读合并已写。真正原件hash+几何/只读像素预览有代码/读租约，但没有已证页跳转/多区域高亮或完整结构图像核对UI。
- 独立vector:true S3/fixedN/KNN代码只隔离入口，生产open固定 VectorStoreRuntimeUnverified。**US5实现未完成**：corpus/query任务、覆盖发布/跨库eligibility、queryKNN/独立授权UI不完整。缺Token上界时两者均InputLimitUnverified，vectorizePdf只门禁说明，publishVectors拒绝，不是“只差Key”。
- 普通库archive/delete/abandon/ReleasePending/readlease/claim/cleanup重试已写；vector跨库清理遇generation拒绝，retained世代安全回收/向量预算/丢失资产统一引用对账仍未完整。旧资产不清库“修复”。

**已勾选**：T001–T022、T024–T025、T027–T028、T030、T033–T034、T038、T040、T044、T049、T051、T053–T055（37）。
**未完成**：T023、T026、T029、T031–T032、T035–T037、T039、T041–T043、T045–T048、T050、T052（18）。失败原因和逐项下一步见实施报告。部分初评checkbox已在最终完整审查撤回。

## 本轮host与证据

- 最终 `.cache/test-logs/2026-10-16-m2b-implementation-closeout-9f5992c/`：250/250，RC0，71.985s；217历史保留+33新增。工作区指纹 `49eca2f8e1353d4fb2464485702794402ef3e4cae8b898a720f182cd2cc5b313`，dirty57。之后仅回写证据指向，无源码改动；前轮m2b-polish-final保留。
- 真实ZIP离线70/70CRC、11,926,995B、346主块/340inline/46公式/7表248cells/64资产；5空块、末页29未知、16cross_page/5lines_deleted有断言。未输出正文，未读原件来猜hash，应用仍UNVALIDATED。
- 新host SQL注入曾暴露generationINSERT13占位符/12列，修后4/4；历史空routes读成一空项，修后最终全绿。失败/修复日志保留，不删难例。Node zlib/SQLite只是host替身，不冒HarmonyOS平台通过。
- capture-test-log.sh字节未改；support增加CAPTURE_SAFE_HOST=1，host-only在.cache独占临时，指纹排除paste/私有目录/签名配置，默认行为不改。summary runner内存消费TAP，仅公开计数/允许numeric metadata；含敏感词的早轮日志被原过滤整体withheld，未读raw。

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" \
RUN_CMD='node entry/src/test/run-host-summary.cjs' \
/bin/bash scripts/capture-test-log.sh m2b-implementation-closeout
```

本轮checker/build/run/设备/UI/真实服务/语义质量全未执行，留给后续明确范围。没有任何真实模型成功或平台验收证据。

## 阶段5唯一验证结案（2026-10-16）

- 范围严格 build-only；44 文件 checker 一次无报错，但首 build 真实失败（3处结构类型，ERROR4/WARN638）。三文件限定修复：EmbeddingTransportAdapter 的 Promise reject 用 Object；PdfArchiveAdapter 显式有界 ArrayBuffer；PdfAssetAdapter 显式实现已有 cleanup port。未改装配行为/旧 wire/门禁。失败后直接重 build，无重复 checker。
- 实际 build **3/10**：第1失败，第2 unsigned/编译通过，第3正常缓存 signed 通过。首次代理登录预检阻塞未触发 build；已有独立 CLI 子进程仅取消两个代理 auth-source 环境变量后预检通过，无 login/签名生成。ignored guard 禁止 generation/额外 build/run；signed wrapper 的 RC125 是有意在实际 run 前停止，非第4 build 或失败安装。
- 独立 `--no-build` 正常脚本部署，唯一 Mate 90 Pro/127.0.0.1:5555 映射经 device/emulator list/view 重核，实际 `run --skip-build --product default --device 127.0.0.1:5555` **1次 RC0**。无重试/卸载/reset/HDC写入/设备 runtime probe/UI/截图/真实 MinerU/embedding。
- 修复后 host **250/250，72.001675334s，RC0**：`.cache/test-logs/2026-10-16-m2b-verify-buildfix-host-9f5992c/`。第2 build/host/signed build/deploy 的公共特征指纹同为 `543823a4de417a5cfc27615f8b5f201a3bc200f81596a11816b851f92177536b`（dirty57）；之后只有文档结案增量。旧六 fixtures/golden不变。
- 证据 scopes：`m2b-verify-build-01`、`m2b-verify-build-02`、`m2b-verify-signed-build-03`（预检阻塞）、`m2b-verify-signed-build-03-independent`（实际build0/总125）、`m2b-verify-deploy-01`、`m2b-verify-final-audit`，均 `.cache/test-logs/2026-10-16-<scope>-9f5992c/`。每轮 safe-host capture，设备 log_exit=not-run，未拿私有日志补断言。
- 当前 signed HAP SHA256 `6670bc403f2559da33ffe4ab35382d6b8efc6f825d5bd06789bf0cc7ba8a27f8`，2,271,306B；模板前/后 SHA256 `36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`，无模板差异。源修复/产物摘要和完整复现命令见权威报告。
- **仍 PARTIAL/INCOMPLETE**：18 项实施任务未改勾选；NativeZlibRuntimeUnverified、VectorStoreRuntimeUnverified、InputLimitUnverified 保持关闭；真实ZIP应用仍UNVALIDATED，US5完整作业/查询/授权/跨库恢复未交付，不是只差Key；平台/原页/服务/语义质量仍未验。UI/Phase2按build-only跳过，不作为额外UI失败。未读私人配置/Key/签名/.local内容，只有正常脚本内部复用缓存；无Git写操作。
