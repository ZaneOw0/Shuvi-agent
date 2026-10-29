# 知识库手机端修复验证记录

本文件记录先前手机 UI/解析验收阶段；后续图片描述/tag 与真实语义验收及最终产物见 [补充记录](vision-semantic-verification.md)。

日期：2026-10-22。基线：`dev/rag` / `9ab89b4`，本次改动未提交、未推送。状态：构建与模拟器正常闭环通过；真机及真实视觉/嵌入未验收。

## 修复与结论

1. **本机检索**：实际复现原范围错误的底层原因 `update failed`，空统一范围触发原生 SHA-256 空 DataBlob 更新失败。空输入改为直接 digest；空库搜索恢复正常无结果提示。新 TXT 导入后唯一短语 `星河档案验证20261022` 正文直接命中。
2. **上传入口**：知识库 → 我的资料 → ＋ 导入文件 → 文本/PDF/图片/DOCX。实际打开系统选择器，从 Download 选入四份新自制文件；未用私有库写入或假数据注入绕过正式入口。
3. **许可及 Promise 身份**：服务使用普通引用；准备期间不挂载资料子页。新 DOCX 许可实际保存成功，真实请求完成；新 PDF/JPG 不再出现 `Then: thisValue is not promise!`。
4. **手机端信息结构**：检索、文件列表、单份详情分开；原件与统一内容合成一张文件卡片，默认不展示 ZIP/hash/版本和清理按钮。解析/语义外发仍明确说明接收方与范围、保必要确认。图片来源默认只显示原图/OCR/有效描述标签，编辑表单按需展开。检索卡片不再显示代 ID 与向量距离。
5. **实测补充**：隐藏重复的原生对照正文，保留未支持对象/公式/图片占位；请求/入库失败不跳到上一份资料；进度使用可观察任务 DTO；搜索收起键盘、详情回到顶部、处理中可暂停。仅原图保存在本机时不冒 OCR 解析完成。

## 分层验证

| 层次 | 结果 | 证据 |
|---|---|---|
| ArkTS | 全部改动 ETS 检查无错误；按增量修改分别执行，既有工程警告保留 | `.cache/test-logs/2026-10-22-knowledge-mobile-check-9ab89b4-{2..10}/`；最终状态/回执 `.cache/knowledge-mobile/check-receipts.log` |
| 统一 host | **153/153**；合成/受控 SDK、SQLite 和网络替身，不作为平台实证 | `.cache/test-logs/2026-10-22-knowledge-mobile-delivery-host-9ab89b4/`；完整结果 `.cache/knowledge-mobile/host-delivery.log` |
| DOCX host | **75/75**，实际生产解析请求为零的受控回归 | `.cache/test-logs/2026-10-22-knowledge-mobile-docx-host-9ab89b4/`；`.cache/knowledge-mobile/docx-host.log` |
| 构建/安装 | 最终实际构建及保数据增量安装成功，复用既有签名；模板恢复无 diff | `.cache/test-logs/2026-10-22-knowledge-mobile-final-build-deploy-9ab89b4/` |
| 模拟器 | 唯一 Mate 90 Pro / `127.0.0.1:5555` / HarmonyOS API 26；四类新导入、文本本机入库、三种真实解析、检索/来源及自制资料归档通过 | `.cache/knowledge-mobile/` 下 UI 布局和截图；`.cache/test-logs/2026-10-22-knowledge-mobile-ui-9ab89b4/` |
| 真机 | 未执行 | 不以模拟器替代 |

最终 signed HAP：7,823,406 字节，SHA-256 `14e40fd0fced88ff02a1526e68a24ce7d4827448afe38d16d947487502e66d76`。最终构建留证工作区指纹 `3c2d5a027badaaf9c124d251838e9d4821cc6fc1058959bc0fe3fd8aba8df84c`；指纹包含当时未提交改动，后续只补验证文档。

首次 checker 有脚本生成字符串换行语法错误，修正后通过。初期 host 失败来自旧 UI selector 断言与新增 TextInputController 缺少 host 替身，已按新入口更新并补真实回归；保留失败日志，不把首次失败覆盖为成功。首次 UI 搜索仍失败后继续定位至原生摘要，未以 host PASS 提前结案。

## 真实解析样本及请求边界

用户在本会话明确允许 PDF、DOCX、JPG 各一份自制非敏感样本调用当前 MinerU，并确认三次免费资格；本轮没有读取密钥，也没有调用新服务。

