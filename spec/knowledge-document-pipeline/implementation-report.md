# M2-A 阶段 4 实施报告

**最终状态：COMPLETED（仅 T001–T031 实现及 host；不是功能已验收）**

日期2026-10-14；Confirmed_Feature_Dir即本目录，PROJECT_ROOT为现仓库，CONFIG_ROOT通过本机home动态解析为`/Users/zane/.local/share/deveco/`。已读取实现工作流、feature spec/plan/tasks、总spec、AGENTS、平台基线及M1邻近接口。用户批准自主实施，未question。本轮无checker/build/deploy/run/UI、真实服务、样本下载/扫描、HDC或Git写入。

## 阶段结果

| 阶段 | 任务 | 结果与证据 |
|---|---|---|
| Setup | T001–T002 | COMPLETED。有效既有工程不重建；保护基线/官方SDK重载重新核对，plan登记摘要；test-contract冻结公开控制fixture和负例 |
| Foundational | T003–T005 | COMPLETED。具名模型/预算/纯端口、无Kit/秘密公共状态；host注册保留旧96及六golden |
| US1 | T006–T009 | COMPLETED。测试先业务RED；Asset属性状态/TokenCRUD/独立AES256-GCM密钥租约，DEVICE_UNLOCKED/NEVER/非持久；密码视图无预填/复制/显示/自动连接；4/4 GREEN |
| US2 | T010–T015 | COMPLETED。Grant绑定与非敏感免费逐件例外、预算；系统Picker保真复制SHA/OOXML目录身份/PDFKit并发页数；独立S3显式库与准备确认视图；9/9阶段GREEN |
| US3 | T016–T021 | COMPLETED。有界标准JSON控制层、身份状态/角色目的地；rcp分离/无redirect缓存trace/TLS/Token仅控制面；真实chunk写前cap，原件PUT/批次先登记/UNVALIDATED隔离包编排和视图；最终全量覆盖 |
| US4 | T022–T025 | COMPLETED。未知不重提、原身份Query、未决slot/tombstone、晚到失效/清理计量重试；Assembly和EntryAbility背景桥只暂停M2；不自动前台续跑 |
| US5 | T026–T028 | COMPLETED。M1状态回归/不索引复杂包、能力分层；Index两个Assembly独立，FeaturePages/TextKnowledgeView仅入口callback；输入目录存在，不扫描/覆盖，input-guide交接 |
| Polish | T029–T031 | COMPLETED。仅INTERNET、选择性M2备份exclude，安全审查/全套host、总spec增量和本报告；逐阶段已立即勾选 |
| Verification | 本阶段之外 | SKIPPED BY SCOPE。不执行或勾选阶段5任务，不产生verification-report |

## 实现边界

独立库`shuvi_parse_stage_v1.db`及filesDir/cacheDir的`knowledge_parse_v1`，版本标识/DDL/显式columns/rowcodec严格；未知既有库拒绝，不reset或打开M1/probe。单写队列按非秘密完整snapshot短事务提交，以具名深拷贝冻结队列输入，防止后续UI修改或await期间变更污染已排队检查点。

控制面仅固定精准vlm/单项batch；控制响应先获得/持久化batch再存加密地址，先登记租约引用再PUT。官方无data_id幂等保证，未知申请不可重提。未知远端slot只在真实done/failed观察后解锁；本机删除保留无标题/哈希/正文最小tombstone。凭据变更撤销Grant、暂停、清旧租约，不假同账号；原身份查询复核要求明确确认。

PDF仅真实本机Kit加密/页数，不做全文/预览；预检之前保真原件已登记，失败/不可用/取消保留且阻止。Office仅中心目录主包身份，不解压成员/公式/原生定位。本轮对ASCII包路径作保守校验，非受支持路径编码会阻塞，不假支持任意OOXML变体。下载仅传输外层/字节/SHA/完整结束，绝不验证内层schema/CRC或宣称真实性；结果永UNVALIDATED。

