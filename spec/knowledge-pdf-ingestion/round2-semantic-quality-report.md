# ROUND2 独立真实语义质量报告

> 后续本机收口（2026-10-17）：见 [交付收口报告](round2-closeout-report.md)。本报告的首次24真实请求与指标为原始历史证据，不更改；后续修复轮只读取缓存、请求0，质量24/16结果一致。当前制品/账本/任务状态以收口报告为准，不重跑本报告真实授权。

## 结论与范围

2026-10-17：**冻结人工题集检索质量 PASS**。本轮用户独立确认免费及最多 8 次 document + 16 次 query 外发；实际恰好 24 次，全部 HTTP 200、1024 维、无重试。没有 models/probe、Pro、其他 provider/model、chat/LLM 或 MinerU 请求。完成后停止全部 provider 操作。

这不是私有 PDF 的内容质量验收、模型回答正确性验收、线上模型 revision 一致性证明或真机验收。R025 的私料 gold/原页区域 gold 及长期压力余项仍未完成。以下为首次真实结果，不存在修改输入/gold/阈值后重发得到的第二组结果。

## 冻结输入与隔离

- 原语料：[round2-semantic-manual-v1.md](../../entry/src/test/fixtures/round2-semantic-manual-v1.md)，SHA256 `de11199f48c05676167b84a1d0a05a005373a6fab2b3e71e969acf76835e2201`。
- 原 gold：[round2-semantic-gold-v1.json](../../entry/src/test/eval/round2-semantic-gold-v1.json)，SHA256 `32daf3262db161944ec2f9da02ac1db683c8c46e75b092bd22b83ec95aa86b09`。原文件不改；构建资源副本逐字节相等，由 host 和应用 SHA 校验。
- Document 只取 `## F01` 至 `## F08` 各节正文，去掉段落边界空行；不发送标题、FID、文件说明或 gold/answer。Query 只取原 JSON 的 16 个 `question`，正式 `prepareTextQuery` 核对 actualInput 完全一致，无改写。
- 当前 SiliconFlow / 精确 `BAAI/bge-m3` / revision 2 / credentialRevision 1；恢复既有 Passed-current 检测，不重新 probe。应用内部沿用 `EmbeddingCredentialStore.fetch`，host 不接触 Key。
- R017 固定资源、计数算法及已接受工程基线不变：profile `BGE-M3-MS-a46a138-fast-scalar-v1`，revision `a46a13810c9d7f876fccd8d7017512ebc265d2c1`；proof.verified 始终 false，providerRevision=NotReported，providerConsistency=UnverifiedRevisionAndHiddenProcessing。
- 全部 final input 的 hash/binding/bound 在请求前持久，集合 SHA256 `b57c3a51dfc4ebe9d46d02a7840dd5cc3b8d8367876af45e0f2ff4b7c5a8ee60`；每条明细见首次请求证据 `quality-provider-receipt`。
- 唯一 run `a220261017240001`；普通库 `shuvi_r2_a220261017240001.db`，向量库 `shuvi_r2_vector_a220261017240001.db`，空间 descriptor 独立保存于 `quality_run.wire`。生产库/空间均不作为候选。8 个规则各自独立 source/chunk；16 个 query 缓存 eligible=false，不能成为 corpus 候选。
- 独占 `quality_run` 主键在任何请求前提交；24 条 `quality_input`、用途分开的两个 grant、每条 InFlight/ReadbackVerified 及 receipt/result 留存。已有 run 再启动不可恢复发送，不删 guard/journal；失败保 UnknownOrFailed/FailedNoRetry，本轮未触发真实失败。
- Host 点击前独占 `.cache/r025-quality-a220261017240001-one-attempt.guard`，固定 cap 8/16。请求计数器拒绝重复 ID、额外 ID、文档不全先 query 和超过 24 次；后台或离开诊断页取消后续请求。没有生命周期自动运行入口。
- 所有质量输入、真实向量和结果只保留在该测试 scope，未导入 M1、未写用户 query history、未改生产 active 指针。保留本轮数据便于离线复算，不清理用户资料。

## 真实执行

| 项目 | Document | Query |
|---|---:|---:|
| 获准 / 实际次数 | 8 / 8 | 16 / 16 |
| 独立 grant | `kb-d2c91227ef314a51297bc8122616de91` | `kb-8926adfca19592831d79a93bb1b724d6` |
| HTTP 200 / Failed | 8 / 0 | 16 / 0 |
| 实际维度 | 全部 1024 | 全部 1024 |
| Reported total / prompt | 222 / 222 | 238 / 238 |
| 每条 request→readback 段耗时 | 178–454 ms | 168–315 ms |

