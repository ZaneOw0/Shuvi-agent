# ROUND2 交付收口报告

> 当前交付增量为文末「两项 Residual 与 R007 UI 结案」，2026-10-17，HEAD仍`9f5992c`。前文八项收口的制品/次数是上轮历史，本轮计数独立，不相加冒本轮结果。R007现已按实际UI证据完成，R025私料gold仍in_progress；本轮provider请求0。

## 交付结论

2026-10-17，HEAD `9f5992c` / `dev/rag`，在保留已有 dirty worktree 的基础上完成用户 review 指定的 **8 项实际修复**，最终源码已成功构建并正常缓存签名增量安装。没有发送任何新的 provider models/probe/corpus/query/quality 请求，没有 MinerU/LLM 请求，没有读取 Key/签名缓存内容、卸载/reset、删除旧日志或 Git 写操作。

本报告是此次收口的当前交付记录。`round2-semantic-quality-report.md` 保留前轮唯一24次真实请求及原始指标；其他报告较早章节为带时间的历史，不再把每段“最终最新”理解为当前结论。父批准 plan 未修改。

最终回归：**host255/255、counter32/32、native11/11、local28/28、vector21/21、basis33/33、workflow28/28、独立修复suite16/16**。保留原host252；新增3条host测试，workflow原26条保留并新增2条。basis33条数量不变，其中small-scope例新增15组对抗快照断言，不冒称增加15个顶层case。

## 八项修复与证据

| Review | 实际修复 | 实测 ID / 证据 |
|---|---|---|
| 1 授权串用 | `QueryConsentSession` 与 `QueryConsentSnapshot` 绑定actual/textHash/bindingHash/role/query或trial用途/space/trialID/scopeHash/currentconfig。任何两处文本编辑、clear、recount、space/filter/config或trial切换撤两套同意。UI handler重新计数与核scope；统一search要求typed快照，不接受无快照bool回退；workflow在创建grant前再次核对，trial service移除旧bool入口。 | CLOSEOUT `consent-bidirectional` / `consent-purpose-config`；BASIS small-scope内15组错误text/hash/binding/role/purpose/space/config/trialscope，真实普通库grant计数不变、注入calls不变；实际KnowledgeView UI双输入/clear，`R2_CLOSEOUT_UI injected=3 initial=3 query_grants=0 trial_attempts=0 requests=0`。 |
| 2 来源阅读截止 | `KnowledgeOperationSession` 每次打开/翻页/读图/节点选择创建新120s deadline与epoch，离页统一失效；adapter close也取消其在途token。旧页面令牌过期不影响下一用户操作。 | CLOSEOUT `fresh-operation`：注入clock推进120001ms，旧token拒绝，新token真实PDFKit渲染通过，不睡2分钟；离页后新op拒绝。 |
| 3 来源释放 | `PdfSourceSession`由assembly持有adapter和close promise，释放失败不移除旧对象、不准新adapter覆盖；background/离页取消后等待在途完成，句柄与pixel释放确认后再释放lease。普通库新增`r2s_source_release`和`KB-PDF-SOURCE-1`增量登记，显式retry，旧进程receipt只在session明确ClosedPreviousProcess后退役。 | CLOSEOUT `source-release-receipt` / `source-release-reopen` / `source-late-close`：注入真实ReleaseRead故障，lease1/receipt1保留；新repository对象读回后retry→lease0；在途render与close并发，迟到render拒绝，最后Released。生产最终leases/source_pending/vector_pending均0。不是拿vector释放测试代替source。 |
| 4 查询总截止 | `knowledgeWithin`共享整个10s剩余budget，所有candidates/visible/get/semantic结果await后核deadline，最后hit/hash/release也检查。已及时核验keyword可降级保留；结果在历史保存前采纳并emit，迟到history不重新提交/覆盖新结果，固定historyID+持有inflight promise，显式retry等待同一次写入，失败后才按原ID幂等重试。timer在finally清除，不取消下一query。 | CLOSEOUT `late-vector-fallback` / `late-final-visibility` / `late-history-once`（注入clock边界，真实普通库history最终只一次保存）；EMBED新增`query-final-hit-deadline` / `query-final-release-deadline`，注入transport+真实ArkData，拒绝迟到结果且lease0；host deadline test核旧timer不污染新query。 |
| 5 诊断纯审查 | `productionReview`只检查当前精确模型与已接受基线，再dryReview；删除preparePinnedModel/saveConfiguration/acceptBaseline隐式调用。日志vectors取实际已核metadata计数。明确配置/接受按钮保留独立操作。 | `closeout-pre-dry-protection` / `closeout-post-dry-protection`：前后state/detection公开行完全相等，rev2/credRev1/Configured/Passed/current1/basisAccepted，dry343/eligible343/requests0/vectors343，同生产readbackSHA；独立脚本断言相等。 |
| 6 来源结构与高亮 | 稳定ID多node选择；12节点分页、12cells分页，行列/rowspan/colspan，选中单元格原文按1024单元分页，公式raw按段展示，不全渲2万node或大表；图片仍通过现有snapshot/image lease读取。 | CLOSEOUT `source-render-regions`及现LOCAL mapping-crop-rotation；实际UI公式选择、26cells两页和单元格详情。非零crop+90°+双region独立gold截图与PNG像素断言通过；只合成原件，不升级用户PDF Unknown映射。 |
| 7 列表分页 | `PdfKnowledgeRepository.listPage` SQL LIMIT/OFFSET，每页最多20，UI每页12；`PdfVectorRepository.jobsPage` SQL限定一页，UI最多12任务/稳定ID，翻页撤query/trial/corpus同意和旧review。原343计数审查12条分页不变。 | CLOSEOUT `document-task-pages`真实26文档分12/12页无交集，拒绝10000页；`task-pages`真实25任务和完整输入集，12/12页无交集，拒绝无界limit。UI只持页数组，未调用全量document/task list再切片。 |
| 8 持久能力审计 | 独立S3普通库`shuvi_capability_audit_v1.db`，layout1事务建表/严格DDL核验，不drop既有布局。实际`getBundleInfoForSelf(DEFAULT)`读取name/versionCode/versionName；仅API/OS/ABI非unique环境，连同impl/suite/state/time/SHA持久。`CapabilityAuditGate`本进程必须执行自检；磁盘Available只审计，不授予能力，identity变化记录Invalidated，FAIL/Releasing fail-closed。 | CLOSEOUT `audit-identity-reopen` / `audit-env-invalidated` / `audit-fail-closed`：实际审计重开、new gate即使磁盘Available仍执行检查、同gate不重复，新gate重验；注入检查失败与释放不确定两次require皆拒绝，disk状态Failed/Releasing。生产Vector真实Checking→Available、Archive真实Checking→Available均落盘，disk_grants0。 |

