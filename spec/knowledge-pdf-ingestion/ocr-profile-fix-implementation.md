# OCR profile / worker 最小修复实施记录

日期：2026-10-18。基线 HEAD：`a9092f0`。状态：T001–T006 实施完成；已实现待独立构建验证，非功能验收完成。

## 范围与基线

- 阶段1/2/3已获批准；本轮只源码、合成本机 host 与指定缓存离线包。checker/build/deploy/UI/设备/真实 TaskPool/ImageKit 均不执行，由下一阶段负责。
- 当前有效工程已存在，不 scaffold；保留父 agent 的 spec/plan/tasks 未提交修改及其他无关文件，不读取无关 paste/e2e、Key、.local、签名、private/raw。
- 新原件：33页 / 6181688 B / SHA256 `1ed80b011c6a0f98288d617dd776fafe3ec34d317c8875e9d157937568776794`；ZIP：6452636 B / SHA256 `ba0e9e429650a88730924f5827adeb13cd836d0427a21f7475b7fe810d716ebb`。
- 既有只读诊断：52 成员 / 52 CRC / 实际展开 8482133 B，v1/v2 342 项；`3.4.4 / hybrid / medium / boolean false` 在旧 normalizer 确定性抛 `ProtocolProfileUnrecognized / normalize`。不能由此声称三次设备异常均已取得底层错误，或已证明 rejected Error 丢原型。
- 33 个 `page_footer` 继续 Unsupported / NodeTypeUnsupported，覆盖审查不自动批准。
- 新 document `kb-fe1b5c77a1ac132bf804ee81058396a3`；现有失败 job：`kb-05926af5de215d75cd05425dd87f2ff3`、`kb-1c974c98c89e35904810a3463b3561a7`、`kb-4dd55b5a630d1479a70ec5a5a5db913f`。诊断时均无 snapshot/report/assets/chunks；本轮不读设备、不恢复、不新建第四候选，保留全部历史和 processingKey。
- 旧30页 ZIP SHA256 `548162c5bb0f6a93d0fe76d4a5a17399f87b0a882c84d4510e7c2ead5fc12a05`；冻结 snapshot SHA256 `7cc6022572ca890114c4e90e3096ddc5318eaceee755ba44ebcb5e83b847e281`，report SHA256 `6b57aaa8827b25325bf41c1a2f82fb4c81fb3a95f6c0af1ee4d92d06a55ac864`。343块/1024维向量的已发布身份不迁移、不重封存。未读取本轮设备，故不声称其当前实际状态已核对。
- MinerU/embedding/models/probe/corpus/query 请求授权仍为0；不读凭据、不网络、不清库、不设备写文件、不 Git 写操作。

## SDK 依据

通过 `devecocli docs search taskpool GenericsTask BusinessError --limit 5` 及 read 查阅：

- `开发指南/ArkTS_方舟编程语言/ArkTS并发/并发线程间通信/线程间通信对象/普通对象/normal-object`：普通类实例跨线程只传数据，不传原型/方法。
- `API参考/ArkTS_方舟编程语言/ArkTS_API/ohos_taskpool_启动任务池_/js-apis-taskpool`：API13 泛型 execute/GenericsTask、Promise、序列化错误及 BusinessError.code；不读取/拼接 message。

## 分阶段结果

| 阶段 | 任务 | 结果 |
| --- | --- | --- |
| Setup | T001 | 完成：固定批准范围、旧新身份、失败事实与推断边界 |
| Foundational | T002 | 完成：先补失败测试，再实现 PDF-WORKER-RESULT-1 / 白名单 / 有界载荷校验 |
| US1 | T003 | 完成：严格 true/false 两变体、未发布事务检查点实际 profile、旧 key 不变 |
| US2 | T004 | 完成：七入口信封、主线程校验/重建、TaskPool 自身 reject 去敏、失败记录与取消/释放语义 |
| Polish | T005/T006 | 完成：299 host / 32 counter、新旧包离线与安全审查、文档交接 |
| Verification | T007/T008 | 未执行/未勾选，归下一阶段；本报告不调用该阶段 |

## 实现与错误前后

