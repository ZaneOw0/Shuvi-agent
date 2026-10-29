# M1 阶段 4 实施报告

日期：2026-10-12。总体状态：**COMPLETED（实施范围 T001–T035；待阶段 5 验证）**。

本报告不是构建、安装、设备、UI或真机质量通过证据。未执行 arkts_check、devecocli build/run、UI自动化、设备日志读取、文件部署或签名操作。T036–T038 明确排除且未勾选。

## 逐阶段结果

| 阶段 | 任务 | 结果/证据 |
|---|---|---|
| Setup | T001–T002 | 完成：有效工程、HEAD7830319及已有改动保护、工具差异、新旧库隔离登记；六fixture SHA/原文范围/结构固定到golden |
| Foundational | T003–T005 | 完成：具名领域/端口/预算与host加载、源码/题集/语料指纹，无Kit领域/应用依赖 |
| US2 | T006–T011 | 完成：UTF-8/BOM/CRLF、UTF-16/行映射、结构/表格/图片引用、512/51分块及快照；red55/4→green69/0，原标题用例保留 |
| US1 | T012–T019 | 完成：真实Picker/fileIo/SHA256/TaskPool/RDB适配器、服务/原文/UI；red69/1→green71/0，仅host端口机制，不宣称真实SDK通过 |
| US3 | T020–T024 | 完成：标题、归档、快照重建、活动世代、确认单批删除/清空、提交后清理；red71/1→green72/0 |
| US4 | T025–T028 | 完成：检查点、暂停/恢复、启动对账、取消/晚到防复活/时限/UI；red72/1→green73/0，最终真实10/60秒host窗口通过 |
| US5 | T029–T032 | 完成：完整问题/实际输入、top5命中与来源快照、20条历史分页、旧版/删除/归档语义；red73/1→green74/0 |
| Polish | T033–T035 | 完成：知识库宽屏分栏/二级返回、长文本和数据标签、预算/故障/golden回归、来源/总spec/report；最终96/96 |
| Verification | T036–T038 | 跳过：阶段职责边界，全部未执行；交回父agent委派spec-verify |

各阶段已完成后分别即时修改 tasks.md，使用可用的 apply_patch（工具集中无 edit）。Polish 完成后单独勾选，不批量跨阶段补标。

## 文件清单

新增生产文件（均在 `entry/src/main/ets/knowledge/`）：

- `domain/TextKnowledgeModels.ets`、`domain/TextKnowledgePorts.ets`
- `pipeline/TextNormalizer.ets`、`pipeline/MarkdownStructure.ets`、`pipeline/StructuredChunker.ets`、`pipeline/QueryPreparation.ets`
- `application/TextKnowledgeService.ets`
- `infra/TextFileAdapter.ets`、`infra/TextProcessingAdapter.ets`、`infra/TextRdbRepository.ets`、`infra/TextKnowledgeAssembly.ets`
- `ui/TextKnowledgeView.ets`

修改生产文件：`knowledge/pipeline/Chunker.ets` 限定修复；`pages/Index.ets` 只改变知识库装配、返回和该tab宽度/数据标签。旧KnowledgeLab/probe/RdbKnowledgeStore/PseudoEmbedding/SampleCorpus源码未改、不执行；其他一级功能保持。

新增测试：`entry/src/test/TextPipelineCases.ets`、`TextServiceCases.ets`、`eval/text-m1-golden.json`。
修改测试：`run-host-tests.cjs`、`ChunkerCases.ets`、`CorpusCases.ets`、`fixtures/SOURCES.md`。原六份txt/md字节未改。
文档：本报告、执行 `plan.md`/`tasks.md`、总契约 `specs/02-个人知识库问答.md` 的新增M1范围/证据，不覆盖五稿、S1或56/1历史。

未改模块/权限/依赖/SDK配置、签名模板、capture脚本、路由资源、上游README；无Git写操作。

## host 测试与日志

全部日志基于 `.cache/test-logs/2026-10-12-<scope>-7830319/`，含host.log、meta.txt，全局index.tsv追加记录。

| scope | 通过/失败 | 说明 |
|---|---|---|
| m1-us2-red | 55/4 | 真业务失败：原标题块尾3处、原emoji低代理、新高代理、trim偏移 |
| m1-us2-green | 69/0 | 结构/映射/Unicode/原语料 |
| m1-us1-red | 69/1 | 服务导入尚未接入的明确错误 |
| m1-us1-green | 71/0 | 导入/判重/查询/原文/选择预算 |
| m1-us3-red / green | 71/1→72/0 | 管理入口缺失→归档/失败重建/文件故障通过 |
| m1-us4-red / green | 72/1→73/0 | 取消入口缺失→取消/晚到/恢复通过 |
| m1-us5-red / green | 73/1→74/0 | 完整问题未保存→历史快照通过 |
| m1-polish-host | 88/0 | 扩展golden/预算/故障 |
| m1-final-host | 90/0 | 加入真实10秒/60秒超时，70.824秒 |
| m1-polish-final | 96/0 | 六fixture服务golden，70.886秒 |
| m1-delivery-host | **96/0** | 最终代码，0取消，70.875秒 |

