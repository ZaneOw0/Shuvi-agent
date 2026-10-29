# 统一解析与图片知识实施交接

日期：2026-10-21。范围：批准 spec/plan v0.1、tasks T001–T045。状态：**COMPLETED（仅实施阶段，45/45）**；T046–T047未执行，由父代理唯一spec-verify处理。旧checkpoint/批准/失败记录保留，不能把此交接当产品已验收。

## 当前证据

- 最终限定host **150/150**，基础37＋US1 20＋US2 27＋US3 20＋US4 23＋生命周期/Polish23。
- 最终源码日志：`.cache/test-logs/2026-10-21-knowledge-unified-polish-host-c78d798-8/{host.log,meta.txt}`。源码时点指纹 `8c2563c62ba452c63cd5a37bc77f0cd001ef76ba4e2a55f7af8c3329bbc66b55`；之后仅文档/任务文字修改。
- 全feature60轮capture的准确失败/修复/计数/指纹在`implementation-report.md`各checkpoint及末尾表，不读隐藏raw、不解除filter。最终无失败case，无后台CLI/子worker遗留。
- 最终90 ETS唯一输入：`entry/src/test/unified-host-entry.cjs exports.changedEts`，完整顺序在实施报告末尾；46新增＋44既有接点，另15非ETS文件，共105。未列dirty/untracked既有M3/M4工作不是本feature新增成果。
- loader SHA `18772b30936eed3bb990343bc8e79aed1ef21701fb77b58169d06971fde8ea8b`；路径清单SHA `55109520e44896b6f3eff562f373e206515cf6f59642792e12822d96c442bb0c`；路径TAB文件SHA序列SHA `c89dff9edb669ad2e91fcc00bf778c620ffa587107d00978864c7709a8e6b99b`。每文件SHA按ordinal在最终host.log。
- 新生命周期suite SHA `141964039ecc56011041654b209f51204d7cf3e4a91c5187ad9c46bae405a089`；既有五suite和冻结fixture未改。
- 真实业务请求、Key/生产库/用户原件读取、生产迁移/升级均0。checker/build/deploy/device/UI/平台suite均未执行。