全局默认关、逐件5项确认，完整原件/图像、未知隐私、非敏感和当前免费资格分别显示。网络30s连接/30s无活动/120s请求墙钟；前台15min/90查询/5至30s退避，429停止提示（未知Retry-After不猜）；零自动申请或PUTretry，手动继续只Query原身份，未尝试PUT且服务waiting-file/同租约有效时才可执行首次PUT，不补申请。

安全Asset状态只ATTRIBUTES，不公开取SECRET。认证秘密只专用平台边界临时使用，背景/退出清输入及本机请求头/字节引用；不能保证ArkTS字符串或SDK内部副本物理零化。AES随机nonce/AAD绑定任务/hash/version/purpose/revision/expiry，地址密文新子树，缺键认证失败不明文降级。下载10min是本机保护窗口，remoteExpiry UNKNOWN不是服务留存期限。业务别名唯一，不执行任何真实Asset测试或覆盖用户别名。

## 文件清单

新增12生产文件（均在entry/src/main/ets/knowledge）：

- domain/DocumentParseModels.ets、domain/DocumentParsePorts.ets
- pipeline/DocumentParsePolicy.ets、pipeline/MineruProtocolCodec.ets
- application/DocumentParseService.ets
- infra/MineruCredentialStore.ets、infra/DocumentFileAdapter.ets、infra/DocumentPdfPreflight.ets
- infra/DocumentParseRepository.ets、infra/MineruTransportAdapter.ets、infra/DocumentParseAssembly.ets
- ui/DocumentParseView.ets

新增测试：entry/src/test/DocumentParseCases.ets、DocumentParseServiceCases.ets；修改run-host-tests.cjs注册纯模块、源码指纹和保护基线审计，不转译/执行SDK或UI。

限定修改：Index.ets、components/FeaturePages.ets、knowledge/ui/TextKnowledgeView.ets、entryability/EntryAbility.ets；module.json5仅INTERNET；backup_config.json选择性排除新子树/DB/sidecar且allowToBackupRestore保持true。

新增文档test-contract.md/input-guide.md/implementation-report.md，plan.md追加Setup记录、tasks.md逐阶段勾选；总spec只增量范围/边界/证据。创建批准的`.cache/m2-input/user-pdf/`入口，没有读取内容。日志/host转译产物只在ignored.cache。原spec/feature.json修改由父流程留下，本subagent不修改；knowledge-emulator-e2e未跟踪记录保留。

## 测试与日志

所有执行都经既有capture脚本、CAPTURE_HOST_ONLY=1，cmd先执行、设备日志跳过。每目录包含host.log/meta.txt，全局index.tsv登记。没有运行未落盘测试。

| scope（目录前缀2026-10-14，后缀-34880f9） | 实测结果 |
|---|---|
| m2-us1-red | 4项，3PASS/1业务FAIL，配置成功状态与revision预期未满足 |
| m2-us1-green | 4PASS/0FAIL |
| m2-us2-red | 5项，2PASS/3业务FAIL，许可正例/页边界/预算尚未实现 |
| m2-us2-green | 9PASS/0FAIL |
| m2-us3-red / green | cmd_exit1 / 0；英文测试标题触发现保守过滤，host.log整体withheld，不能引用逐项计数 |
| m2-us4-red / green / lifecycle-green | cmd_exit1 / 0 / 0，同过滤限制 |
| m2-us5-red / green | cmd_exit1 / 0，同过滤限制 |
| m2-polish-all-host / public-host | cmd_exit0，仍被英文题名过滤；旧日志保留，没有读取私有原始输出 |
| m2-polish-final-host | 可读146PASS/0FAIL，71.107秒 |
| m2-publish-red | 1项，0PASS/1业务FAIL，包登记事务失败仍公开成功；修复回退结果/保留清理账本 |
| m2-final-all-host | 147PASS/0FAIL，71.022秒 |
| **m2-delivery-host** | **148PASS/0FAIL/0取消/0跳过，71.026秒；原96+新增52** |

