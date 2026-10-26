# 离线语料 fixtures（冻结材料）

`entry/src/test/run-host-tests.cjs` 及其 `*-host-cases.cjs` 需要的两份外部材料，**随仓库提交**，
不再依赖某台机器 `.cache/` 下的私有副本。

| 入口 | 说明 |
|---|---|
| `entry/src/test/corpus-fixtures.cjs` | 唯一读取入口：`requireCorpus(id)`，校验 `status/bytes/sha256` |
| `entry/src/test/fixtures/corpus/manifest.json` | 清单与固定哈希；`status: committed` 之后才可用 |
| `scripts/import-corpus-fixtures.cjs` | 唯一写入方：扫描 → 脱敏 → 入库 → 更新哈希（支持 `--only`） |
| `scripts/verify-corpus-zip.cjs` | 候选 ZIP 自检：只输出成员数/解压字节/CRC/必需成员，不打印成员名与正文 |

## 为什么入库

`.cache/` 被 gitignore，CI 拿不到：此前材料放在 `.cache/m2-input/`、`.cache/m2-result-analysis/`、
`.cache/new-pdf-ingestion-diagnosis/`，导致 6 个用例在 CI 上必然 ENOENT（本机 runner 可复现），
门禁因此不可复现。入库后这些用例在任意机器与 CI 上行为一致，且哈希变化会显式失败。

## 脱敏要求（入库前必须完成）

1. **PDF**：清除 `/Author`、`/Creator`、`/Producer`、`/Title`、`/Subject`、`/Keywords` 与 XMP
   （`--scrub-pdf` 用 PyMuPDF 重写，保留页面内容）。
2. **ZIP**：成员名不得包含个人目录、主机名或租户标识；成员正文不得含邮箱、令牌、绝对用户路径、租户 ID。
3. 导入脚本只输出**命中类别计数**，不打印成员名与正文（与该组测试的既有约定一致）。

## 授权记录

| 材料 | 授权来源 | 确认人 / 日期 | 脱敏情况 |
|---|---|---|---|
| `m2-user-pdf`（原始 PDF，8,656,018 B，30 页） | RAG 线授权用于仓库与 CI，用户提供原件 | 2026-10-25 | 保留原始字节，仅有的元数据是 `Producer=pypdf`（软件标识，无个人信息）；因此 sha256 与原历史记录 `7f959de8…` 完全一致 |
| `m2-result-zip`（70 成员，8,461,084 B） | 同上，原件哈希与历史一致 | 2026-10-25 | 扫描无命中（无邮箱/用户路径/令牌/租户）；成员名仅为解析输出路径 |

> 若授权不允许随仓库分发，本节应改为「不入库」，并把该组用例改成**显式 skip 并计入 summary 的 skip 数**；
> 不得静默跳过（见 `docs/deployment/持续集成.md`）。

## 导入步骤

```powershell
# 1) 把材料放进收件箱（文件名可用 manifest 的 acceptNames 任一写法）
#    D:\ArkTSProjects\HarmonyPA\.local\corpus-inbox\
# 2) 仅扫描，不写仓库（可用 --only 只处理部分条目）
node scripts/import-corpus-fixtures.cjs --inbox .local/corpus-inbox --only m2-user-pdf,m2-result-zip
# 3) 脱敏 PDF 后再扫描
node scripts/import-corpus-fixtures.cjs --inbox .local/corpus-inbox --scrub-pdf
# 4) 确认无敏感命中后入库并固定哈希（会更新 manifest.json）
node scripts/import-corpus-fixtures.cjs --inbox .local/corpus-inbox --scrub-pdf --commit
```

更新材料时同样走本流程：新的哈希进入 manifest，旧哈希不再被接受，避免静默替换冻结证据。

## 已知边界

- 当前台账只有两份材料：原始 PDF + `m2-result-analysis.zip`；对应的 `pdf-offline`（3 例）、`knowledge-result`、`pdf-worker` 均使用它们。
- 2026-10-25 实测：托管 MinerU 3.4.4 即使传 `is_ocr:false`，返回的仍是 `profile=…-OBSERVED-1`、`_ocr_enable=true` 的内容（0 个 `page_footer`）。因此原先的“OCR 关闭 + 页脚排除”语料（`…-OCR-FALSE-1` 画像）**已不可再生**。
- 经决定：该用例（`pdf-ocr-profile-host-cases`）与其语料一并**删除**，没有用别的语料顶替，也不留 skip。覆盖缺口记在 `docs/deployment/持续集成.md`。
- 测试只允许读取受版本控制的路径；`spec/`（仅存在于 `dev/rag`）不得作为测试输入
  （原 `spec/knowledge-pdf-ingestion/round2-pdf-gold-candidate.json` 已移入 `entry/src/test/eval/`）。