授权UI两条路径的“无请求”指未创建query grant/attempt、注入transport调用未增加；普通本机keyword路径允许写隔离库新历史，不写生产历史。trial按钮在失效后disabled；不能把disabled按钮点击算handler执行，handler绕过/错绑定由同一个typed session与workflow真实普通库对抗测试验证。无凭据的fixture transport最多只允许初始化3个corpus结构向量，任何query调用都作为失败，绝不联网。

查询10s限制是结果采纳和剩余预算；不能保证底层ArkData任意极端阻塞被硬杀。已经发出的本机history事务可能在截止后落盘，状态保pending供显式确认，不假装撤回事务；同ID保证不追加第二条历史。真实云失败、极端DB硬退出仍与已验本轮截止行为分开。

## 具体文件

新增核心：`application/QueryConsentSession.ets`、`KnowledgeOperationSession.ets`、`KnowledgeDeadline.ets`；`infra/PdfSourceSession.ets`、`KnowledgeCapabilityAudit.ets`。

修改：`KnowledgeView.ets` / `PdfSourceView.ets` / `KnowledgePlatformDiagnostics.ets`、`KnowledgeSearchService.ets` / `EmbeddingService.ets` / `EmbeddingWorkflow.ets`、`KnowledgeAssembly.ets` / `PdfPageAdapter.ets` / `PdfKnowledgeRepository.ets` / `PdfVectorRepository.ets` / `KnowledgeCapabilityService.ets` / `VectorRdbRepository.ets`、`KnowledgePorts.ets` / `PdfKnowledgeModels.ets` / `EmbeddingModels.ets` / `KnowledgeSearchModels.ets` / `VectorWorkflowModels.ets`、`pages/Index.ets`。保留原有同文件未提交变更，没有无关格式重写。

