# MinerU Token 保存修复验证报告

**日期**：2026-10-15。**最终状态：INCOMPLETE**。本报告是本次限定修复唯一 spec-verify 委派的权威报告；不替换旧 `verification-report.md` 或旧 M1/M2 结论。

## 范围与直接结论

- 配置根原生 HOME 解析为 `/Users/zane/.local/share/deveco/`，已加载 `specs/commands/spec-verify.md`。项目根 `/Users/zane/DevecostudioProjects/Shuvi-agent`，功能目录使用父流程确认的 `spec/knowledge-document-pipeline/`；当前任务 `token-save-fix-tasks.md`，Verification marker 为 **build+ui**。沿用用户同意的流程例外，不重新审核或提问。
- 基线仍为 **a799981 feat(knowledge): 增加 MinerU 安全配置与复杂文件转发链路**，分支 `dev/rag`。本轮没有 commit、push、Git config、登录、接受协议、强签、卸载或清库。
- **生产路径是真实 SDK/网络实现，不是生产 Mock**：`DocumentParseAssembly` 默认 `MineruCredentialStore` → `MineruPlatformAssetStore` → `@kit.AssetStoreKit`；远端为 `MineruTransportAdapter`/rcp。host 注入测试不能证明设备 SDK 写入成功。
- **本轮保存是否成功：未证实。** 修复版已经构建并安装，真实应用首次打开引擎设置显示“未配置”；返回再打开仍是同一状态。没有操作生产保存按钮、输入凭据或写删生产 alias。页面“未配置”不能当作本轮保存尝试失败，因为本轮没有进行保存尝试。
- **用户上次无反馈的唯一根因仍未实测定位**：已修复的 IS_PERSISTENT 默认参数风险和消息传播缺口有文档/源码/host 证据；本轮没有取得设备新增失败 code，不能宣称这就是用户当次唯一原因。
- **真实 API 没有验证成功**：生产页面当前未配置，agent 不可获取/代填秘密；本轮没有申请任务、PUT、远端状态查询或结果接收，不能把安装成功、host 或本机 PDF 元信息当认证/解析成功。

## 执行结果

| 步骤 | 状态 | 实际结果与边界 |
|---|---|---|
| 材料读取与范围 | executed | 当前 tasks/implementation、相关生产三文件、装配/页面邻接、AGENTS、mac/capture 脚本；未循环读取旧整包 history |
| 快速静态检查 | executed / PASS | 生产三文件及两测试 `.ets` 共 5 文件，`No errors found in 5 file(s)`；只作检查，不代产物 |
| 首次脚本预检 | executed / stopped | `Mate90Pro` 不匹配清单全名；构建及安装前停止，RC1，不计实际 build 次数，日志保留 |
| 初始构建 | executed / PASS | 改用精确清单名 `Mate 90 Pro`、同 serial；缓存签名后 `devecocli build --product default` RC0，**实际 build=1/10**，无编译修复 |
| 部署 | executed / PASS | 同一 mac 脚本在构建成功后调用 `devecocli run --skip-build --product default --device 127.0.0.1:5555`，首次安装启动 RC0；没有启动其他实例 |
| 全量 host 回归 | executed / PASS | **180/180**，0失败/取消/跳过，**71.139825 秒**；原148+新增32。真实适配器代码的注入边界仍不是真实平台执行 |
| US1 自动校验 | attempted / INCOMPLETE | 初次及一次工具初始化重试，共2次，均未配置多模态模型，无校验 ID、截图、执行步骤；不是应用断言 FAIL |
| US1 CLI 分层观察 | executed / partial | 仅白名单标签、几何、动作RC；进入真实设置、看到未配置和保存/删除控件、返回再打开。未显示密码内容、未截图；不作 verify_ui PASS |
| US1 独立 alias 真实 CRUD | skipped / unproven | 无可直接执行的现有设备用例/公开 CLI 测试入口，详见下文；没有旧参数真实拒绝码或修后平台保存证据 |
| US2 PDF 本机预检 | executed / partial | 只读取授权目录指定一件论文元信息/哈希，符合预算；非 HarmonyOS PDFKit 和非远端解析证据 |
| US2 自动 UI 与真实提交 | skipped / blocked | 共享 UI 工具前提不可用；生产配置未就绪。未打开 Picker 检查此论文是否在设备，未写入设备或绕过选择器 |
| 有界设备日志 | executed / empty | `devecocli log` 经 capture 采集1分钟，RC0，device.log为空；不推断无异常或 code=0 |
| Phase2 | skipped | `code_modified=false`，无故事内 src 修复；Phase1 未完成结果权威，不能用 host 或 CLI 补成自动 UI 通过 |