应用整轮 elapsed=5798 ms，小于 15 分钟窗口；reported total/prompt 合计均 460，不用 usage 代替发前上界证明。真实协议保持单字符串、encoding_format=float，无新增 text_type/instruction/truncate。正式 transport 每次重计数/核 grant 后通过应用安全凭据发出；模型/count/index/dimension/Float32 finite/nonzero、写后逐值及全部 row 身份读回校验通过。8 条 document 完整后关闭/重开向量库，全体 hash 再核后才发 query。

首请求公开日志 SHA256 `931d2636af1cf4a67d9d847a790d99cd46fcf66d054b3ff5fc7262a2ad46936a`。独立 `scripts/semantic-quality-evidence.cjs` 从该固定公开日志核原始输入 hash、24 个唯一 case/ordinal/receipt、24 个唯一 request attempt 的 Start/HTTP200，确认 document8/query16/models0/probe0/failed0；复算原 gold，不使用检索结果制造期望。另检查6份后续缓存/重启/回归/最终保护公开日志，没有未知的新request attempt（重复采到旧行不重算请求）。独占 actual receipt 为 `.cache/r025-quality-a220261017240001-actual-receipt.json`，与旧全文请求回执分离。

## 三路结果

Keyword 复用正式 `prepareTextQuery` / `textKeywordScore`，不是另造弱关键词路线。现正式策略按空白分隔的完整字面短语检索；本题集中 16 个中文自然语言问题均无字面整句匹配，所以 keyword top5 全为空。Vector 复用真实 ArkData filteredKnn：只允许同一质量空间的 8 个权威 target，SQL 前过滤 identity/eligible/hash，再精确 cosine 排序；每题返回 8 条，报告 top5。Hybrid 复用正式 `knowledgeFuse`（RRF60/top5），本次 keyword 空，因此 hybrid 顺序与 vector 相同。

| 12 条答案题指标 | Keyword | Vector | Hybrid | 冻结 Hybrid 门槛 |
|---|---:|---:|---:|---:|
| Recall@5 | 0/12 = 0.00 | 12/12 = 1.00 | 12/12 = 1.00 | ≥ 0.80 |
| MRR@5（未召回记 0） | 0.00 | 1.00 | 1.00 | ≥ 0.60 |

8 条改述均是 keyword 未召回、vector top5 补回，超过至少 2 条的要求。4 条否定/范围题 gold 都排第 1；相反来源不会因靠近而计作正确证据。这里只验证检索证据，不证明模型理解或生成答案。

| Case | Gold | Keyword top5 | Vector top5 = Hybrid top5 | Gold rank V/H | Gold cosine distance |
|---|---|---|---|---|---:|
| P01 | F01 | 空 | F01,F02,F07,F05,F06 | 1 / 1 | 0.2841784314 |
| P02 | F02 | 空 | F02,F01,F07,F05,F06 | 1 / 1 | 0.2856363399 |
| P03 | F03 | 空 | F03,F04,F08,F05,F02 | 1 / 1 | 0.1631958971 |
| P04 | F04 | 空 | F04,F03,F08,F05,F02 | 1 / 1 | 0.2681258859 |
| P05 | F05 | 空 | F05,F01,F07,F02,F03 | 1 / 1 | 0.1974271183 |
| P06 | F06 | 空 | F06,F07,F05,F02,F01 | 1 / 1 | 0.3671780764 |
| P07 | F07 | 空 | F07,F01,F02,F05,F06 | 1 / 1 | 0.1851087919 |
| P08 | F08 | 空 | F08,F03,F04,F05,F02 | 1 / 1 | 0.2293290359 |
| N01 | F01 | 空 | F01,F02,F07,F06,F05 | 1 / 1 | 0.2791701555 |
| N02 | F03 | 空 | F03,F08,F04,F05,F02 | 1 / 1 | 0.4284836054 |
| N03 | F07 | 空 | F07,F01,F06,F02,F05 | 1 / 1 | 0.3390092047 |
| N04 | F05 | 空 | F05,F01,F07,F03,F02 | 1 / 1 | 0.2116095894 |

P03 仅验 F03 被召回，来源正文含借期 21 天与续借 14 天；没有调用模型生成，也未把“35 天”的算术当作回答正确性测试。N01 的 forbidden F02 仍出现在第 2 位，仅 F01 计为 gold；不声称相反来源已被剔除。N02 的期刊限制、N03 同一 F07 的蓝/绿线路与目的地范围、N04 每人每日一场仅由冻结原规则人工核对，不把其他近邻算正确。

## 无答案行为

