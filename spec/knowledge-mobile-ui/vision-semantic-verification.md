# 图片描述、标签与语义检索真实验收

日期：2026-10-22。分支 `dev/rag`，基线 `9ab89b4`，工作区改动未提交、未推送。状态：自制单图的真实视觉 → 描述/tag → 文本向量 → 本机召回 → 来源展示闭环通过；设备为 Mate 90 Pro API 26 模拟器 `127.0.0.1:5555`，未做真机验收。

## 问题结论

1. 原视觉作业实际返回 HTTP 401，服务未接受鉴权，因此没有生成描述/tag。用户在应用重新保存独立 DeepSeek Key 并重新启用自动处理后，新自制图真实请求完成。没有读取或输出 Key，不把历史 Unknown/401 当作新 Key 的测试结果。
2. 原「统一自动全量嵌入」关闭，不能生成统一空间的合格输入，通用 review 提示把关闭、空间和计数问题混在一起。用户在应用审阅范围、费用、工程基线后启用，真实正文作业完成 40/40，当前问题向量检索成功；并非本轮证据显示 tokenizer 失败。
3. 视觉/嵌入虽然有两条 lane，旧调度器仍等两者全部结束才处理新增任务。实测新图 AwaitingConfig 被另一份 232 段正文作业阻塞。改为独立运行器；回归证明阻塞正文请求未释放时新图视觉即可完成。
4. 后台切换还复现准入已持久化、launch 前抛 DispatchPaused，却因 InFlight 标记变成 Unknown。补充确定未调用 launch 的 NotSent 结算，保持真正未知网络请求不自动重发。旧长正文作业停在 120/232、Unknown/DispatchPaused，保留既有向量与账本，未自动重试或重写历史。此作业不代表自制图片链路失败，也不宣称已有资料全量向量化完成。

## 实际验收与请求范围

用户明确要求继续真实服务闭环，并在应用更新视觉 Key、确认启用统一自动嵌入；之前已同意恢复队列并接受现有设置范围内请求。队列因此可能处理用户现有待办语料；本轮人工仅新增/验收自制图片、两条非敏感问题，未批量重试既有用户图片。

样本 `shuvi-vision-e2e-20261022.jpg` 为前一轮自制白底三行英文图的新文件名，82,046 字节，SHA-256 `476f68003a5e30ec16bb02252f704cbc1bab3c7e192379134b5e05a40d8ed14f`。通过公开 Download → 系统选择器 → 正式图片导入保存；未直接写私有库、未注入标注、未调用 MinerU/OCR。

| 验收点 | 真实结果 |
|---|---|
| DeepSeek 视觉 | Vision Complete 1/1；一次 Received 尝试 |
| 描述/tag | 自动描述白底、三行黑色文字；标签「白底、黑色文字、英文、OCR验证、测试图片」落库 |
| SiliconFlow BAAI/bge-m3 | ImageEmbedding Complete 1/1；一次 Received 尝试；描述/tag 为实际文本输入 |
| 索引 | upd-image / Synced / expected=1，input_hash=readback_hash；未使用图像像素向量 |
| 标签召回 | 搜索「OCR验证」，正文组无直接命中，相关资料组显示自制图及「本机标签」原因；零问题向量 |
| 语义召回 | 搜索「用于检验文字识别的黑字白纸样例」，本机无直接匹配，明确确认后请求一个问题向量；自制图以「语义相关」位于第一项 |
| 来源 | 从语义结果打开原图，实际显示预览、生成描述和五个标签；此新样本未调用 OCR，OCR 字段为空 |
| 问题准入 | 共两次消耗的一次性 Query grant；第一条「白色背景的英文测试图片」在图片尚未向量化时验证已就绪正文空间，第二条完成图片语义验收；未运行额外模型探测 |

描述中英文标识的大写 I 被识别为小写 l，与先前 OCR 有类似差异。小样本证明链路可用，不证明所有图片的描述/标签语义质量或逐字准确性。自制新图保留在资料库中便于复查；用户原有资料、旧向量和历史未清除。

## 变更和分层验证

