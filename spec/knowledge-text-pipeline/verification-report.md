# M1 阶段 5 权威验证报告

日期：2026-10-12。最终状态：**INCOMPLETE**。本阶段唯一一次正式委派已结束，不自动再次调用验证流程或进入下一阶段。

**结论**：限定修复后 unsigned 构建通过，修复后完整 host 回归 96/96 通过；部署命令因无唯一目标被 CLI 拒绝，未安装、未启动应用。没有安全 signed 产物。US1–US5 设备 UI 均未执行，不是 M1 已验收，不是手机/平板真机质量通过。

## 1. 范围与流程结果

- CONFIG_ROOT：由 OS HOME 动态解析为 `/Users/zane/.local/share/deveco/`；已读取其 `specs/commands/spec-verify.md`，未再次调用 spec-verify。
- PROJECT_ROOT：`/Users/zane/DevecostudioProjects/Shuvi-agent`。
- Confirmed_Feature_Dir：`/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-text-pipeline/`，直接使用，不回退 feature.json。
- Verification scope：**build+ui**，来自父 agent 与 tasks.md Phase 9 marker；未因环境条件改为 build-only。
- 已读 spec.md、plan.md、tasks.md、implementation-report.md、AGENTS.md、总 spec、协作约定及日志脚本；已加载 deveco-cli 与 hmos-arkui-develop-skill，核对官方 TaskPool/fileIo 文档和 API 26 SDK 导出。可用 skills 没有 arkts-error-fixes，使用实际编译错误与官方 SDK 修复。

| 步骤 | 执行状态 | 真实结果与原因 |
|---|---|---|
| T036 静态检查 | executed | arkts_check 一次，18 个新增/修改 .ets，返回 No errors found；仅静态层，不是编译证明 |
| Phase 1 step 1 初 build | failed，已修复 | CompileArkTS 失败；完整日志检出 8 条明示错误，汇总 ERROR:9/WARN:179 |
| Phase 1 step 1 retry build | executed / PASS | 第 2 次 build 成功，CompileArkTS/PackageHap 完成，unsigned HAP 已生成 |
| T037 run --skip-build | executed / blocked | exit=1，DEVICE_SELECTION_REQUIRED；四个候选模拟器均 stopped，无唯一明确目标，不选择/启动任何设备 |
| T037 signed 安装/启动 | skipped | 当前仅 unsigned HAP，No signingConfig found；没有读取私人签名缓存或生成签名 |
| T037 专用 txt/md 副本 | skipped | 无安全唯一设备；没有创建设备目录，没有复制/覆盖任何设备文件 |
| T038 UI 准备 | executed | 直接沿用父 agent 五故事各一条复合用例，未重新生成用例、未询问 |
| T038 五故事 UI | skipped / INCOMPLETE | verify_ui 工具可用，但本轮没有安全部署实例；不能在旧安装上误验或把 host 当 UI |
| Phase 2 最终复验 | skipped | code_modified=false，只有初次 build loop 编译修复，没有 Per-Story Loop 源码修改 |
| 修复后 host | executed / PASS | 96 PASS / 0 FAIL / 0 cancelled / 0 skipped，70.906880 秒 |
| 证据/安全自审 | executed / PASS | 原 fixtures 字节/SHA 与固定 golden 一致，源码指纹与修复后 host 一致；保护配置无 Git diff |

T036–T038 的勾选由父 agent 最终负责；本报告区分“尝试完成”与“验证成功”，未修改 tasks.md checkbox。

## 2. 构建次数、错误与限定修复

Phase 1 step 1 `build_fix_attempts=2/10`；1 次初 build + 1 次 retry。没有 per-story fix build，没有第三次 build，没有重试上限超限。

| 次数 | 时间/退出 | 结果 | 完整证据 |
|---|---|---|---|
| 1 | 22:14:34，CLI exit=1，8.295 秒 | FAIL；CompileArkTS，无本轮成功产物 | `.cache/test-logs/2026-10-12-m1-verify-build-01-7830319/host.log`、`full-cli.log`、`meta.txt`、`arkts-check.md` |
| 2 | 22:20:18，CLI exit=0，4.351 秒 | PASS；Hvigor BUILD SUCCESSFUL 2.516 秒；No signingConfig found | `.cache/test-logs/2026-10-12-m1-verify-build-02-7830319/host.log`、`full-cli.log`、`meta.txt` |