| Case | Keyword top5 | Vector top5 = Hybrid top5 | 最近 cosine distance | 判定 |
|---|---|---|---:|---|
| A01 | 空 | F02,F05,F07,F01,F08 | 0.5286868146 | 无馆长电话证据 |
| A02 | 空 | F02,F01,F03,F05,F08 | 0.4389709234 | 无空调温度证据 |
| A03 | 空 | F08,F04,F05,F06,F03 | 0.4227493497 | F08 未说明手机 App 挂失渠道 |
| A04 | 空 | F07,F05,F01,F02,F04 | 0.3513202087 | F07 未说明节假日发车间隔 |

四题都返回非空近邻，gold 来源均为空，支持答案证据不足；answer_generated=0。距离不是置信度/可回答性阈值，尤其 A04 的最近距离小于部分可答题，不能用“有 hit”或固定距离门限自动作确定答案。当前为证据检索，不存在经本轮验证的自动拒答生成器。

## 重开与存量保护

真实 24 向量及逐题结果持久后，多次关闭/重开核验，并执行一次真实 `aa force-stop` / `aa start` 新进程复算；最终制品再读亦 PASS，均 requests=0。逐行核固定输入 hash/text/role/binding/bound、space/doc/content/vector generation/epoch/eligible/1024维/readback SHA，三路重新计算结果与已存 wire 完全相同。不通过重发 query 恢复结果。

生产审计最终保持：expected343/Verified343/Unknown0/remaining0/eligible343/active1/SemanticReady/Synced/1024维；读回集合 SHA256 `7fd6351e6ef82270a9e0213928a6c8aa5f784454c4510e583e9a52392b69a1b3` 不变。生产 doc `kb-60986788281e094aff01063dfcf764f1`、content `kb-e144c7dff2b309d638cfa10b14604e3b`、snapshot `kb-68c7504281b1a324817d2390b5c021e6`、vector job `kb-a559722e0fceb2006b145f2ad9e6c656`、space `kb-5f85a339550011dce2c68243d97e2b1f` 均不变。

- M1 SHA `f2fc7436d159ff91e162acf62a42e23d3bb3bdfa67d7709e473497ad62e8dd2b`；parse SHA `f9256feddd56314ea2fbe40e5807831461917bf5ae42ddb6ae5498f31a598308`。originals1/results1/M1 history16，original_ok1/zip_ok1。
- KB history9、既有授权全文 history1/当前引用5；质量轮次未新增用户历史。生产旧 corpus grant inputs340、与前三块 overlap0，不重发旧 corpus/query。
- 原 report SHA `6b57aaa8827b25325bf41c1a2f82fb4c81fb3a95f6c0af1ee4d92d06a55ac864`；snapshot SHA `7cc6022572ca890114c4e90e3096ddc5318eaceee755ba44ebcb5e83b847e281`；ZIP SHA `548162c5bb0f6a93d0fe76d4a5a17399f87b0a882c84d4510e7c2ead5fc12a05` 不变。
- 原343块关键词、64/64图片全读回；assets65、ledger1350219 B、leases0，published1。
- Configured / Passed-current1 / revision2 / credentialRevision1；fingerprint SHA `6d7110c124b3b745de45c8bea8c5ff242c7003955a7fa295ff220729ce34b562`。重启后 models0 为内存列表未重拉，不表示重新验证列表或模型消失。
- 最终生产账本：assets3080192/vector75337728/shared2994176/metadata29321316，total107739236 B < 524288000 B，按 assets+vector+max(shared,metadata) 口径。文件族/WAL/保留物理开销随实跑增长，未清理或伪造旧读数。
- 独立质量 scope 最终 ordinary757760/vector14737408/derived0，total15495168 B；与生产账本分别记录，保守合计123234404 B。不是 500 MiB 压力或全部空间容量验收。

## 构建与回归

本轮 3 次 checker（4 文件、1 文件、4 文件）均 clean；实际 build3 次均 PASS（直接 build1、正常缓存签名脚本内 build2），正常增量部署2次均 PASS，无卸载/force-sign/reset。首次制品用于唯一真实请求；最终修改只加强本机缓存核验与只读生产审计，未更改冻结题集/计数/评分/请求结果，也未重发。

Host 共3次各252/252，新增1例覆盖资源逐字节/原SHA/解析/8+16上限和重复/越界/次序拒绝/16题评分/相反来源；保留原251例。独立 counter 共3次各32/32。模拟器首次和最终制品 native11/11、local28/28、vector21/21、basis33/33、workflow26/26 各通过两轮。basis/workflow 的注入传输测试不算真实 provider 请求或语义质量证据。

最终 signed HAP：3,669,868 B，SHA256 `1a0c3e642c23929accf841bb24d9471e07450cb34cebb4d98f98294db0f5edb5`；unsigned：3,608,169 B，SHA256 `4ba7db39be45484eb0a44c81d2a9639859e9a52c6f628f4b832c7983f6ec152c`。模板 SHA256 `36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`，`git diff --exit-code -- build-profile.json5` 为0。HEAD `9f5992c`，保留工作区已有未提交更改，未做 Git 写操作。

