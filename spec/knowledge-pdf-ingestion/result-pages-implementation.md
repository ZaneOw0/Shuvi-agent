# 原页标注与片段高亮实施报告

日期：2026-10-17。状态：**COMPLETED（仅批准实施范围 T001–T009）**。T010–T011 留给独立 spec-verify，未勾选。本阶段 checker/build/deploy/UI/设备/provider 请求全部 0；不宣称增量已构建、安装或页面闭环已验收。

## T001 保护基线

有效单 entry/API26 工程，product=default、module=entry，不 scaffold、不新增权限或依赖。已有未提交变更全部保留，不执行 Git 写操作。

以下为父任务及 ROUND2 报告的历史基线，不是本阶段实际数据库读回：

| 对象 | 冻结身份 |
|---|---|
| 原件 | 30 页，SHA256 `7f959de85fdab10b15e2aada044d9f1fbd75dbc90b2fabfca79eb9ecb4b3df3a` |
| ZIP | `548162c5bb0f6a93d0fe76d4a5a17399f87b0a882c84d4510e7c2ead5fc12a05` |
| 文档 | `kb-60986788281e094aff01063dfcf764f1` |
| content | `kb-e144c7dff2b309d638cfa10b14604e3b` |
| snapshot | `kb-68c7504281b1a324817d2390b5c021e6` / `7cc6022572ca890114c4e90e3096ddc5318eaceee755ba44ebcb5e83b847e281` |
| report | `6b57aaa8827b25325bf41c1a2f82fb4c81fb3a95f6c0af1ee4d92d06a55ac864` |
| vector generation | `kb-9e20e7c45dff0f7ba8eede3e9f8db9a7` |
| space | `kb-5f85a339550011dce2c68243d97e2b1f`，1024 维，343 active/Synced |
| readback set | `7fd6351e6ef82270a9e0213928a6c8aa5f784454c4510e583e9a52392b69a1b3` |
| 存量 | 343 keyword / 64 images / M1 history16 / KB history9；全部原件、ZIP、快照、旧身份和历史保留 |

不改变规范化内容、chunk ID、embedding text/inputHash、snapshot/reportHash、vector/space/vgen。只新增页身份及结果展示侧表。旧 region 证据不升级。所有旧请求授权已用完，旧 guard/journal 不删改，不重发 MinerU/文档 embedding/查询，不读取 Key、`.local`、签名或私有 raw。

## 分阶段进度

- Setup：T001 完成。
- Foundational：T002 完成。新增 strict ResultMatch/ResultPageReference/PAGE-IDENTITY-1 与 `KB-PDF-RESULT-1` 事务侧表；EXT-2/M1/解析 v3 原布局不重置。
- US1：T003/T004 完成。先写漂移/冲突/多节点/partial 用例，再逐页读取原件及指定 ZIP，用同 normalizer 还原来源，提供受审清单、显式登记和独立页集合解析。未在生产执行登记。
- US2：T005/T006 完成。纯 ASCII-fold/ranges/Unicode 安全、双源正文 direct 端口、Text+Span 共用卡片、版本化展示历史侧表与旧历史兼容。旧 M1 search/candidates/wire 不改行为。
- US3：T007 完成。direct 优先零模型调用；双源完整零命中且 typed current query approval/free 才调用既有 searchReviewed；partial/read failure/stale source 禁发，相似仅合法同空间 vector、无 literal/ranges。
- Polish：T008/T009 完成。保留原257例、counter/golden，加21例，最终 host278/counter32；安全/范围/文档收尾。
- Verification：范围外，保持未勾选。

## 验证边界

允许已授权原件/ZIP 的有界只读对照和 host 注入测试。host 不是 ArkTS 编译、ArkData/PDFKit、UI、设备或真实语义验收。SC-007–SC-010 的页面与真实相似场景本轮未执行，不改旧未验结论。

## 原页实际证据与身份