F005–F007 任务复选框保持原状，由父流程按本报告结案，不能把 F006/F007 勾成通过。

## 测试计划与逐故事结果

使用父流程给定两条复合故事，不从旧 spec 重生成五故事计划。

| 故事 | 本轮计划 | Phase1 自动次数/修复 | 权威状态 |
|---|---|---|---|
| US1 | 固定设置的保存接线、忙/错反馈、退出清输入；独立非秘密 alias 的旧参数拒绝与省略默认后保存/属性确认/更新/删除；生产仅属性状态 | **2/3**；第2次仅工具初始化重试，无代码修复；无校验ID | **INCOMPLETE**：页面可达与状态已观察；实际保存、错误/忙态可见、非空输入清理、真实独立 alias CRUD 未证 |
| US2 | 选授权预算内单件PDF，经应用已存Key、真实Picker、逐件免费同意，观察真实申请/PUT/查询/隔离收包 | **0/3**，共享工具故障后跳过；没有代码修复 | **INCOMPLETE**：本机文件预检通过；生产未配置、设备文件可见性未查；网络阶段均未执行 |

两次 US1 `freshStart=true`、bundle `com.example.shuvi`、device `127.0.0.1:5555`。工具两次相同原文：

> UI 意图校验功能不可用：未配置多模态模型。请在配置文件中为 ui_verification agent 配置一个支持多模态的模型，或登录账号以使用内置多模态模型。

未改 DevEco 模型配置或登录态，不再重试。CLI 观察有独立日志，绝不赋予自动校验 ID。当前 `TextInput` 的可访问树不是空密码/密码已清的可靠证明，本轮不记录值，也不据其断言清理通过。

## 真实 SDK 与凭据证据

1. 首次实际设置页面是在生产 `openParse` 等待 `assembly.initialize()` 完成后才暴露 `parseService`。该初始化使用真实 `credential.status()`，其配置判断只查生产 alias 的 `RETURN_TYPE.ATTRIBUTES`，不查 SECRET。页面观察为“未配置”，与适配器 Missing 分支一致；没有直接读取平台回包或取得数值code，不能断言现场实际发生了24000002（也可能返回空数组）。
2. 返回再进入设置复用既有 `parseAssembly`，**不是新一次平台查询、进程重启或写后持久化证明**。未做锁屏、重启后保存确认或租约 AES-GCM 验证。
3. 生产 alias 未由诊断进行 ALL/SECRET 查询、未替换/删除、未写假凭据。应用正常状态检查不是认证有效性检查。
4. **独立 testalias CRUD 未执行**：仓库 `entry/src/` 只有 `main`、host `test`，无 `ohosTest` 目录/注册用例；现有 `devecocli run --help` 只给应用 build/run、ability、apply 等入口，无公开测试 runner 调用。遵守流程禁止直接 hdc，且不添加生产可调用诊断路由，不为测试修改生产装配或绕过权限边界。此处仅说明本轮安全路径不足，不宣称 IDE/人工测试绝对不可行。
5. 未创建 testalias，**cleanup=not-applicable**，没有任何测试 alias 删除。旧 IS_PERSISTENT=false 的实际设备拒绝码、修后省略属性的真实 add/attributes/update/remove 结果均 **未证**，不能引用 host 注入码代替。