- UnifiedQueryService/UnifiedKnowledgeView：拆分可操作的 review 错误，保留所有授权/范围/计数校验；KnowledgeQuerySession 清理失败确认。
- VisionTransportAdapter/UnifiedProcessingQueue/VisionSettingsView：明确鉴权拒绝终态和提示，独立运行两队列，以及准入后未 launch 的 NotSent 回执。
- 统一 host 最终 **158/158**，网络替身请求与私有文件读取均为零。新增：各阻塞原因、过期确认清除、401 不自动重试、两 lane 独立、准入写入与 launch 之间切后台可恢复。host 不替代真实服务和原生向量证据。
- ArkTS 增量检查全部通过；中间一次异常重抛不符合 ArkTS 限定类型规则，改为 Error 类型收窄后通过，失败日志保留。
- 最终 signed HAP：7,830,481 字节，SHA-256 `78cf8029240b2089a63942811758b2c1a6f9fb0432f22136b73d4903df186c8f`；构建时工作区指纹 `a6eec6209c0364fb25553c7f2d9283034d81f91fd83596000290b65d232373fa`。后续仅补文档。
- 最终构建、安装、工作区指纹与模拟器日志：`.cache/test-logs/2026-10-22-knowledge-vision-semantic-delivery-build-9ab89b4/`。未升级 SDK/依赖、未新增权限或云服务；build-profile 模板退出时恢复。
- 实际联网闭环在独立队列修复版验收；最后 NotSent 修复用受控竞态回归、最终构建及保数据重开验证，不再次调用真实模型。

## 本地证据与复现

所有证据保存在 gitignore 的 `.cache/`，不将日志或私有内容纳入提交：

- `.cache/test-logs/2026-10-22-knowledge-vision-semantic-delivery-host-9ab89b4/`；`.cache/knowledge-mobile/semantic-delivery-host.log`。
- `.cache/test-logs/2026-10-22-knowledge-vision-semantic-check-9ab89b4/`、`knowledge-independent-lanes-check-9ab89b4/`、`knowledge-vision-semantic-final-check-fix-9ab89b4/`。
- `.cache/knowledge-mobile/e2e-self-annotation.txt`、`e2e-self-attempts.txt`、`e2e-tag-hit.txt`、`e2e-paraphrase-local.txt`、`e2e-paraphrase-review.txt`、`e2e-paraphrase-result.txt`、`e2e-image-source.txt`、`e2e-image-source.png`、`e2e-final-counts.txt`、`delivery-receipts.txt`、`delivery-receipts-final.txt`、`delivery-tag-hit.txt`（最终重开就绪后本机标签再次命中，视觉/图片嵌入仍各一次，Query 仍 2/2）。
- 最终模拟器日志落盘 `.cache/test-logs/2026-10-22-knowledge-vision-semantic-ui-final-9ab89b4/`。
- 队列 UI 限前 50 项且按 ID 排列，定位新任务困难。本轮额外用 `devecocli device sqlite3 ... -readonly`，严格 SELECT 自制样本标注、作业阶段/状态/计数、索引哈希相等布尔值及 Query 准入计数；未读取密钥/凭据配置，未修改私有数据库。

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='/Applications/DevEco-Studio.app/Contents/tools/node/bin/node entry/src/test/run-host-tests.cjs --unified-only' \
/bin/bash scripts/capture-test-log.sh knowledge-vision-semantic-host

RUN_CMD='/bin/bash scripts/dev-run-mac.sh --no-emulator --device 127.0.0.1:5555' \
/bin/bash scripts/capture-test-log.sh knowledge-vision-semantic-build 10m 127.0.0.1:5555
```

设备复现：在应用确认视觉/嵌入当前设置后导入新的非敏感图片，待视觉与 ImageEmbedding 完成，先用实际标签本机搜索，再以不含原文/tag 的改写问题明确确认语义搜索，并打开来源。真实重复调用可能产生费用；本记录不替代后续任意批量测试的授权。异常/拒绝/模型失败由受控回归覆盖，本轮未为验收故意制造真实鉴权失败或服务限流。