新增隔离测试：`platformtests/CloseoutSuite.ets`、`CloseoutSourceFixture.ets`、`CloseoutQueryFixture.ets`、`ui/CloseoutQueryView.ets`；扩展`EmbeddingIntegrationSuite.ets` / `EmbeddingSmallScopeCase.ets`、host loader及`vector-quality-host-cases.cjs`。工具新增`closeout-source-ui.cjs`、`closeout-consent-ui.cjs`、`closeout-highlight-pixels.cjs`、`closeout-crash-anchor.cjs`、`closeout-evidence.cjs`，扩展定向UI及安全capture白名单。

新增API官方依据：bundleManager文档 `API参考/Ability_Kit_程序框架服务/ArkTS_API/通用能力的接口_推荐/ohos_bundle_bundleManager_应用程序包管理模块_/js-apis-bundlemanager`（getBundleInfoForSelf API9起、读自身DEFAULT，无新权限）；PDFKit `API参考/PDF_Kit_PDF服务/ArkTS_API/pdfService_PDF服务/pdf-arkts-pdfservice`（Stage、Core、API12起，create/save/crop/rotation）；deviceInfo sdkApiVersion/osFullName/abiList仅非唯一环境。目标SDK/API26不变，无新依赖/后端/权限。

## 最终存量

最终读取 `closeout-shipped-protection`，不是拿旧日志代新制品验证：

```text
doc=kb-60986788281e094aff01063dfcf764f1
content=kb-e144c7dff2b309d638cfa10b14604e3b
snapshot=kb-68c7504281b1a324817d2390b5c021e6
vectorJob=kb-a559722e0fceb2006b145f2ad9e6c656
space=kb-5f85a339550011dce2c68243d97e2b1f
expected=343 Verified=343 Unknown=0 remaining=0 eligible=343 active=1
stage=SemanticReady mirror=Synced dimension=1024
readbackSetSHA=7fd6351e6ef82270a9e0213928a6c8aa5f784454c4510e583e9a52392b69a1b3
leases=0 source_pending=0 vector_pending=0
```

- 原343关键词块、64/64图读回、assets65/ledger1350219/published1不变；原report SHA `6b57aaa8827b25325bf41c1a2f82fb4c81fb3a95f6c0af1ee4d92d06a55ac864`、snapshot SHA `7cc6022572ca890114c4e90e3096ddc5318eaceee755ba44ebcb5e83b847e281`、original SHA `7f959de85fdab10b15e2aada044d9f1fbd75dbc90b2fabfca79eb9ecb4b3df3a`、ZIP SHA `548162c5bb0f6a93d0fe76d4a5a17399f87b0a882c84d4510e7c2ead5fc12a05`一致。
- M1 SHA `f2fc7436d159ff91e162acf62a42e23d3bb3bdfa67d7709e473497ad62e8dd2b`、parse SHA `f9256feddd56314ea2fbe40e5807831461917bf5ae42ddb6ae5498f31a598308`；originals1/results1/history16/original_ok1/zip_ok1。生产KB history9/旧授权history1/当前引用5，未新增生产query历史。
- Configured/revision2/credentialRevision1/Passed-current1/AcceptedEngineeringBaseline；fingerprint SHA `6d7110c124b3b745de45c8bea8c5ff242c7003955a7fa295ff220729ce34b562`。providerRevision=NotReported、providerConsistency=UnverifiedRevisionAndHiddenProcessing仍保留，未重新probe或接受基线。
- Synthetic quality scope `a220261017240001`缓存24真实向量/16结果完全一致、requests0；hybrid Recall@5=1/MRR=1、改述补回8、否定4、无答案4近邻非空但不生成。原fixture/gold/阈值不改，历史24真实attempt回执不动。
- 最终生产账本：assets3080192/vector118894592/shared3022848/metadata29360594，total151335378 B < 524288000 B；质量scope ordinary757760/vector14794752/derived0，total15552512 B，二者保守合计166887890 B。含文件族/WAL/实际重开开销增长，不清资料降数，不称500MiB压力通过。隔离失败fixture保留为故障证据，不混入生产预算或用户索引。

## 制品与执行次数