最终路径：`.cache/test-logs/2026-10-12-m1-delivery-host-7830319/host.log` 与 `meta.txt`；HEAD7830319，dev/rag，dirty22，工作区指纹4949231e2e75。runner打印新增生产/测试、Index、golden、六语料SHA256，不依赖git diff遗漏未跟踪文件的指纹。最终只有后续报告/checkbox文档编辑，不改被测试源码。

工具：PATH Node v22.23.2，CLI1.3.4，DevEco安装 `/Applications/DevEco-Studio.app/Contents`，SDK26.0.0.105/API26（oh-uni-package核对），纯host SDK转译器4.9.5。Node/CLI与仓库文档基线不同，未升级或掩盖。

复现（约71秒）：

```bash
DEVECOCLI_BIN=/usr/bin/false RUN_CMD='DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" node --test entry/src/test/run-host-tests.cjs' bash scripts/capture-test-log.sh m1-delivery-host 1s
```

capture的 `status=log-failed` 为刻意禁用设备日志，不读取个人设备资料。`run_cmd_status=ok` 与实际TAP96/0/0独立判定。没有设备证据。未落盘测试不用于结论；git diff --check仅编辑卫生核对，不是编译。

## 实现选择与偏差

- 仍为entry/V1分层，采用允许的泛型TaskPool函数execute；函数模式不能物理取消，单活动写任务等待退出但取消/删除/超时失效结果不发布，不称物理任务已停止。快照编解码/解码/查询准备也入CPU适配器，返回有界校验。
- 官方单次序列化16 MB；本轮增加12 MiB估算/快照保护线、20000节点/40000单元格/80000行、100块短事务。超保护线拒绝发布，原件/旧结果保留；这些是保守实现保护，不是资源测量结论。
- 不用禁用的as/JSON断言；采用具名关系行和显式版本wire。完整问题有界分行，历史不暗藏完整删除原件。
- FTS仅实际建表/事务写入、中英query、rollback/delete及既有活动行覆盖通过才开启；否则同库LIKE。没有为旧模拟器现象默认FTS分提交，也没有第二个空库降级。
- SDK OpenMode不存在EXCL；采用唯一资产ID、存在则拒绝、单导入/NOFOLLOW、不覆盖原件。真实URI/fd/平台语义仍须阶段5。
- 测试先失败证据并非每个新结构断言独立red：US2先覆盖已有标题/Unicode/偏移真实失败，结构断言随新增实现扩充；US3/US4初轮为入口未实现，后续行为/阶段故障/预算在Polish完整回归。透明记录，不声称所有分支逐个测试先失败。
- 长标题/完整表头无法计入512输入时明确失败并保留原件，不删前缀伪造成功。未知特殊Markdown保留并警告；非完整Markdown渲染器。

## 未覆盖、风险与后续

无依赖/密钥/权限扩权阻塞，无未完成实施任务。以下属于验证/后续门禁，不由本报告宣称通过：

1. T036：ArkTS严格模式/ArkUI及SDK实际编译，TaskPool类DTO序列化/返回模型、资源布局。host transpile不做这些类型与运行检查。
2. T037–T038：唯一设备、安全签名路径、真实选择器URI、原字节SHA256、S3非向量库/FTS有效性或LIKE、事务读写/关闭、重启对账/删除残留、手机/平板布局和输入保持。不得卸载、清库、读签名秘密或覆盖设备资料。
3. 时限通过的是host业务防迟到，不证明平台I/O能强制中止；TaskPool物理工作仍可能待退出。实际资源峰值/耗电与可承载边界待真机，不承诺1 MiB任何结构都能成功索引。
4. 固定六份语料和否例/定位通过不是S2完整检索质量评测，LIKE/字面关键词不理解任意自然语言或同义/否定语义，条件保留提示不表示模型理解。
5. M2–M5、复杂格式、视觉、embedding/L1、服务隐私许可、同步及双设备共享均未实施。本次本机测试许可不自动取得第三方公开展示权。

交付状态：**COMPLETED**，可交回父agent进入已选build+ui验证，完成结论以verification-report实际结果为准。