| 文件 | 字节 | SHA-256 | 实际结果 |
|---|---:|---|---|
| `shuvi-mobile-check-20261022.pdf` | 1537 | `16587ff67ced3c05a3b2e6f62cda7e6aad55ccae6550e11f772ca69a635e1f7f` | 新导入 → 原件上传 → 解析结果 → 自动统一入库；累计查询 2 次、上传已确认、结果已接收 |
| `shuvi-mobile-check-20261022.docx` | 975 | `90947076e4c059e30e143c8e9965dc48774032fcaa2c70c20b0f34121d0fd9d1` | 同闭环；持久回执申请 1 / PUT 1 / query 2 / ZIP 1 |
| `shuvi-mobile-check-20261022.jpg` | 82046 | `476f68003a5e30ec16bb02252f704cbc1bab3c7e192379134b5e05a40d8ed14f` | 同闭环；持久回执申请 1 / PUT 1 / query 2 / ZIP 1；OCR Direct 命中、原图实际打开 |

PDF 为一页英文文本；DOCX 为三段英文、无媒体/复杂表格；JPG 为 1600×800 自制白底文字图。TXT 174 字节，仅本机解析。清单 `.cache/knowledge-mobile/synthetic-manifest.json`。

三件均仅点击一次正式解析确认，无新任务重提/补传。PDF 原合同没有单独持久化 POST/ZIP 数字，因此不根据默认 usage=0 编造申请次数回执；上述一轮操作有 UI 与上传/接收终态证据。没有为核验重新解析或再次下载。

检索 `Shuvi` 实际同时召回 DOCX、PDF 正文和 JPG OCR；DOCX 去重后的正文每段仅显示一份，图片来源有原图与 OCR，数据不平铺回列表。JPG 的 `Image` 中大写 I 被 OCR 为小写 l（`ShuvilmageCheck20261022`），这是本样本识别差异，不宣称 OCR 逐字无误或复杂格式全质量通过。

关键证据：`new-text-hit.txt`、`empty-search-fixed.txt`、`docx-parse-result.txt`、`pdf-result.txt`、`image-result.txt`、`final-query-three.txt`、`final-docx-source.txt`、`final-image-source.png`、`docx-receipt.txt`、`image-receipt.txt`、`pdf-receipt.txt`，均位于 `.cache/knowledge-mobile/`，不入 Git。

## 数据、增强队列与未覆盖范围

- 未迁移、删除或改写既有用户文件、旧 ZIP、旧向量或历史；没有卸载/清库/新增权限依赖/提交/push。
- 三份解析样本导入前发现原自动视觉设置已开启，因此在三份解析样本导入前暂停增强队列，避免样本触发视觉/嵌入。四份新自制验收资料随后通过正式 UI 归档，停止后续增强，保原件和结果可供本机审阅。证据 `final-test-archives.txt`。
- 恢复队列最初被自动审批拒绝（可能处理其他未明确列出的资料及产生费用）；用户随后明确同意按现有设置恢复。只读滚动核对完整队列仅有 6 个作业（2 个 Vision、4 个 BodyEmbedding），全部 `Canceled / OwnerRetired`、进度为 0，没有可发送作业。补充此证据后审批通过，已正常点击恢复；未更改模型、Key、自动处理设置或重试任何作业。证据 `queue-readonly*.txt`、`queue-resumed.txt`。
- 取消/费用变更/服务失败与错误读回等由受控 host 覆盖，本轮未进行真实服务失败/额度耗尽/系统权限拒绝的故障注入。
- 未验收真实 DeepSeek 视觉、真实语义向量查询、真机、批量容量、复杂 Office、扫描长 PDF 或所有图片编码；不将本次三个小样本外推为完整格式质量保证。

## 复现

使用 IDE 配套 Node `24.14.1`；本次 PATH Node 为 `22.23.2`，因此 host 命令显式指定 IDE Node。

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='/Applications/DevEco-Studio.app/Contents/tools/node/bin/node entry/src/test/run-host-tests.cjs --unified-only' \
/bin/bash scripts/capture-test-log.sh knowledge-mobile-host

CAPTURE_HOST_ONLY=1 RUN_CMD='devecocli build' \
/bin/bash scripts/capture-test-log.sh knowledge-mobile-build
```

设备复现：知识库 → 我的资料 → 导入新文件 → 从系统选择器选择 → 单份详情解析确认 → 完成后回到搜索；不复用本报告作为任意新文件或额外云请求的费用授权。