## 证据与复现

以下目录统一位于 `.cache/test-logs/2026-10-17-<scope>-9f5992c/`，各含 host.log/meta.txt，总索引为 `.cache/test-logs/index.tsv`；设备证据由 RUN_CMD 内固定 `SHUVI_R2` 白名单 helper 实采，`log_exit=not-run` 表示跳过默认广域日志，不是没有设备操作。真实阶段指纹 `6b273d13c825a87bd7a436c082156f80d224b77da4dd416da54ce462478103e4`；最终源码指纹 `902741c8ea9cb2fcae2b9cdd6b8563a4b4fc952599b4589505e04beab95bf153`，以各 meta 的 public-feature-host-only 范围为准。

| Scope | 证据 |
|---|---|
| quality-contract-receipt | 设备24输入本机计数/基线/用途/free门禁，无网络 |
| quality-protection-pre-receipt | 请求前 M1/parse/原件ZIP/343块/64图 |
| quality-authorized-submit | 唯一显式 consent/free/run 点击，host guard |
| quality-provider-receipt | 首次真实24输入/请求/receipt/16题top5与距离/metrics |
| quality-request-evidence-final | 独立请求数/原输入hash/gold指标复算 |
| quality-request-closeout | 最后复算及6份后续公开日志无新增request attempt核对 |
| quality-cache-reopen | 初次缓存关闭重开，无网络 |
| quality-process-restart / quality-process-reopen | 真新进程24向量/16结果复算，无网络 |
| quality-deploy-final / quality-artifact-evidence | 最终成功build/run/制品hash/模板恢复 |
| quality-host-delivery / quality-counter-delivery | 最终252/252与32/32 |
| quality-delivery-native-local | 最终11/11、28/28 |
| quality-delivery-vector-basis-flow | 最终21/21、33/33、26/26 |
| quality-delivery-protection | 最终质量缓存/生产343/hash/镜像/64图/M1/配置/账本 |

纯本机复算，不触发 provider：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 RUN_CMD='node scripts/semantic-quality-evidence.cjs' /bin/bash scripts/capture-test-log.sh quality-evidence-recheck
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 RUN_CMD='node scripts/embedding-authorized-ui.cjs qualityReadback && node scripts/embedding-authorized-ui.cjs waitSummary QualityPASS && node scripts/capture-knowledge-platform.cjs 127.0.0.1:5555' /bin/bash scripts/capture-test-log.sh quality-cache-recheck 5m 127.0.0.1:5555
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" RUN_CMD='node entry/src/test/run-host-summary.cjs' /bin/bash scripts/capture-test-log.sh quality-host-recheck
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 RUN_CMD='devecocli build --product default' /bin/bash scripts/capture-test-log.sh quality-build-recheck
```

质量缓存命令要求已在显式诊断页，先重新枚举核定设备；只检查目标非秘密控件，不采设置页全 layout。真实提交历史命令为 `qualityConsent && qualityFree && qualityRun`，**不可重新执行**，授权已用完，guard/journal 不得删除或改名绕过。构建正常部署沿用 `scripts/dev-run-mac.sh --device 127.0.0.1:5555 --emulator 'Mate 90 Pro' --no-emulator --product default`，脚本内部复用缓存，不查看 `.local`。

失败与证据限制均保留：第一次 diagnostics 定向 helper 因可见阈值530而实际按钮起点528超时，修到528后继续，未点请求；`quality-contract-device` 首采早于异步结束（RC2/无有效行），随后 `quality-contract-receipt` 才是 PASS；最终保护审计等待曾因屏外 status bounds0 超时，已完成的 AuditPassed 不算失败业务，修为只读状态允许屏外、点击仍需可见，`quality-protection-final-receipt` 与 delivery证据通过。该超时 capture 被外层终止，没有生成完整公共日志/metadata，故不计为通过证据；不读取其私有临时输出。首次 request-evidence 输出字段带 tokens 被保守过滤，改用 usage 字段后重新纯本机审计落盘，未削弱全局隐私过滤。无真实 provider 失败或重试历史被覆盖。

## 尚未验收

私有真实 PDF 区域/内容 gold 与改述质量、真实回答/自动拒答生成、真500 MiB/max2000块压力、每提交 kill/真实掉电、全部系统资源释放故障、极端DB10秒硬退出及其他ABI/真机均仍未验。8条人工规则的小语料很容易召回，且正式字面关键词基线在本题集为0；不能把 1.00 指标推广为私料、长文档或复杂生产数据的泛化质量。R025/R026 保留部分完成，不整批勾选长期任务。