- 实际读取指定原件30页图像；指定 ZIP 70成员全部有界解压、70CRC、总展开11,926,995 B；没有扫描其他 PDF，没有读 `.local` 或设备库。
- 原页1–29逐页特异内容及结构对应、明确的292个受审文字节点（287普通完整节点＋5跨页合并节点）见 `pdf-page-alignment.md`。完整 node ID/集合SHA/UTF-16 fragmentSHA 随包 `pdf-page-review-v1.json`，SHA256 `d99055bb5e8005a73d2c085870cc4f5a405ef8ee59768d3354e8844e72faee39`；UI 显式本机导入前固定核该摘要。
- 16 cross_page spans 对应5个合并节点：node-6(1/2)、97(8/9)、178(15/16)、202(17/18)、278(23/24)。原件断句逐片核对，范围有hash；5 lines_deleted空node-11/100/181/205/281不补证。页眉、页码、无文字图像不因页锚点转绿。原物理页30无parsedblock，明确不绑定，不自动称空白页。
- **实际复算同adapter规范化完整节点集合SHA = 冻结snapshot SHA `7cc6022572ca890114c4e90e3096ddc5318eaceee755ba44ebcb5e83b847e281`**，不是同count/geometry证明。用原 `PdfStructureChunker` 还原343块，292节点受审范围覆盖343/343，其中5块跨页。服务用原sourceStart/sourceEnd裁剪证据，跨页节点的单页子块不会多标一页；读取所有chunkSources，不取首locator代整块。
- 本轮无生产数据库读取，343 active/Synced及readbackSetSHA仍仅引用上轮基线。没有修改normalizer/chunker/snapshot封存/EmbeddingWorkflow/PdfVectorRepository/VectorRdbRepository及原件/ZIP/冻结V1；本轮新增SQL仅元数据侧表，不UPDATE内容/输入/向量。导入时仍要在应用实际snapshot/hash/nodeSet上逐项核验，任何身份漂移拒绝。
- 页身份与region模型分离；没有 geometry/transform 授权升级，没有原PDF区域叠加正确性声明。Unknown/Partial/Conflict明标；旧世代/删除/缺原件不授予来源跳转。来源打开重新resolve，在独立原件hash+读租约后沿已核physical页跳转；不把provider候选页当原页。

## 查询与历史

`LITERAL-ASCII-FOLD-1` 只折叠A–Z，中文和其余Unicode原字面，terms沿用空白分隔任一匹配；半开UTF-16 ranges不拆代理对，重复/重叠合并，原hit.text不改。评分/筛选在top20前，不由retrievalText前缀或keyword通道推断direct。实时/历史卡片统一，match绑定result实际输入、terms、正文SHA，非当前输入框；旧历史仅从saved actualInput兼容重建并标识，不回写旧行。

保留10秒截止/最终visibility/固定history ID及pending重试。任一正文通道失败、扫描后来源失效不声明全库零命中且不外发；存在direct只direct。零direct未授权与语义失败分别提示；Similar只同空间vector证据且ranges空、最多5，不把距离当概率，不生成回答。原searchReviewed的配置/模型/response invalidation、预算、grant/journal与免费门禁未改。

## Host 实际结果

全部由既有安全capture执行，设备日志`not-run`；公共日志不含正文/秘密。

| scope（均`.cache/test-logs/2026-10-17-<scope>-9f5992c/`） | 实际结果 |
|---|---|
|result-pages-host-01|270/272，RC1；新增测试预期失败：两个空白terms各两次实际4ranges；5跨页节点原有7个分块，需按source范围投影|
|result-pages-host-focused-02|8/10，RC1；仅数值诊断确认上述2项；失败保留|
|result-pages-host-focused-03|10/10，RC0；修正确切range预期及sourceStart/End页集合，不删用例/改gold|
|result-pages-counter-01|32/32，RC0；旧固定counter/golden全保留，离线oracle；无网络|
|result-pages-sql-04|9/9，RC0；新增迁移重开、双端口前缀挤占、历史sidecar/旧记录兼容|
|result-pages-identity-05|10/10，RC0；完整normalize snapshot SHA一致、292/343/5证据|
|result-pages-host-06|277/277，RC0，72.691s|
|result-pages-host-final-07|277/277，RC0，72.799s；本轮词条统计|
|result-pages-host-final-08|**278/278，RC0，72.732s**；最终全部源码，新增失效direct禁止假zero外发|

最终源码capture指纹 `8915f8e135dfb152b60a293275c4a9572e9036c8eddf0ee2ae945d3ec1b6a308`，HEAD `9f5992c`，dirty114，Node v22.23.2，Bash3.2。随后仅文档/任务更新，不改源码。`git diff --check` RC0。未调用arkts_check/CLI check/build/run；host转译不是严格ArkTS检查。

