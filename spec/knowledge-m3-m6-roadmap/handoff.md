# M3–M6 新对话与 Agent 交接

> 状态：待确认；版本：v0.2；日期：2026-10-18。
> 配套规格、44 项 TODO、样本/预算与验收矩阵见 [路线与规格](roadmap.md)。本次授权仅完善文档，不实施、不测试、不外发。

## 1. 先读与先确认

1. 读 [工程约定](../../docs/01-协作与工程约定.md)、[平台基线](../../docs/02-平台基线.md)、[知识库总规格](../../specs/02-个人知识库问答.md) 与本目录路线。
2. 读 M2 [OCR 修复](../knowledge-pdf-ingestion/ocr-profile-fix-implementation.md)、[部署记录](../knowledge-pdf-ingestion/ocr-profile-fix-studio-deployment.md)、[收口记录](../knowledge-pdf-ingestion/round2-closeout-report.md)。M2 按用户多次 PDF 入库/检索可用反馈作已完成基线；旧报告保持原时点，不重新打开 M2。
3. 明确本轮只推进哪个 M。优先 M3：最小公共接缝与 JPG/PNG OCR。M4 DOCX、M5 PPTX、M6 XLSX 不一起自动开工。
4. 另获准后只读核对实际 HEAD/未提交差异与允许范围；已有 OCR 修复不回滚、不混为自己新增成果。不要为调查现状读取秘密/私有日志。
5. 将新 M 的需求、设计、任务按当轮 SDD 门禁审阅；本路线不是这些门禁已通过的证据。获准后才创建对应目录/更新 feature 指针，不覆盖 M2 文件。

建议未来目录：`spec/knowledge-m3-image-ingestion/`、`spec/knowledge-m4-docx-ingestion/`、`spec/knowledge-m5-pptx-ingestion/`、`spec/knowledge-m6-xlsx-ingestion/`。本轮尚未创建这些执行目录。

## 2. 关键源码接缝

项目根：`/Users/zane/DevecostudioProjects/Shuvi-agent`。以下路径均相对项目根；先读再设计，文件名不是平台能力保证。

| 接缝 | 文件 |
|---|---|
| 原件/格式/预算 | `entry/src/main/ets/knowledge/domain/DocumentParseModels.ets` |
| MIME/后缀/主包身份与保真复制 | `entry/src/main/ets/knowledge/pipeline/DocumentParsePolicy.ets`、`entry/src/main/ets/knowledge/infra/DocumentFileOperations.ets`、`entry/src/main/ets/knowledge/infra/DocumentFileAdapter.ets` |
| 服务参数/传输 | `entry/src/main/ets/knowledge/pipeline/MineruProtocolCodec.ets`、`entry/src/main/ets/knowledge/infra/MineruTransportAdapter.ets`、`entry/src/main/ets/knowledge/application/DocumentParseService.ets` |
| Text/Pdf 二分与 locator | `entry/src/main/ets/knowledge/domain/KnowledgeSearchModels.ets`、`entry/src/main/ets/knowledge/domain/KnowledgePorts.ets` |
| Direct/Similar 与历史资格 | `entry/src/main/ets/knowledge/pipeline/KnowledgeMatchPolicy.ets`、`entry/src/main/ets/knowledge/application/KnowledgeSearchService.ets` |
| 来源/会话/数据保护 | `entry/src/main/ets/knowledge/infra/KnowledgeAssembly.ets`、`entry/src/main/ets/knowledge/infra/PdfSourceSession.ets`、`entry/src/main/ets/knowledge/infra/KnowledgeStoreHost.ets`、`entry/src/main/ets/knowledge/domain/KnowledgeStorageScope.ets` |
| UI/生命周期 | `entry/src/main/ets/pages/Index.ets`、`entry/src/main/ets/entryability/EntryAbility.ets`、`entry/src/main/ets/knowledge/ui/KnowledgeResultCard.ets`、`entry/src/main/ets/knowledge/ui/KnowledgeView.ets`、`entry/src/main/ets/knowledge/ui/PdfSourceView.ets` |
| 配置与备份 | `entry/src/main/module.json5`、`entry/src/main/resources/base/profile/main_pages.json`、`entry/src/main/resources/base/profile/backup_config.json` |

不得只扩 `DocumentParseFormat` 就声称入库支持。PDF normalizer/locator/worker profile 仍是 PDF 专用；旧 PDF/TEXT wire、hash、页证据与活动向量保持。独立 PNG/JPG、DOCX/PPTX/XLSX 的实际产物/schema 目前没有充分证据。

## 3. M3 的第一个工作包

**M3-01～03：需求/合同与证据准备，不先写 parser。**

- 明确本轮实施与操作授权，核旧数据兼容清单和当前改动所有权。
- 登记五格式已知/未知，优先暴露 XLSX 原生 sheet/cell/缓存风险；Office 未决只留对应 M，不让真实 Office 取证阻塞图片。
- 冻结图片最低来源：原图/hash/version、尺寸/方向、OCR 段落。区域未知时可无框核原图，不造像素定位。
- 审阅新来源/历史版本、资格分派与资产所有权，不对旧 PDF wire 加默认字段改变摘要。
- 明确图片输入/产物官方合同；获批后以保守保护线取得基础/复杂非敏感样本，不猜供应商 schema。