## 单件 PDF 与网络

只对已授权目录的一件文件做本机 Apple PDFKit/CryptoKit 预检，无依赖安装、正文/图片提取或其他私有目录扫描：

| 字段 | 结果 |
|---|---|
| 本机路径 | `.cache/m2-input/user-pdf/_ASE_2025__Auto_fix_missing_dependency_errors.pdf` |
| 大小/页数/加密 | **1,056,162 字节 / 13 页 / false**，≤20MiB且1–50页 |
| SHA256 | `e70dde8c765b3f5a10b66524ebd8e237e44bdcfaaef8b1976012fdd9e937576b` |
| 本次应用远端任务 | **0**；未产生 batchId、服务code或隔离结果包 |
| 网络阶段 | 申请未执行；原件PUT未执行；Query未执行；ZIP接收未执行；UNVALIDATED未产生 |

用户授权该目录PDF、完整文件/内嵌图、未知隐私例外及本次免费测试，未被误记为“未授权”。实际阻塞是**生产凭据未配置且agent不能代填**；设备 Picker 的文件可见性尚未核查，不能说已证明文件缺失。未对其他10件做元信息/字节读取，未批量任务，未自动收费/重申请，未向外部curl/service灌文件或改库。既有禁止HDC写入保持，不重试Download写入、不自动拖入，不读/执行未审核 `scripts/paste-to-emulator.sh`。

## 构建产物与指纹

| 产物/源码 | 字节 / SHA256 |
|---|---|
| `entry/build/default/outputs/default/entry-default-signed.hap` | **1,304,471** / `b6fe6e08c5e6b1062f711c4e940762208240a54e36b5b7d098a0c191749bc7a6` |
| 同目录 `entry-default-unsigned.hap` | **1,260,347** / `bae73d2026aa2a6b8b962dc71ff97053ec51e5c5d2f406a19b6b92df1479fd02` |
| `MineruCredentialStore.ets` | `98e8a5efaad7f476c9455777aeec799436828ef41abaeafb16de60c4db07b730` |
| `DocumentParseService.ets` | `b0ba858afe93b2786bbcecfc81c596430281f7509a6f890bd79c416d58b8f301` |
| `DocumentParseView.ets` | `700d8acaa148cf14ee491d719ccd6c16b0d92af3dd5d1905b03d807dddd564ec` |

上述三生产文件是上一实施阶段的未提交修复，本轮未改源码，也没有新的平台测试 `.ets`。本轮只新增忽略目录中的去敏观察/元信息/审计脚本与转录，以及本报告和总spec增量。

build/deploy与最终180项host的meta均为 HEADa799981、dirty12、指纹 **76cb50a7385efc2e2d33ccb5c53028d6a0e7669833c518a7ec332abb711433ed**；随后新增报告文档不混称同一工作区快照。最终host.log包含源/fixture/golden/loader摘要。Nodev22.23.2，独立CLI路径使用既有22.23.2安装，无SDK或依赖升级。`build-profile.json5` 恢复前后公开模板SHA均 **36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7**。脚本、装配、INTERNET单权限、依赖、M1六fixture/golden与基线diff不变；`git diff --check`通过。

## 日志与复现

证据根 `.cache/test-logs/`。下列目录均为前缀 `2026-10-15-m2-token-save-fix-`、后缀 `-a799981`，各保留 `meta.txt` 及全局 `index.tsv`：