复现：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" \
RUN_CMD='node entry/src/test/run-host-summary.cjs' \
/bin/bash scripts/capture-test-log.sh result-pages-host-new-scope

CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" \
RUN_CMD='node entry/src/test/r017/capture-counter-tests.cjs' \
/bin/bash scripts/capture-test-log.sh result-pages-counter-new-scope
```

每次使用新scope保留失败/指纹，不覆盖旧日志。手工`result-pages-offline.cjs review`只用于本次受权只读内容审查，不是测试通过证据，不应向公共日志输出逐页正文；自动host仅输出计数。

## 后续验收输入（本阶段零请求）

完整343片段离线字面统计：`过拟合`8、`ROC`25、`roc`25、`查准率 查全率`18。参考文献/aside默认过滤后仍有真实正文direct。不是正式UI运行或生产query结果，不能据此标SC-008已验。

冻结P03原句“把一份数据分成k份以后，每轮怎样训练和测试，一次k折交叉验证最终返回什么？”在同343片段范围literal=0（全句无空白，不改题）。可作为以后一次独立授权same-space query候选，**本轮build-only无UI/新RPC，不请求、不复用旧额度**。未评价真实相似召回、未跑16题完整评分，gold文件未改。

## 文件清单与验证交接

以下为本轮实际改动，不代表Git总diff中的全部既有用户变更。17个`.ets`：

```text
entry/src/main/ets/knowledge/domain/KnowledgeSearchModels.ets
entry/src/main/ets/knowledge/domain/PdfLocalModels.ets
entry/src/main/ets/knowledge/domain/KnowledgePorts.ets
entry/src/main/ets/knowledge/domain/TextKnowledgePorts.ets
entry/src/main/ets/knowledge/application/PdfPageReferenceService.ets (新增)
entry/src/main/ets/knowledge/application/KnowledgeSearchService.ets
entry/src/main/ets/knowledge/pipeline/KnowledgeMatchPolicy.ets (新增)
entry/src/main/ets/knowledge/pipeline/KnowledgeRetrievalPolicy.ets
entry/src/main/ets/knowledge/infra/PdfKnowledgeRepository.ets
entry/src/main/ets/knowledge/infra/TextRdbRepository.ets
entry/src/main/ets/knowledge/infra/KnowledgeAssembly.ets
entry/src/main/ets/knowledge/infra/PdfPageAdapter.ets
entry/src/main/ets/knowledge/ui/KnowledgeResultCard.ets (新增)
entry/src/main/ets/knowledge/ui/KnowledgeView.ets
entry/src/main/ets/knowledge/ui/PdfSourceView.ets
entry/src/main/ets/pages/Index.ets
entry/src/test/KnowledgeResultCases.ets (新增)
```

其它：新增`entry/src/main/resources/rawfile/pdf-page-review-v1.json`、`entry/src/test/knowledge-result-host-cases.cjs`、`entry/src/test/result-pages-offline.cjs`；修改`run-host-tests.cjs`、`run-host-summary.cjs`、`vector-quality-host-cases.cjs`、`knowledge-store-host-cases.cjs`。文档为本报告、pdf-page-alignment.md、context-memory.md、tasks.md、当前spec/plan状态行及`specs/02-个人知识库问答.md`增量。

必要偏离：额外修改Index/PdfPageAdapter/PdfSourceView三个既有接缝，以便来源重新核验并真实跳已核原页，不借region模型；新增一个hash/ID-only rawfile和两个host helper承载可导入受审数据/实际只读回归，不硬码UUID到通用算法。没有新依赖/权限。

下一次spec-verify精确目标：PROJECT_ROOT当前根，`default`/`entry`/debug，API26；先上述ets checker紧接build，首轮最多10次实际build含wrapper内部，失败后只直接build重试。成功后按T011重新枚举唯一已获准模拟器，正常cached signing/模板字节恢复及`run --skip-build`增量安装；无UI、无provider、无生产登记/query。模板SHA仍`36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`。本报告不替代`result-pages-verification.md`。

## 限定风险与未验

实施任务无失败阻塞项。真实ArkTS/ArkUI编译与部署尚未执行，交T010/T011；页身份生产登记、原件打开/Span像素/历史实际UI和真实P03相似均未执行，build-only不增加这些验收。首次页来源读取仍计10秒查询预算，超时明确待核并保留direct而不伪页；极端库/资源/真机压力和旧region/full16未验不改PASS。