M3-A 退出不是“五格式全部证明完成”：只需图片必需公共接缝/兼容有依据，Office 风险有明确后续任务。G6 正式 UI/制品/恢复证据属于结案，不是开始所有本机实现前的循环门槛。

## 4. 操作授权清单

| 操作 | 本次是否已授权 | 未来要求 |
|---|---|---|
| 规划文档编辑、相关只读复核 | 是 | 不扩到无关文件/秘密 |
| 应用代码、配置、测试 fixture 修改 | 否 | 当轮范围与需求/设计/任务门禁明确批准 |
| 命令、host、checker/build、安装/设备/UI 测试 | 否 | 另确认操作范围/设备；测试落盘、保数据 |
| MinerU 新文件解析 | 否，旧额度授权已用完 | 每件许可/非敏感/完整内容/免费资格/参数/次数批准 |
| 模型列表、固定 probe、文档文本/问题嵌入 | 否 | 分用途、实际输入/范围和次数独立批准；不混 chat |
| 新依赖/权限/服务/SDK/Native | 否 | 官方依据、方案及额外审阅 |
| commit/push/合并/打 tag/清库/卸载/强签 | 否 | 不自动执行；数据与秘密保护始终有效 |

在未来实施或任务审阅阶段先确定验证范围和外发许可，交给验证代理执行有限用例；验证代理不得自行扩样本、请求次数或用途。无授权不发，也不把“只差授权”当作尚未实现编排的解释。

Key 已由用户在应用配置并实际使用过，不能再把“从未有 Key”当 M2 阻塞。当前只读安全状态，不读明文、不代填/截图，不重复索取。免费资格和当前可用性仍逐用途核实。

## 5. 工具链与安全执行背景

以下为历史部署记录，不是本轮命令执行或当前实时检测：

- 最近成功工具为 Studio CLI `1.3.5`、Node `24.14.1`；Agent 默认代理 CLI/Node 曾不同，不直接混用。
- 历史 Studio CLI 路径为 `/Applications/DevEco-Studio.app/Contents/tools/node/bin/devecocli`。未来先核实际版本和工程上下文，不自动升级。
- 仅部署子进程清代理/Agent 认证来源变量曾解决登录误报；不改系统代理，不重复调用 `auth status` 当纯本地探针，不读取认证材料。
- 沿正常 `scripts/dev-run-mac.sh` 缓存签名/模板字节恢复路径，不强签/卸载；设备运行前核唯一映射，不盲用历史 serial。
- `.ets` 每轮改完 checker 紧接 build；失败修后直接重 build。构建成功才安装。实际测试使用工程 capture 落盘，不将认证/签名原始流送公共日志。

这些背景不构成本轮命令或设备操作许可。

## 6. 不得触碰或冒称

- 不清理 M1/M2 原件、ZIP、快照、向量、历史、任务/凭据，不切空库或 HDC 写入绕过正式流程。
- 不改冻结的 PDF gold 来迎合检索；新格式另建许可样本与独立 gold。
- 不读取/修改/执行既有无关 `scripts/paste-to-emulator.sh`、`spec/knowledge-emulator-e2e/`。
- 不将支持上传扩展名、HTTP 成功、收到 ZIP、host、构建、安装、模拟器机制或用户人工反馈互相替代。
- 不执行宏、公式、外链/嵌入对象；不把派生 PDF、文本相似、caption 或缓存值冒原生来源/计算正确。
- 不覆盖 `.local`、签名/证书、私有配置或原始日志，不将其带入上下文/截图/Git。

## 7. 可复制的 M3 启动说明

> 当前材料只批准规划文档，不授权实施。先确认用户本轮是否另行授权 M3 的需求/设计/任务流程、代码和本机验证；未获准停在审阅。获准后只推进 M3：最小公共来源/历史/资产接缝与 JPG/PNG OCR 文字入库、原图核对、Direct 高亮/明确 Similar、恢复与删除。Office 在 M3 只登记风险，真实样包/原生锚点未决只阻塞对应 M4/M5/M6。保留 M1/M2 现有数据、wire/hash/向量和未提交 OCR 修复；不重做 M2、不增视觉服务/生成回答/同步、不自动改 feature 指针或 Git。逐格式真实样包不得编 schema，每件文件/文本/问题外发须新独立许可和次数上限；Key 仅用户在应用输入。按获批验证范围分层留证，不以构建安装当完整验收。只报告 M3，其他 M 保持 pending。

## 8. 每 M 交付报告

列明任务 ID 实际状态、变更文件/契约/权限/依赖/存储影响、样本与 profile/gold/hash 身份、实际请求量、正常/异常/拒绝/服务失败及恢复/清理结果。

host、构建、平台、服务、正式 UI、内容/来源质量、真机/容量分别给准确日志路径、复现方式及未覆盖项。未执行不写通过，build-only 不自动补做 UI，也不关闭完整格式验收。

后续工作仅在其明确授权范围内继续。规划获审阅、文档 TODO 或本段命令式表述均不产生新的操作许可。

## 9. 计划路径提示

会话计划 `.deveco/plans/1791964278587-curious-meadow.md` 目前是 M3–M6 草稿，过去 M2 报告曾引用同路径。不要据当前文件重写 M2 批准史，不凭摘要恢复旧全文；保留历史报告，用本目录隔离本次路线与后续执行档案。