目标重新枚举为唯一活动 Mate 90 Pro `127.0.0.1:5555`、API26 Release。正常`dev-run-mac.sh`内部复用缓存签名、build成功后`run --skip-build`，无uninstall/reset/force-sign。

最终signed HAP **3,903,205 B**，SHA256 `2109c77a4e700467bc0af0374e6b663daf481aed628632fbb902be6e9314e89a`；unsigned **3,843,185 B**，SHA256 `e8a66b5f64df75b8a275f0d7261e4e57dcc260a5b9935b0b6eeb2b375ee6f3ca`。模板SHA `36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`，gitdiff0。最终源码指纹（public-feature-host-only范围）`b8bae33609cf24784f381a99791496cca01016c080a30e14747187621c0ec453`；全工作区已有脏文件不归本轮单独所有。

本轮实际执行总数，不沿用前轮次数：

| 项目 | 实际次数与结论 |
|---|---|
| arkts_check | 7轮，23/9/12/3/29/1/1文件均clean；完整构建仍发现快检未报类型错误，失败后按约束直接build |
| build | 11次（直接3 + 正常缓存脚本8），8成功/3失败；最终脚本08成功 |
| install/run | 7次增量成功；脚本03 build失败未run；均不卸载 |
| host | 4轮各255/255，原252保留+3新增；最后closeout-host-shipped |
| counter | 2轮各32/32，原资源/算法不改 |
| CLOSEOUT | 6轮：5/15、15/15、15/16、16/16、16/16、16/16，最终16/16；另delivery-protection内1轮16/16，共7轮，失败历史保留 |
| EMBED | 4轮各28/28（原26+2），最后shipped-repair-basis-flow |
| BASIS | 4轮各33/33，含small-scope内15组新对抗断言 |
| NATIVE/LOCAL/VECTOR | 每组3轮，分别11/11、28/28、21/21全部PASS |

源码交付后未做provider调用；`closeout-evidence.cjs`核所有本轮closeout公开日志，任何Start都必须属于历史已知唯一attempt集合，实际 observed_known_lines=0/unexpected_requests0。`semantic-quality-evidence.cjs`只复算旧24请求回执，不发网络。任务结束无残留UI helper进程。

## 证据目录与复现

目录统一 `.cache/test-logs/2026-10-17-<scope>-9f5992c/`；各有host.log/meta.txt，公共总索引`.cache/test-logs/index.tsv`。设备日志由RUN_CMD中`capture-knowledge-platform.cjs`真实读取SHUVI_R2并白名单输出，默认广域日志刻意跳过，meta的log_exit=not-run不表示未做设备测试。

| Scope | 用途 |
|---|---|
| closeout-device-01 / device-02 / device-03-result / device-04-basis | 新suite失败、修复和实测历史；最后一个含16/16与33/33 |
| closeout-final-repair-workflow / final-native-local / final-vector-basis | 最后一轮业务源码全回归 |
| closeout-shipped-repair-basis-flow | 实际安装最终服务源CLOSEOUT16/BASIS33/EMBED28 |
| closeout-shipped-native-local-vector | 实际安装最终源NATIVE11/LOCAL28/VECTOR21 |
| closeout-host-shipped / closeout-counter-final | host255与counter32 |
| closeout-consent-ordinary-approved / consent-forward-complete | 实际普通计数授权→trial对抗编辑→普通提交→无grant/call |
| closeout-consent-trial-approved / consent-reverse-result / consent-clear-submit / consent-ui-final | 反向编辑/recount、空输入提交、无额外querygrant/call审计；超时的完整长链不算通过 |
| closeout-shipped-ui-trial-count / shipped-ui-reverse-edit / shipped-ui-reverse-assert | 最终制品实际trial授权→普通对抗编辑+recount→trial按钮disabled、grant0/attempt0/injected仍3，离开fixture释放 |
| closeout-final-source-ui / final-source-screen / final-highlight-pixels | 合成crop90度双区域截图+PNG像素检查，无用户PDF |
| closeout-final-cell-detail / final-cell-page-release | 真实node/cell详情、第二页和释放 |
| closeout-pre-dry-protection / post-dry-protection | 本机审查前后config/detection/向量集合不变 |
| closeout-archive-audit | 生产Archive与Vector当前进程Checking→Available，磁盘不授予 |
| closeout-shipped-protection | 最终343/64图/M1/parse/ZIP/cache24/全部release/账本 |
| closeout-artifact-shipped / closeout-deploy-08 | 最终制品与模板/安装成功 |
| closeout-handoff-evidence及后续收口证据 | 去重suite/零新增RPC/生产保护/最终制品SHA/合成像素断言；首版脚本重复采集case去重问题修复后PASS |