1. 原条件只接受 `_ocr_enable.kind === true`。现保持 version=3.4.4/backend=hybrid/effort=medium 精确校验，只允许 JSON boolean true/false；缺失、null、字符串、数值及未知 profile 仍拒绝。true 标识和序列化不变；false 使用 `MINERU-HOSTED-PDF-3.4.4-OCR-FALSE-1`，没有改 ZIP 或请求参数。
2. 不给 PdfNormalizedDocument/PdfContentNode/Coverage 添加默认字段。实际 profile 在规范化成功后及恢复完整快照时赋到当前 job；checkpoint 原事务仍核 epoch/terminated/tombstone/cleanupClaim/Staging 或 Publishable 后更新已有 kb_local_job.profile，不写 processing_key、Published/Retained 或活动指针，不迁表。
3. 七入口 normalize/chunks/seal/verify/encode-node/hydrate-node/hydrate-header 返回具名信封。成功为 Uint8Array[] 分片，header/node 沿原有 BoundedDocumentJson/PdfSnapshotCodec，chunks 显式重建并核来源身份/范围/正文/资产/定位/预算；verify 只接受精确成功标记。主线程拒绝错误版本/操作/分支/缺字段/非字节载荷/超限/多余敏感字段。
4. worker 内同线程捕获 KnowledgeFailure 并只复制白名单 category/stage/可选安全整数 code；未知异常变 `WorkerOperationFailed / pdf-<operation>`，不读/传 message、stack、URL、正文或认证。TaskPool Promise reject 和同步调度失败也按操作去敏；取消/截止优先，active/finally、读租约和 releasing 保持。
5. 修复前设备只持久化通用“恢复失败”，host 精确拒绝为 `ProtocolProfileUnrecognized / normalize`。修复后同类合成拒绝经注入数据拷贝仍在主线程重建同一类别/阶段；失败记录保存该去敏消息，取消为 Paused，未知本机准备/恢复失败只显示 `LocalOperationFailed / prepare|resume`。这里不能推断旧三次设备错误的原始对象，也没有真实 TaskPool 本轮证据。

## 本机新包结果与旧包保护

- 指定新 ZIP 的大小/SHA 在读前及读后核对不变。原 SafeZipPolicy 检查 central/local、路径/冲突/顺序；Node zlib 有界展开逐成员核实际长度、compressed bytes 消耗、CRC 和 hash，52/52 CRC、展开8482133 B。未把成员写磁盘，未输出正文/完整 JSON。
- 当前原版严格 normalizer 已不再被合法 false 拒绝：342 主记录，包含派生图注共346节点，294 validated / 52 excluded；52为33 `NodeTypeUnsupported` 页脚及19 `EmptyText`。46资产引用，header/全部 node codec 与信封数据拷贝往返字节相同。未做 ImageKit 解码、资产落盘或真实覆盖审查。
- `page_footer` 仍是 Unsupported/NodeTypeUnsupported 的节点和覆盖 issue，33项均可计数；19空文本也如实保留。不存在“全文完整/无需人工审查/已发布”结论。
- 旧30页包原70 CRC、展开11926995 B、346主块/340 inline/46公式/7表248 cells/64资产/5空块及旧页证据用例全部保留。经新增 worker seal/verify 注入通路复算：snapshot SHA256 `7cc6022572ca890114c4e90e3096ddc5318eaceee755ba44ebcb5e83b847e281`、report SHA256 `6b57aaa8827b25325bf41c1a2f82fb4c81fb3a95f6c0af1ee4d92d06a55ac864`，均与冻结值精确相同，343块回归通过，未更新 golden/rawfile/Span/旧测试断言。
- 同一合成候选成功→再次恢复仍同 job/generation/processingKey/snapshot，只规范化一次、不发布；SQLite 注入测试核实际 profile 持久化及 Active/Retained/stale epoch 拒绝。注入内存库不是用户库，不等设备三候选已恢复。

## 测试证据

所有下表目录前缀为 `.cache/test-logs/2026-10-18-`，后缀为 `-a9092f0/`，均 `CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1`，设备日志 `not-run`。无 private/raw 读取、过滤器更改或绕过。

| scope | 结果/意义 |
| --- | --- |
| ocr-fix-worker-red-01 | RC1：测试先于合同模块，预期失败基线；无成功冒报 |
| ocr-fix-worker-policy-green-01 | RC0：纯合同6项通过 |
| ocr-fix-profile-red-01 | RC1：合法false仍被旧条件拒绝，预期失败基线 |
| ocr-fix-profile-green-01 | RC0：profile/事务/旧冻结来源8项通过 |
| ocr-fix-seven-worker-host-01 | RC0：七入口注入与纯合同12项通过 |
| ocr-fix-full-host-01 | RC0：完整296/296 |
| ocr-fix-counter-01 | RC0：原counter32/32；仅公开固定制品/离线 oracle |
| ocr-fix-final-boundaries-01 | RC0：冻结SHA/恢复幂等/新包10项 |
| ocr-fix-full-host-final-02 | RC0：完整298/298 |
| ocr-fix-host-closeout-03 | RC0：最终完整299/299，73.859146541秒，无skip/fail |

最终host指纹：`813430e646e0c456c59b85aeb90b8acf39588032938df3951f61b13fd4cbb10b`。counter指纹：`dde9a65421475b9878356252e61974c1b858b91cfc2692f5e732c858b535e959`；counter后改动仅本任务worker/host及文档，不改counter源码/制品/冻结值。最终host后仅文档收尾，证据指纹保留其真实时点。Node v22.23.2 / SDK转译器4.9.5 / Bash3.2；host转译不等 ArkTS 类型检查。

新增21个case：纯信封6、profile3、SQLite检查点1、worker注入10、新包离线1；原278不删除、不跳过。覆盖非法版本/操作/status/类型/缺失及双分支/超长/float/NaN/Infinity/越安全整数/额外原始消息、全部可达literal错误白名单、七入口非法成功payload及各调度reject、取消/timeout、失败持久化/释放、旧SHA及恢复幂等。