首轮完整错误清单（行号为修复前版本；保留失败原始输出，不用 CLI 末尾截断摘要代替）：

| 错误 | 文件与行 | 修复 |
|---|---|---|
| 10605087 arkts-limited-throw | application/TextKnowledgeService.ets:125 | catch 对象经 instanceof Error 收窄后重抛，非 Error 明确 TextFailure；不加 as |
| 10605030 arkts-no-structural-typing | application/TextKnowledgeService.ets:179 | Promise reject 回调按 Object 参数声明，与标准 Promise 契约匹配 |
| 10605087 arkts-limited-throw | infra/TextFileAdapter.ets:105、114 | 两处 catch 同样显式收窄，非 Error 明确 IO 阶段失败 |
| 10605087 arkts-limited-throw | infra/TextRdbRepository.ets:66 | rollback 后显式 Error 收窄，非 Error 明确 RDB 事务失败 |
| 10505001 namespace export | infra/TextFileAdapter.ets:62、68、96 | ReadOptions/WriteOptions 是 CoreFileKit 顶层命名导出，不是 fileIo namespace 成员；改为真实 import |

SDK 依据：`ets/kits/@kit.CoreFileKit.d.ts:26,34`，`ets/api/@ohos.file.fs.d.ts:2664,3557,5689,5738`；官方文档 ID 为 `API参考/Core_File_Kit_文件基础服务/ArkTS_API/ohos_file_fs_文件管理_/js-apis-file-fs`。TaskPool 泛型函数 execute 的 API13+ 重载已核对，未变更其生产调用。