复现均为本机，不得执行任何真实网络入口：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" RUN_CMD='node entry/src/test/run-host-summary.cjs' /bin/bash scripts/capture-test-log.sh closeout-host-recheck
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 RUN_CMD='node entry/src/test/r017/capture-counter-tests.cjs' /bin/bash scripts/capture-test-log.sh closeout-counter-recheck
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 RUN_CMD='node scripts/embedding-authorized-ui.cjs closeoutSuite && node scripts/embedding-authorized-ui.cjs waitSummary 16/16 && node scripts/capture-knowledge-platform.cjs 127.0.0.1:5555 CLOSEOUT' /bin/bash scripts/capture-test-log.sh closeout-device-recheck 5m 127.0.0.1:5555
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 RUN_CMD='node scripts/closeout-highlight-pixels.cjs && node scripts/closeout-evidence.cjs && node scripts/semantic-quality-evidence.cjs' /bin/bash scripts/capture-test-log.sh closeout-evidence-recheck
```

设备suite要求已核定同一目标并在诊断页；源码改完checker→build，安装沿用正常缓存脚本，绝不force-sign或读取.local。合成屏幕只能在隔离fixture采集；禁止Key页全layout或截图。所有旧真实请求guard/journal不可删除/复用。

## 保留的失败

首build失败：`KnowledgeDeadline` Promise reject回调Error名义类型，修为Object后直接build通过。脚本deploy03隐藏原流并误归“疑似签名”，没有读取.local；普通build03公开诊断确认实际为CloseoutQueryView未初始化字段及枚举收窄，修后deploy04成功，不强签。

首CLOSEOUT 5/15：fixture把原件放到derived根触发UnregisteredDerivedBytes（正确安全拒绝），连带source失败；分页fixture缺pin、late-hit fixture sourceKind不符。修正隔离original根/pin/sourceKind后15/15。新增task-pages首轮15/16，fixture不完整输入集合被VectorInputSetIncomplete拒绝，补完整chunk/attempt/expected后16/16，未放宽生产校验。

UI脚本一次把成功click的空stdout误当失败，修为仅undefined失败；两次长链外层超时没有完整公共meta/host.log，不算通过，拆短链后分别留证。采到的crash anchor为既有EMPTY QueryPreparation/TextFailure栈，当前窗口仍存活、不是此次新崩溃，未据旧栈捏造修复。原始私有流不读；不捕获密码或用户内容。独立收口脚本首版把两次capture同run行算32而非16，改run+case去重且重复内容一致断言后PASS，不删case。

## 任务结案边界

R003现有EXT-2增量迁移/来源binding/checkpoint/typed多目标cleanup契约已在LOCAL/EMBED/VECTOR实跑，旧描述不再永久in_progress，本轮关闭。R004/R008/R011/R019/R020/R021及合成定位R013的上述实际缺陷已修复验收；R005有界typed整体返回不是本轮发现的违约，未为追求形式做大重写；R006只承诺已验JPEG/本样64图，未宣称所有格式。

任务表中completed均指已批准的当前实现及明确实测范围，非无限全矩阵。长期500MiB/max2000/每提交进程kill或真实掉电/所有释放故障/极端DB硬10s/其他ABI真机单列，不因此重新打开已完成代码缺陷。R007既有服务恢复/幂等/清理机制通过，但“同源不同ZIP新attempt UI与所有管理竞争组合”的独立屏幕验收尚未覆盖，保留具体未验，不混作本轮8项缺口。R025私有PDF内容/区域gold仍需用户另行指定gold与独立范围授权；已有cached人工质量不等私料质量。任何新真实embedding请求必须另获明确授权，本轮绝不发请求。

## 两项 Residual 与 R007 UI 结案

### 本轮结论

2026-10-17，用户定向review的两个residual均修复，R007指定正式UI验收完成。**provider models/probe/corpus/query/quality新增0、MinerU/LLM新增0**。只使用独立fixture普通/向量库、合成原件和两个受控ZIP，生产343、原report/ZIP/Key/Passed状态未改；没有新生产候选/报告确认或发布。HEAD仍`9f5992c`，未Git写入/卸载/reset/读.local或秘密。

### Residual 1：暂停后的 History Settlement

`KnowledgeSearchService.writeHistory`在真正写入开始即设置pending并通知listener，固定record与本次write promise配对。resolve回调只在该record/promise仍当前pending时清pending并emit；reject保pending并emit，不依赖query epoch，不修改result/message/historyId。`pause()`同步反映可恢复pending并通知；原write成功后自动解除下一query阻塞，失败后页面重入可见retry。显式retry先等同一promise，失败后才按同record/id幂等写入，不生成第二ID，不让旧write回调清理后来的pending或覆盖结果。

本次未新增通用持久队列；此问题的恢复范围是现有service/session持有的write在pause/background/页面重入之间可恢复，历史本身由正式仓储事务持久。没有声称尚未提交的history可跨进程凭内存恢复。

- Host新增2条：`Residual pause-during-history deferred resolve` / `... reject`，真正deferred promise，先等待写入entered再pause，记录原result/id，分别resolve/reject，核通知、pending、固定ID最终一条和下一query能继续。
- 真实Kit新增CLOSEOUT `history-pause-resolve` / `history-pause-reject`：`ResidualDeferredHistoryRepository`只拦第一次save，落盘仍调用正式`PdfKnowledgeRepository.saveHistory`；真实隔离普通库查询核一次ID，reject路径retry调用2次但落库1条，resolve只调用1次。重新订阅listener模拟页面重入，result/id保持，下一query可执行。
- 实际`KnowledgeView`：开始延后写入→离页pause→reject→重新进入，定向layout可见`r2-history-retry`，真实点击retry，审计`once=1 pending=0 saves=2 requests=0`。resolve路径离页后完成→重入，审计`once=1 pending=0 saves=1 requests=0`。测试不挂真实embedding/credential/transport。

### Residual 2：Reviewed 错误分类

`EmbeddingWorkflow.searchReviewed`加入与原`search`相同catch：调用共享`invalidateResponse`，模型/count/index/维度响应契约错及HTTP400/413/422使检测Failed、pause、进度ContractRejectedPaused；当前approval的approved/free撤销，向关键词降级，无重试、provider/model切换。下一次即使显式重设fixture同意，也在requireDetection拒绝，transport调用不增加；finally仍释放租约。

EMBED保留原28条并新增4条：`reviewed-model-rejected`、`reviewed-http400`、`reviewed-http413`、`reviewed-http422`。每条从正式`KnowledgeSearchService`的typed reviewed handler进入，注入transport一次返回错误，真实ArkData、输入proof/grant/lease；断言Keyword保留2hits、detectionFailed/ContractRejectedPaused/approval撤销/serviceconsent撤销、下一request拒绝/调用只+1/lease0。每条使用独立fixture detection对象，原workflow和生产真实Passed未改。

### R007 正式页面闭环

新增`ResidualIngestionFixture`只允许`KnowledgeStorageScope.isolated`。应用自身通过PDFKit创建合成原件，生成两个STORED ZIP（A/B，各3个规范协议JSON成员），CoreFileKit落入本轮独立cache root，hash/长度/CRC由现有`PdfArchiveAdapter.inspectForPlatformEvidence`实际校验、真实成员读取。复用正式`PdfProcessingAdapter` TaskPool normalize/seal/verify/chunks、`PdfAssetAdapter`、`PdfKnowledgeRepository`、`PdfIngestionService`、`KnowledgeDerivedLifecycle`，UI直接嵌入同一个`PdfIngestionView`。没有HDC文件transfer或云请求，也没有改用户source或造新生产ZIP。

解析侧metadata仅提供合成original/task/data/result绑定，不构造远端任务或网络端口；页面准备A/B会调用真实`service.prepare`。额外控制只在fixture：一次inspect故障、下次publish前deferred gate、删除此fixture索引、只读集合断言/文件hash审计。gate释放后依旧调用正式repository publish，不绕过epoch/tombstone/approval/expectedOld校验。

实际逐步点击与断言：

| ID / Scope（目录后缀统一`-9f5992c`） | 正式UI与真实断言 |
|---|---|
| `residual-r007-initial-review` / `initial-publish` | 准备A→AwaitingCoverageReview→当前报告checkbox确认→正式发布按钮→KeywordPublished，记A活动 |
| `residual-r007-retry-success` | B首读故障Failed后点正式刷新任务，再点`r2-job-<Bjob>`原ZIP重试→审查；未变A活动 |
| `residual-r007-rebuild-review` / `new-publish` | 真实点`r2-rebuild-<Bjob>`新attempt；B原候选jobs2→新attempt jobs3，A仍active，确认新报告后正式发布 |
| `residual-r007-switch-evidence` | B成为active、A为Retained，docs1/jobs3/active1/retained1/lease0；重复只读核对不创建任务 |
| `residual-r007-abandon-prepare` / `abandon-ui` | 对B正式新attempt→审查→点放弃→实际确认弹窗“确认放弃”→正式重试派生清理 |
| `residual-r007-abandon-retained` | 放弃job terminated、cleanup0、B活动不变；显式retire A后旧chunks0，原件+A/B ZIP三份文件hash保持 |
| `residual-r007-publish-delete-order` | 已发布后真实lifecycle.deleteDocument→active0/tombstone1，cleanup0/lease0/来源3不变 |
| `residual-r007-race-initial` / `race-blocked-publish` / `delete-publish-order` | 另一独立scope先A已发布，再B报告确认/正式publish暂停于提交前，UI删除同文档后释放gate，晚publish拒绝，不复活active，tombstone1/lease0/cleanup0/来源不变 |
| `residual-r007-resume-initial` / `resume-published` / `resume-once` | 最终制品A正式发布后点正式“恢复本机检查点”，仍原generation、jobs1/chunks1，无重复任务/块；`case=resumed`断言通过 |

`PdfIngestionView`只新增稳定ID与放弃后的可见状态/任务刷新，未加入云入口。任务列表在prepare/失败后原先需点已有“刷新任务”才能显示，此次确实验证了该按钮，不假称自动刷新。等待/点击脚本只允许fixture已知控件，放弃对话只在隔离页确认，未抓Key页或用户PDF。

R007要求的rebuild/resume/abandon/retry全部有实际UI点击，后端case不替代UI。两个ZIP不同hash/同source绑定，旧活动保留、候选切换、Retained cleanup、删除两序与恢复幂等均真实通过，现关闭R007。不是无限全故障/真实掉电验收。

### 本轮计数与最终制品

本轮与上方八项收口分开：checker **2轮**（10文件、2文件）全clean；build **3次全PASS**（直接build1+正常缓存脚本build2）；增量install/run **2次全PASS**，脚本内run使用`--skip-build`，未强签或查看缓存。host **2轮各257/257**（保留255+新增2），counter **1轮32/32**；fix **2轮18/18**（原16+2），workflow **2轮32/32**（原28+4）；native **11/11**、local **28/28**、vector **21/21**、basis **33/33**各最终一轮全PASS。R007多个逐步UI动作分别落盘，不虚构为一个后端suite通过数。

最终signed HAP **4,022,541 B**，SHA256 `d2877ab60b07169f18f0b43451b496506e4e77814790a576f8412835a4bfdaf2`；unsigned **3,962,586 B**，SHA256 `fbbcc72462cbc274a4b12746e265af1b792f3e2fab8693a4e234e96bb1df118e`。模板SHA仍`36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`，gitdiff0。最终源码指纹（public-feature-host-only范围）`64f120facb5327ca57b1eb6347a7b47d4f933099bef235a73877ecba53465722`，设备Mate90Pro/API26重新核定。

最终`residual-final-protection`核生产：343/343/Unknown0/remaining0/eligible343/active1/SemanticReady/Synced/1024，同readback集合SHA `7fd6351e6ef82270a9e0213928a6c8aa5f784454c4510e583e9a52392b69a1b3`。343keyword/64图全读回/assets65/ledger1350219/lease0，原snapshot/report/original/ZIP hash与上轮完整值一致。M1摘要`f2fc7436…dd2b`、parse摘要`f9256fed…a8308`不变，M1history16/KBhistory9/旧授权history1/currentcitations5，production无新增history。Configured/rev2/credRev1/Passed-current/basisAccepted不变，未把fixture Failed写生产。source_pending0/vector_pending0。

质量scope缓存24向量/16结果完全一致、requests0，Recall1/MRR1/补回8/否定4/无答案4不生成保持；fixture/gold不改。生产账本最终assets3080192/vector27922432/shared3026944/metadata29368900，total**60371524 B**；质量scopeordinary757760/vector14811136/derived0，total**15568896 B**。文件族实际读数可随SDK日志/checkpoint变化，不把下降解释为手动清理，未清生产数据；两者分别记录，非容量压力结论。

### 本轮文件与证据

业务修复：`application/KnowledgeSearchService.ets`、`EmbeddingWorkflow.ets`。正式UI：`ui/PdfIngestionView.ets`稳定ID/abandon状态，`KnowledgePlatformDiagnostics.ets`隔离入口。新增测试/fixture：`platformtests/ResidualHistoryFixture.ets`、`ResidualIngestionFixture.ets`、`ui/ResidualHistoryView.ets`、`ResidualIngestionView.ets`，扩展`CloseoutSuite.ets`、`EmbeddingIntegrationSuite.ets`和`entry/src/test/vector-quality-host-cases.cjs`。工具：`scripts/residual-ui.cjs`、`residual-evidence.cjs`，扩展定向UI及capture白名单；文档增量按本节列证，不改父plan/旧logs。

最终目录统一`.cache/test-logs/2026-10-17-<scope>-9f5992c/`：

- `residual-host-final` / `residual-counter-final`：257/32。
- `residual-final-fix-workflow`：fix18/EMBED32及新增6case逐项日志。
- `residual-final-native-local-vector-basis`：11/28/21/33。
- `residual-history-ui-reject-start` / `reject-retry` / `resolve`：实际页面离开重入/pending显示/显式retry/固定ID一次。
- 上表`residual-r007-*`：正式入库组件全部验收动作与不变来源/集合断言。
- `residual-deploy-02` / `residual-artifact-final`：最终源build/install/制品hash/模板恢复。
- `residual-final-protection`：生产343/64图/M1/parse/原件ZIP/rev2/cache24/lease/账本。
- `residual-evidence-final`及后续收口：独立按run+case去重断言全部suite、原输入及旧24真实回执、R007 UI证据/制品/模板/本轮无新RPC。

复现只允许本机缓存/注入，不触发旧授权：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 RUN_CMD='node scripts/residual-evidence.cjs && node scripts/semantic-quality-evidence.cjs' /bin/bash scripts/capture-test-log.sh residual-evidence-recheck
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" RUN_CMD='node entry/src/test/run-host-summary.cjs' /bin/bash scripts/capture-test-log.sh residual-host-recheck
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 RUN_CMD='node scripts/embedding-authorized-ui.cjs closeoutSuite && node scripts/embedding-authorized-ui.cjs waitSummary 18/18 && node scripts/capture-knowledge-platform.cjs 127.0.0.1:5555 CLOSEOUT' /bin/bash scripts/capture-test-log.sh residual-fix-recheck 5m 127.0.0.1:5555
```

suite命令需已在诊断页且重新核定同设备。R007通过`residualIngestion`显式入口新建独立scope，A/B准备均无网络；不得把fixture动作改为生产source。每次actual test有capture公共日志/meta/总index；RUN_CMD内部白名单设备日志是真实Kit证据，默认广域log_exit=not-run仍刻意保护隐私。

保留失败：本轮无build/test断言失败。R007长链helper两次外层超时、一次currentJob屏外取不到、一次wait状态标签屏外超时；无完整公共meta的超时不算通过证据，不读取私有临时流。修helper只在目标控件屏外时滚动，正式点击拆成短链后通过。B的FixtureReadFailure是明确注入负例并由正式任务按钮重试成功，不是原件损坏或provider失败。旧有八项收口失败历史仍在上文，不覆盖。

当前R001–R024/R026按明确实现范围已完成，R025私有PDF内容/区域gold仍in_progress，需另定独立gold与范围，缓存人工质量不替代。长期真机/500MiB/max2000/每提交kill掉电/所有资源故障组合/极端DB硬10s另列，不能据此把本次两个residual或已验R007再称未实现。全部provider授权已耗尽，后续真实请求仍必须新授权，本轮不向用户索取Key或授权。