| 中段名称 | 内容与RC |
|---|---|
| `build-deploy` | 不含空格的实例名预检停止，cmd_exit1；未build |
| `build-deploy-exact` | 缓存签名、build、run公开阶段，cmd_exit0；工具原始私有输出未读 |
| `verify-host` | 180/180完整公开TAP，cmd_exit0，71.139825秒 |
| `approved-pdf-meta` | 单件元信息/hash，cmd_exit0，不含正文 |
| `ui-home` / `ui-profile` / `ui-profile-bounds` / `ui-bounds-schema` | 安全观察脚本调试；profile两次RC3为未找到可解析几何，未执行点击，其余RC0；不是应用失败 |
| `ui-production-state` / `ui-reopen` | CLI实际导航及未配置状态，cmd_exit0，不含输入值或原始树 |
| `device-log` | log_exit0，device.log为空，不能作无故障证明 |
| `audit` | cmd_exit0；公开host.log被既有保守过滤器withheld，仅引用meta，不绕过读取原始流 |

除 `device-log` 外，capture 使用 `CAPTURE_HOST_ONLY=1`，`log_exit=not-run` 只表示不额外采集hilog；其中 UI 命令本身确实访问固定模拟器，不能把这个标签解释为 UI 在host模拟执行。工具错误及静态检查原文转录在 `.cache/token-save-fix-tool-results.md`。真实SDK数值错误未取得，不填0或编造。

构建部署复现使用原有脚本，私有CLI输出不读取，不登录/强签：

```bash
env -u DEVECO_CLI_AUTH_SOURCE -u DEVECO_CODE_AUTH_DIR DEVECO_HOME="/Applications/DevEco-Studio.app/Contents" PATH="/Users/zane/.local/share/fnm/node-versions/v22.23.2/installation/bin:/usr/bin:/bin:/usr/sbin:/sbin" DEVECOCLI_BIN="/Users/zane/.local/share/fnm/node-versions/v22.23.2/installation/bin/devecocli" CAPTURE_HOST_ONLY=1 RUN_CMD='/bin/bash scripts/dev-run-mac.sh --device 127.0.0.1:5555 --emulator "Mate 90 Pro" --product default --no-emulator' /bin/bash scripts/capture-test-log.sh m2-token-save-fix-build-deploy-reproduce
```

本轮host/元信息/页面观察的复现入口（均需使用既有Node路径；不自动重做真实API）：

```bash
CAPTURE_HOST_ONLY=1 RUN_CMD='DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" node --test entry/src/test/run-host-tests.cjs' /bin/bash scripts/capture-test-log.sh m2-token-save-fix-host-reproduce
CAPTURE_HOST_ONLY=1 RUN_CMD='swift .cache/token-save-fix-pdf-meta.swift' /bin/bash scripts/capture-test-log.sh m2-token-save-fix-meta-reproduce
CAPTURE_HOST_ONLY=1 RUN_CMD='node .cache/token-save-fix-observe.cjs' /bin/bash scripts/capture-test-log.sh m2-token-save-fix-observe-reproduce 1m 127.0.0.1:5555
```

## 流程自审与剩余前提

实际初build调用 **1/10**，成功前有BUILD_ATTEMPT标记；脚本预检未build但也先发了attempt1，纠正名称后仍attempt1，不计成编译重试。US1 **2/3**、US2 **0/3**，未超过限制。第二次US1有正确的 `[VERIFY_UI_CALL] story=US1 attempt=2 freshStart=true`。**首次US1漏发前置VERIFY_UI_CALL审计行，是本轮流程偏差**，不能事后补称已满足；无超次数违规。初始化CODE_MODIFIED与PHASE2_SKIPPED已输出，code_modified始终false，无per-story build、无Phase2或最终修复。

下一步须由**本人仅在已部署的应用密码框重新填写并保存**，不把秘密给聊天、shell或agent；观察新版本的明确状态/错误阶段及数值code后，才能判定实际保存。本轮不会等待或引导提交秘密到对话。真实Asset独立别名测试仍需要合规设备测试执行路径；若论文未在设备，由本人手动拖入后再经系统Picker选择，不能由agent重试既有禁止写入。真实服务仍须在生产已配置、逐件确认、空闲slot及免费额度前提下最多一件任务；任何前提未满足继续 **INCOMPLETE**。