修复不改变预算、判重/版本/归档/删除范围、任务失效、数据库布局或公共端口；没有 any/unknown/as。静态工具未检出的错误以实际构建为准。严格遵守 failed build 与 retry 之间不再 arkts_check；第二次 build 是修复后编译证据。编译仍有 SDK 可抛异常/系统能力警告，未用抑制注释消除，不推断运行时已验证。

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`，**759853 bytes**，SHA256 `d1cf9040a431cf8d135304b6bfc5a545cd0d01dd41e0057cbc914c0f739b85e3`，mtime `2026-10-12T14:20:24.267Z`。**没有 signed HAP；SignHap 任务显示完成不代表已签名。** 指纹见 `.cache/test-logs/2026-10-12-m1-verify-audit-7830319/host.log`。

复现构建（保留无签名模板）：

```bash
DEVECO_HOME="/Applications/DevEco-Studio.app/Contents" DEVECOCLI_BIN=/usr/bin/false RUN_CMD='node .cache/m1-verification-evidence.cjs --log-dir .cache/test-logs/2026-10-12-m1-verify-build-02-7830319 build' bash scripts/capture-test-log.sh m1-verify-build-02 1s
```

本机 `.cache/m1-verification-evidence.cjs` 只用于证据：调用真实 devecocli、记录 CLI 退出码/耗时与源 SHA，将 CLI 保存的完整输出以禁止覆盖方式复制进本轮 capture 目录。复现同一 scope 时 capture 自动加后缀，`--log-dir` 应对应新 capture 目录，否则 full-cli.log 的禁止覆盖检查会拒绝覆盖历史证据；直接复现标准构建命令为 `devecocli build`。

## 3. 部署与设备保护

实际调用 `devecocli run --skip-build` 一次（capture RUN_CMD 包装），22:21:05，exit=1，1.234 秒。证据：`.cache/test-logs/2026-10-12-m1-verify-deploy-7830319/host.log` 与 `meta.txt`。

CLI 原始结果：

```text
DEVICE_SELECTION_REQUIRED
Available devices:
- Mate 90 Pro [emulator, stopped]
- Mate X7 [emulator, stopped]
- MateBook Pro [emulator, stopped]
- MatePad Pro 13 [emulator, stopped]
```

没有明确唯一设备，未填 --device、未重试选择、未启动模拟器、未接受协议。即使之后目标明确，当前无 signingConfig 仍是独立部署前置阻塞；本轮没有观察真实安装错误，不能把它描述为“签名安装失败”。

复现本轮非定向检查：

```bash
DEVECO_HOME="/Applications/DevEco-Studio.app/Contents" DEVECOCLI_BIN=/usr/bin/false RUN_CMD='node .cache/m1-verification-evidence.cjs run --skip-build' bash scripts/capture-test-log.sh m1-verify-deploy 1s
```

安全副本目录：**未创建**。未打开用户库/旧 probe 库，未读取设备原文/私人资料；未卸载、清库、清日志、重签、登录、改 Git config/commit/push。没有调用 dev-run 脚本、直接 hdc 或安装旧产物。所有 capture 使用 DEVECOCLI_BIN=/usr/bin/false 禁止目标不明确时抓设备日志，device.log 没有设备取证价值；meta 的 device=auto 是脚本默认文本，不是已选设备。

## 4. UI 计划与逐故事权威结果

用例直接沿用父 agent，不重新生成。每故事恰好一条核心复合用例；若能够执行，仅操作本轮测试 ID，US3 删除样本与 US4/5 保留样本隔离，实际个人库批量/清空不执行。

| 故事 | 一条复合用例与期望 | Phase 1 attempts | 修复/重验 | 权威状态 |
|---|---|---:|---|---|
| US1 | 导入资料→真实系统 Picker 选择专用 txt/md→golden 正词检索→第一命中原文→golden 否例；真实就绪、通道/行范围准确，否例无召回，无伪向量/假回答 | 0 | 无 | INCOMPLETE：未部署 |
| US2 | Picker 导入工程 Markdown/Unicode 副本→标题正文/表格检索→片段/原文；标题/表头/代码/列表、非 BMP/BOM/换行位置可核对，外链仅引用 | 0 | 无 | INCOMPLETE：未部署 |
| US3 | 仅测试文档重命名→重新索引→归档→默认排除/显式包含→恢复→确认单篇删除→检索不命中；身份原件不变、状态独立、删除范围准确、其他资料不变 | 0 | 无 | INCOMPLETE：未部署 |
| US4 | 测试文档处理/重建→可用时序取消→切一级页返回→停止/启动但不卸载/清数据→任务/资料回看；完成列表/输入保留、未完可恢复、晚到不发布 | 0 | 无 | INCOMPLETE：未部署；强杀阶段故障亦未覆盖 |
| US5 | 真实 L0 查询落库→历史→重启回看→仅删除对应测试原文→历史引用；完整问题/实际输入通道/定位快照持久，删除失效只显示快照，无假 L1，归档不失效 | 0 | 无 | INCOMPLETE：未部署 |

verify_ui 工具存在，本轮调用 **0 次**，没有校验 ID、截图或 UI 运行日志；不是“工具不可用”。实际阻塞是安全设备/部署前置条件。不将 host 服务假端口、源码审阅或 unsigned 构建当成真实 Picker/RDB/UI 通过。

`code_modified=false` 仅指 Per-Story Loop 修复标志，不表示本阶段没修源码。Phase 2 **未执行**，输出 `[PHASE2_SKIPPED] reason=no_per_story_fix`；初次 build loop 的三文件编译修复不触发最终复验。**Phase 1 的五个 INCOMPLETE 是本报告权威故事结果。** 无失败故事重试，无 RETRY_LIMIT_EXCEEDED。

## 5. 修复后 host 与证据分层

修复后运行完整 host：**96 PASS / 0 FAIL / 0 cancelled / 0 skipped**，耗时 **70906.880334 ms**。包含实际等待的10秒查询（10016.852208 ms）和60秒索引（60103.544291 ms）窗口；不是跳过时限测试的短轮。六 fixture SHA 与 text-m1-golden-v1 全部一致，旧失败用例保留。

证据：`.cache/test-logs/2026-10-12-m1-verify-fix-host-7830319/host.log`、`meta.txt`、全局 `index.tsv`。capture `status=log-failed` 是刻意禁止设备日志，`run_cmd_status=ok` 与实际 TAP 独立核对。旧阶段4 `m1-delivery-host` 及所有 red/green 日志保持，不声称旧 host 覆盖本轮新代码。

```bash
DEVECOCLI_BIN=/usr/bin/false RUN_CMD='DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" node --test entry/src/test/run-host-tests.cjs' bash scripts/capture-test-log.sh m1-verify-fix-host 1s
```

host 证明纯逻辑与应用服务的具名假端口行为；不执行真实 TextFileAdapter/TextRdbRepository/TaskPool/ArkUI，即使 runner 打印其 SHA 也不代表平台执行。批量/清空仅 host 假端口覆盖，不删个人库。

## 6. 本阶段修改与追溯

生产源码仅三文件编译修复（既有实现文件上增量 patch）：

- `entry/src/main/ets/knowledge/application/TextKnowledgeService.ets`，SHA256 `7bb0f0bd519fff14ea1ba869a4f0267a956ebffdd8123ab8553ddc8bd34da0b5`。
- `entry/src/main/ets/knowledge/infra/TextFileAdapter.ets`，SHA256 `c65bc087f958b28ad04dcf18bf3c43482defd98a3a8ff9b96cdfaa4fa4d7200a`。
- `entry/src/main/ets/knowledge/infra/TextRdbRepository.ets`，SHA256 `7c19a1f442a0c5953e52591f565996066cc032a8befd696d7081938338d434bb`。

文档新增本报告；总 spec 只增本轮真实层级/证据/未覆盖。本机 ignored `.cache/m1-verification-evidence.cjs` 和本轮五个日志目录是验证证据，不打包 HAP、不作为应用依赖。原 fixtures、golden、生产其他文件、测试源码、SDK/权限/依赖/路由/签名模板、capture 脚本、旧 probe 源码及实施 host 记录均未手工改动。devecocli build 内部显示既有 ohpm install 检查，无主动新增依赖；manifest/lock 无 Git diff。

HEAD：`7830319984b351d56946e8e01d8a649439828f79`，分支 dev/rag。capture 当时 dirty_files=23，worktree_fingerprint=`0b9d2d505186`；该值仅含 tracked diff，三份修复文件原本 untracked，故 build01/build02 该值相同，**必须结合每轮新增源 SHA**，不能仅凭 worktree_fingerprint 断言同版。最终只有报告/总 spec 文档追加，不再改被测试源码。

模板 `build-profile.json5` SHA256=`36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`，首 build、修复 build、deploy、audit 一致；未读取 .local 私人配置或密钥证书。git diff --check 通过，受保护配置/capture 脚本 Git diff 为空。

工具：PATH Node **v22.23.2**；实际 Hvigor 进程使用 DevEco bundled Node **v24.14.1**；CLI **1.3.4**；DevEco `/Applications/DevEco-Studio.app/Contents`；SDK **26.0.0.105/API26/platform26.0.0**；host SDK 转译器4.9.5。与仓库旧 PATH Node/CLI 文档基线差异如实保留，未升级。

## 7. 自审与下一门禁

构建断言：build 01、02 均有 `[BUILD_ATTEMPT]`，总数2≤10。UI 调用0，US1–US5 attempts 均0≤3，无无断言调用。`[CODE_MODIFIED] initialized code_modified=false` 已输出；只有初次编译修复，未置 true。Phase 2 无代码修改/构建/部署。没有 question、二次委派或自动新阶段。最终使用 Phase 1 INCOMPLETE，不用 host PASS 代替故事 PASS。

剩余门禁（本轮不自动触发）：

1. 明确授权唯一测试目标，并由既有安全流程提供可更新安装的签名产物；不得用卸载/清数据/强签解决安装身份问题。
2. 在该目标新增不覆盖的独立 txt/md fixtures 副本，经真实 Picker URI 执行五故事；记录原件 SHA、实际 TaskPool 序列化、RDB S3 schema/事务/FTS 或 LIKE/资源关闭与定位结果。
3. 取消时序、进程停止/重启、各阶段故障、晚到不复活、待清理/孤儿对账的真实平台行为尚未覆盖；不能虚造强杀测试成功。
4. Phone/Tablet 真机、宽屏/旋转/大字体/长标题与原文、性能峰值/内存/耗电/文件 fd 行为、1 MiB/批次/库额度/10000块/12 MiB 传输保护的真实设备压力未测。host 时限是业务防迟到机制，不是平台强制取消证明。
5. S2完整检索质量、真实语义/L1、其他格式、MinerU/图片、同步/外发许可和八格式支持仍不在本轮；保留总 spec S1/56-1及阶段4历史。

**最终权威状态：INCOMPLETE（unsigned build PASS + post-fix host PASS；signed deploy/UI/真机质量未完成）。**