复现完整host（scope须为新的唯一名称）：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" RUN_CMD='node entry/src/test/run-host-summary.cjs' /bin/bash scripts/capture-test-log.sh ocr-fix-host-reproduce-new 1s
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" RUN_CMD='node entry/src/test/r017/capture-counter-tests.cjs' /bin/bash scripts/capture-test-log.sh ocr-fix-counter-reproduce-new 1s
```

## 需求与安全审查

| 要求 | 本轮证据/边界 |
| --- | --- |
| FR-042 | 两明确布尔分支＋缺失/非法/未知负例；新真实ZIP离线通过 |
| FR-043 | ZIP policy/CRC/hash/流结束/页数/顺序/bbox/JSON/表格/像素及预算实现均未放宽；原negative回归保留 |
| FR-044 | 旧snapshot/report精确SHA、343块/旧来源用例不变；false独立profile；未读写生产用户库/向量 |
| FR-045 | PDF-WORKER-RESULT-1与白名单/七入口运行时载荷校验；真实线程边界平台case仅准备未执行 |
| FR-046 | 主线程重建具体错误、持久化与同attempt恢复host通过；没有实际点击三候选或新建第四attempt |
| FR-047 | 新包33页脚明确排除，19空文本保留；真实Review/UI未验，不自动批准/发布 |
| FR-048 | 新provider请求0，Key读取0，checker/build/run/deploy/UI/设备动作0；依赖/权限/SDK/存量原件ZIP/冻结文件不改，无Git写 |

SC-011仅达到严格本机离线规范化/codec证据，设备Review未验；SC-012的离线旧包/negative回归已覆盖，生产存量状态本轮未读；SC-013的真实TaskPool边界未验；SC-014本轮零外发/不改生产身份，后续build-only同样不得恢复/发布。`git diff --check` 无错误。无未完成实施任务或阻塞项，不能因此宣称以上真实平台验收已完成。

## 精确文件清单

以下14个 `.ets` 为下一阶段静态检查输入（含新增/已有，绝对根为 `/Users/zane/DevecostudioProjects/Shuvi-agent/`）：

```text
entry/src/main/ets/knowledge/application/PdfIngestionService.ets
entry/src/main/ets/knowledge/domain/PdfKnowledgeModels.ets
entry/src/main/ets/knowledge/domain/PdfWorkerModels.ets
entry/src/main/ets/knowledge/infra/PdfAssetAdapter.ets
entry/src/main/ets/knowledge/infra/PdfKnowledgeRepository.ets
entry/src/main/ets/knowledge/infra/PdfLocalAudit.ets
entry/src/main/ets/knowledge/infra/PdfProcessingAdapter.ets
entry/src/main/ets/knowledge/infra/PdfSnapshotWorker.ets
entry/src/main/ets/knowledge/infra/PdfWorkerSupport.ets
entry/src/main/ets/knowledge/pipeline/MineruPdfNormalizer.ets
entry/src/main/ets/knowledge/pipeline/PdfWorkerPolicy.ets
entry/src/main/ets/knowledge/platformtests/PdfWorkerCases.ets
entry/src/test/PdfStructureCases.ets
entry/src/test/PdfWorkerCases.ets
```

其他改动：`entry/src/test/pdf-worker-host-cases.cjs`（新增，明确注入调度/crypto/文件拒绝替身）、`pdf-ocr-profile-host-cases.cjs`（新增，指定缓存包）、`knowledge-store-host-cases.cjs`、`run-host-tests.cjs`、`run-host-summary.cjs`；本目录当前spec/plan/tasks/context-memory/本报告，以及总spec `specs/02-个人知识库问答.md`。不修改旧result-pages/ROUND2/冻结gold/旧guard。

## 设计细化与交接

- 为满足严格no as/宽类型和原型无关要求，成功载荷选择已有codec的字节分片，并为chunk显式校验；没有通用应用错误框架或新依赖。安全定位元数据取最小集合（操作、类别、阶段、可选code），不提供任意字符串槽。
- `KnowledgeFailure` 只增可选数字code，旧两参message不变，不影响旧快照序列化；host runner在Foundational即接入，以便先红后绿，未等待Polish才补测试。
- 额外适配 `PdfLocalAudit.ets` 是已有verify worker直接调用方，改用同一adapter，避免返回合同变化后吞掉失败；没有执行该审计或放宽冻结report校验。平台 `PdfWorkerCases.ets` 仅新增可显式调用的真实normalize拒绝/未知/timeout case，未接自动生命周期、未执行真实suite。
- 父agent下一阶段只按T007/T008一次独立build-only验证。无需UI确认、不点击恢复、不运行准备平台case、不发布/向量化或任何provider。真实新包ImageKit/Review及SC-013需未来另获运行范围，本次不能因安装启动成功补成PASS。

实施子阶段最终状态：**COMPLETED**。功能总体：**已实现待构建验证**，真实平台/新包Review仍未验。