受控复现命令，只允许该入口：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='node entry/src/test/run-host-tests.cjs --unified-only' \
/bin/bash scripts/capture-test-log.sh knowledge-unified-polish-host
```

不能执行默认旧全量runner，也不能用`--unified-only`的PASS推导真实FS/RDB/XML/zlib/ImageKit/RCP/AssetStore/向量SQL或ArkUI运行成功。

## 正式入口与操作

以下是实现的用户操作路径，不是本轮已代用户执行。部署阶段禁止点业务按钮或启用费用设置。

| 功能 | 正式位置与稳定ID | 服务/状态 |
|---|---|---|
| 统一资料 | 知识库 → `upd-entry` | `openParsed`立即切页、`upd-status`显示加载/错误，`upd-retry-open`重试 |
| 四格式选择 | `upd-select-text/pdf/image/docx` | TXT/MD本机；其余由原parse owner准备，图片先原图可用 |
| 原解析许可 | `upd-parse-<id>` → `upd-confirm-parse` | 沿原MinerU完整文件/非敏感/免费资格，不由新视觉同意代授权 |
| 已收结果 | `upd-consume-<asset>` / `upd-rebuild-<asset>` | 已收ZIP公共消费；显式本机新代重建不重解析 |
| 视觉设置 | 统一资料 `upd-open-vision-settings` 或我的 `upd-profile-vision` | 独立DeepSeek alias，`upd-vision-key/save-key/cost/enable`；固定deepseek-flash |
| 自动嵌入 | 原嵌入设置 `upd-embedding-cost` / `upd-embedding-enable` | 当前服务/全部合格Body/OCR/ImageProxy、新空间/可能费用；需本机基线确认 |
| 图片详情 | `upd-open-image-knowledge` / `upd-image-detail-<occurrence>` | 原图/OCR/图注/Auto/用户修正分栏，全部同有效版本父来源 |
| 编辑标注 | `upd-image-description/tags/save/delete-annotation` | 用户overlay/tombstone，未变OCR不清、旧proxy资格即撤 |
| 暂停/恢复 | `upd-queue-pause/resume`、`upd-ingest-pause` | 设置级队列暂停持久；本机取消不宣云取消 |
| 恢复/清理 | `upd-processing-retry` / `upd-cleanup-retry` | 本机读回/补缺Import job/清理重试；不把Legacy转Import |
| 归档/删除 | `upd-archive-<doc>` / `upd-delete-<doc>` → `upd-delete-confirm` | tombstone/epoch/撤资格，释放仅该父refs，共享图/读/task保护 |
| 旧代退役 | 打开当前资料后 `upd-retire-<generation>` → `upd-retire-confirm` | 拒当前或被读/task持有的旧代，不暗留历史像素 |
| Unknown释放 | `upd-unknown-<job>` → `upd-unknown-release-confirm` | 仅已删owner明确放弃本机追踪；账本保留，非远端取消或免计费 |
| 本机迁移 | `upd-migration-entry` 或 `upd-open-migration` | 刷新`upd-migration-catalog`、选范围、`upd-migration-freeze/run/pause`；固定分母/逐项回执，0云 |
| 历史升级 | 同页独立 `upd-upgrade-freeze/cost/approve/pause/resume` | 固定已迁移范围及费用版本；未批不得发送，不能因开设置自动全集升级 |
| 本机检索 | 知识库 `upd-query-input/local` | 先正文/OCR Direct和本机tags，不等远程或corpus全局busy |
| 当前语义 | `upd-query-review/consent/cost/semantic` | 实际问题/统一空间/当前费用持久准入，一次Query Promise |
| 双组分页 | `upd-direct-more` / `upd-related-more` | 每页10新卡，重复/失效补页；复用同候选会话不再embed |
| 取消/改问题 | `upd-query-cancel/clear/archived`及输入编辑 | 撤当前epoch/持久grant，迟到不采纳，本机已存证据保留 |
| 历史 | `upd-query-history/legacy-history/history-retry` | 新固定record revision与卡payload；旧TXT/RESULT1/2/3只读桥，不恢复网络许可 |

图卡hash＋有效标注全局合卡，OCR Direct图归第一组，tags/vector迟到只追加理由/父来源。首父删除后图片来源handler精确选剩余hash/effective父；不同用户lineage不强合。来源不足为Block/Unknown，不伪原生页或OCR框。

## 保护与恢复

保`shuvi_parse_stage_v1.db`、`shuvi_kb_user_v1.db`、`shuvi_kb_vector_v1.db`；新精确20表`upd_*`和新文件根`knowledge_unified_v1`，不增第五legacy reader，不改旧wire/hash/space/token/profile/free/grant/历史计数。新ordinary扩展失败不drop旧库；引用保护建立早于旧cleanup。

原件/结果ZIP仍由旧owner持有，统一删除不自动物理删旧包。图文件共享按实际byte asset；occurrence/OCR/用户overlay独立。task持有、读租约、cleanup claim均持久；Unknown不自动重发，release故障可重试。归档保文件并停后续准入；完整既有数值代本机镜像恢复不重传。统一根+旧新根/DBfamily/temp/reserve纳共享500MiB；未知文件不自动扫除。

新根files/cache备份排除已配置；普通用户库既有备份行为未改，恢复缺图明确Missing。历史只保文本/原因/来源版本，不暗存原图像素副本；卡整体current表示仍有可用匹配父，不表示当时每个父仍当前。只有已写出Ready manifest的历史可跨进程恢复回执，未写成文件的内存pending不保证杀进程后保留。

## 父代理验证边界

本代理停止编辑并交还控制。父代理只委派一次spec-verify，沿tasks既定build-only，不追加UI询问或自动执行完整故事。

1. T046：使用最终90 ETS清单`arkts_check`后紧接`devecocli build`，实际build总数至多10（含正常缓存签名脚本内部build）。每次capture，失败修后直接build，failed与retry间不再checker。准确记录工具、工作区指纹、源码变化、制品SHA和失败。必要时只复跑限定host。
2. T047：build成功才正常缓存签名/模板恢复路径部署，唯一实时活动模拟器，`run --skip-build`。缓存/登录/目标不安全则具体INCOMPLETE，不newsign/force/login/卸载/reset/清资料，不向AI返回证书或私有输出。普通启动不冒Cold/UI通过。
3. 不启用视觉/自动嵌入，不迁移/升级，不导入用户全集，不点解析/query等业务按钮；无平台suite/hdc/文件传输/真实请求。禁止读改执行`scripts/paste-to-emulator.sh`与`spec/knowledge-emulator-e2e/`，不读秘密/.local/signing/private/raw/生产库。

## 未验与下一步

没有未完成实施任务或外部阻塞；未验不是“只差Key”。严格ArkTS/ArkUI与API签名、实际普通库事务隔离/连接、FLOATVECTOR SQL/排序、fsync/rename掉电、SDK资源释放、真实RCP/AssetStore/XML/zlib/ImageKit及备份恢复仍需平台证据。正式picker/双组分页/来源高亮/图预览/后台返回的UI只做方法级检查，未设备点击或截图。

DeepSeek账号可用、费用/留存、描述正确性和tags质量，真实MinerU新schema覆盖、实际全量embedding/同问题一次query计费/召回，以及生产迁移全集/30k和500MiB压力均未验。真实样本先另批自制/公开清单、独立gold、接收方/参数/可能费用/明确次数，不继承历史授权或自动新增探测。PPTX/XLSX/图像向量/回答/同步未实施，不能标八格式完整知识库。