最终证据：[host.log](../../.cache/test-logs/2026-10-14-m2-delivery-host-34880f9/host.log)、同目录meta.txt。HEAD34880f9/dev/rag、dirty24、工作区指纹`13bd6dc192682aa09862ed69f67ebba6016ff40e016f834569cfb3b781d2f556`；该指纹为测试时，随后仅报告/任务文档变化不与测试指纹混称一致。Nodev22.23.2、SDK转译器4.9.5、平台基线未升级；runner打印新增production/test/UI source与golden/六fixture SHA，不把SHA打印当SDK执行。

复现：

```bash
CAPTURE_HOST_ONLY=1 RUN_CMD='DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" node --test entry/src/test/run-host-tests.cjs' bash scripts/capture-test-log.sh m2-delivery-host-reproduce 1s
```

新增22纯策略/协议/目录元信息用例、29服务用例、1源码边界审计；包括无确认零端口请求、six states、重复JSON/深度/字节/整数、目的地混淆、流预算、OOXML穿越/链接/加密/ZIP64、多卷、错误身份/状态、未知提交/PUT、限频/鉴权/过期、背景/关闭/删除晚到、cleanup重试、结果包非法/登记失败、PDF预检取消原件保留、M1 state/history/fixture隔离。目录元信息与公开控制fixture仅单元构造，非完整Office文件/服务样包。

## 保护与偏差

- 公开模板SHA仍`36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`；capture/mac-run/依赖/golden/六原件摘要与Setup一致。Git diff --check通过，受保护M1模型/Ports/Service/Rdb/File/Assembly/Normalizer/golden/脚本/依赖字节审计通过。
- 无变更M1wire/schema/预算/两份设备资料/六设备files；probe不装配、不读库或filesDir/kb；不读.local、证书/私有配置、用户原文件或真实Token；无SDK/Node/deps升级、Git写、设备操作、样本下载/抓取、公网解析/检查连接。
- 无安全边界降级。实现细化：repo端口提交整份非秘密snapshot，显式列/严格布局，深拷贝+串行短事务；恢复守旧Query、不假续传。不是新权限/业务格式扩张。
- 证据偏差：保守过滤命中英文题名导致中间阶段TAP不可逐项审计。原记录/rc保留，未改保护脚本，题名去敏后重新全量可读落盘；只用最终148项和可读RED做精确结论。

## 未覆盖与下一步

本阶段失败/阻塞任务：无剩余实施任务。阶段5仍未执行；host不证明ArkTS严格编译或平台行为。

待验证：真实AssetCRUD/锁定/GCM租约、PickerURI/取消/字节SHA/fd、TaskPoolDTO/取消/PDFKit实际加载地域ARM设备、RDB严格DDL/事务/重启/cleanups、rcp IncomingDataCallback异步等待/onDataEnd/TLS/3xx/实际字节硬cap/总时限、选择性备份、PhoneTabletUI和返回/输入清理。PDFKit原生同步加载无官方强制终止保证，协作取消/回调失效不是原生资源已即时释放证据，实际长调用需平台验证。保守路径/固定角色主机遇真实变化会暂停，不能自动增加主机。

真实Token/四格式获准原件/公网任务/实际ZIP均**未执行**。后续只由用户自行配置并逐件确认获许可非敏感免费测试文件，再M2-B收样取证；禁止agent代填/读取/截屏/伪产物。M2-B内层schema/解包/结构/native locator/PDF完整原页高亮、Office位置、M3tag、LLM/embedding/sync等不在本轮。

父agent下一阶段执行既定Verification，不重问用户、不修改scope或把缺样本改称服务PASS；若实际平台不满足强边界，保留失败与原件、限定修复后再取证。
