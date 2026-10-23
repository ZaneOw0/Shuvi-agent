# 阶段 5 权威验证报告：dev-run 跨平台可用性

## 2026-10-14 更新（回退与迁移）

- 依用户要求，`scripts/dev-run.sh` 与 `scripts/dev-run.cmd` 已恢复到上一提交（`2ac9098`）的提交版；本报告所述跨平台重写中的启动器改动**不再位于这两个文件**。
- macOS 本机启动迁入独立脚本 `scripts/dev-run-mac.sh`（登录预检、模拟器许可预检、JSON 清单、私有工具输出、模板按字节恢复），回归 `scripts/tests/dev-run-mac.test.cjs` 两套 Bash 各 12/12。
- 跨平台重写中仍有效的取证基建（`scripts/dev-run-support.cjs`、重写后的 `scripts/capture-test-log.sh`）保留入库；面向已回退实现的 86 例 `scripts/tests/dev-run.test.cjs` 已移除（备份在仓库外临时目录）。
- 真实端到端结果（2026-10-14，`dev-run-mac.sh`）：锁定 `127.0.0.1:5555`、复用签名缓存、构建成功、安装启动 CLI 退出码 0，设备侧确认 `com.example.shuvi` 已安装且进程存在；证据 `.cache/test-logs/2026-10-14-dev-run-mac-e2e-2ac9098-4/`。已知故障：CLI 停在 `Installing artifacts...` 属设备侧 hdc 会话停摆，恢复=重启实例后重跑（见 `scripts/README.md`）。
- 本报告此前记录的阶段 5 结论（INCOMPLETE）作为历史保留，不因本次迁移而改为通过；Windows 原生仍未实测。

## 最终结论

**INCOMPLETE**，2026-10-13。本报告是本功能阶段 5 唯一正式验证结果，采用 Phase 1 实际执行结果；没有 UI 或 Phase 2。脚本隔离回归通过不代表真实签名、构建或部署完成。

唯一真实脚本调用为 `scripts/dev-run.sh --emulator 'Mate 90 Pro' --product default`，返回 **RC 1**，公开错误为 **`target-readiness-timeout (240 seconds)`**。已请求启动现存获准实例，但未核验到就绪 serial，后续签名、build、run 均未进入。结束后模拟器清单仍为四个 stopped、serial 均 null，device 清单为空。未重试、未切换目标、未接受协议或登录。

模板字节前后完全一致、恢复锁/备份不存在、真实仓库 Git 配置指纹不变。没有本轮 signed HAP、安装、启动或应用进程证据。旧 M1 INCOMPLETE 不变；本报告不验收旧 M1 业务。Windows 原生 cmd.exe/Git Bash 实机未测。

## 绑定与流程

- `CONFIG_ROOT`：通过 `os.homedir()` 动态解析为 `/Users/zane/.local/share/deveco/`，已读取 `specs/commands/spec-verify.md`。
- `PROJECT_ROOT`：`/Users/zane/DevecostudioProjects/Shuvi-agent`。
- `Confirmed_Feature_Dir`：`/Users/zane/DevecostudioProjects/Shuvi-agent/spec/dev-run-portability/`，直接使用用户指定目录，未回退旧 feature。
- `Verification_Scope`：**build-only**，来自本次委派与 `tasks.md` 的 `<!-- verification_scope: build-only -->`。
- 已读取 spec、plan、tasks、implementation-report、AGENTS 第六节、scripts README、main/cmd/helper/capture；加载 deveco-cli skill。
- 按任务要求只通过仓库脚本执行内部 build→run，不裸 build、不 IDE、不 `--no-build`。真实脚本在前置目标就绪阶段停止，因此不能单独补跑 run。
- 没有 `.ets` 修改；`arkts_check` 跳过，不对非 `.ets` 调 checker。没有应用编译错误修复。

## 逐步结果

| 阶段/步骤 | 执行状态 | 结果与依据 |
|---|---|---|
| 资料/路径/scope 初始化 | executed / PASS | 已绑定本目录与 build-only；无 UI 用例生成 |
| 安全前置审计 | executed / 发现脚本缺陷 | 模板/锁/Git 均可用；生产 invoke 捕获的 JSON 受到调试行污染；尚未调用真实脚本 |
| 脚本限定修复 | executed / PASS | 去除子进程调试变量，新增两项回归；完整两 Bash 各 78/78 |
| 唯一正式脚本调用 | executed / RC 1 | 仅指定 Mate 90 Pro/product default；启动请求后 readiness 超时 |
| T013 内部签名/构建 | skipped / 前置阻塞 | 未核验到 serial；auth/signature/build 次数均 0，无签名有效性或新构建产物证据 |
| T014 内部安装/启动 | skipped / 依赖未满足 | build 未进入；run 次数 0，无安装或应用进程证据 |
| 命令后真实目标日志 | executed / FAILED | capture 的 log RC 1、status=log-failed；device.log 为空，不作为部署证据 |
| 模板/锁/存量保护审计 | executed / PASS | 原始 SHA256 与 unsigned 状态一致，锁/备份不存在，Git 配置不变，其他目标状态未改 |
| verify_ui prep/故事循环/截图 | skipped | scope 为 build-only；调用均为 0；未生成 UI 测试计划 |
| Phase 2 | skipped | build-only，不适用；Phase 1 权威 |
| 报告/文档同步 | executed | 本报告、AGENTS 第六节、README；任务复选框保留供父阶段记录尝试状态 |

**判定**：关键真实 build/deploy 未能执行，故整体 INCOMPLETE，而不是 PASS。脚本 readiness 失败和设备日志失败如实记录；无法从安全公共证据确定更深的模拟器启动失败原因，不臆测许可、账户或 SDK 问题。

## 真实调用与计数

经现有 capture 入口调用，capture 以系统 Bash 3.2 执行，RUN_CMD 内容仅为获准脚本命令：

```bash
RUN_CMD="scripts/dev-run.sh --emulator 'Mate 90 Pro' --product default" /bin/bash scripts/capture-test-log.sh dev-run-portability-stage5-mac 10m 'Mate 90 Pro'
```

| 项 | 实际记录 |
|---|---|
| 调用时间（UTC） | 2026-10-13T14:27:49.948Z 至 2026-10-13T14:32:56.979Z（包含命令后日志） |
| 真实脚本调用次数 | **1**；没有第二次真实调用 |
| script RC / capture RC / log RC | **1 / 1 / 1**；无 signal、无外部审计超时 |
| product / bundle | `default` / `com.example.shuvi` |
| emulator start | 指定实例启动请求已执行；由进入 readiness 循环而非 start-blocked 分支可知 start 命令返回 0，但不代表实例实际启动成功 |
| 锁定 serial | **null / 未获得**，没有假造或替换为其他设备 serial |
| 实际 `devecocli build` 次数 | **0/10**；内部 build 从未进入，无编译重试 |
| 实际 `devecocli run --skip-build` 次数 | **0**，安装重试也为 0 |
| auth / signature / cache-apply | 均未进入，不能声称缓存/账户/证书真实有效 |
| 本轮 installed / launched / process | **无证据**；不把既有应用或 CLI 启动文案当真实部署成功 |
| 目标结束状态 | 四实例仍 stopped、serial null，无活动 device |

流程断言已输出 `[CODE_MODIFIED] initialized code_modified=false`，正式调用前输出 `[BUILD_ATTEMPT] attempt=1/10`。首次前置审计前也曾输出相同预期断言，但该审计未调用真实脚本；两条断言都未对应实际 build。准确构建计数为 0，不按断言数或 fake CLI 用例计数。`code_modified` 仍 false：本轮修复是脚本前置修复，不是 src 中的 Per-Story Verify & Fix。已输出 `[PHASE2_SKIPPED] reason=verification_scope_build-only`。无重试上限违规、无 UI 调用或新的委派。

## 脚本修复与回归

**缺陷**：原 helper 设置 `DEVECO_CLI_DEBUG: '0'`、`DEBUG: ''`。本机 CLI 对前者按非空值判断，生产 `invoke` 的 device/emulator JSON 流出现调试前缀；普通直调 JSON 无此问题。初次安全审计只读清单并失败关闭，没有真实脚本/build/run，也没有启动设备。

**修复**：`scripts/dev-run-support.cjs` 中构建子进程 env 后明确移除 `DEVECO_CLI_DEBUG` 与 `DEBUG`，不改变调用参数、不改父进程环境、不去除 JSON 中任意行、不放宽 schema。新增两项隔离测试，断言变量在工具进程中不存在，覆盖 JSON discovery 与 capture 日志；保留原 76 项要求。

| 证据目录（相对工程根） | 结果 |
|---|---|
| `.cache/test-logs/dev-run-portability-stage5/debug-red-bash32/` | 新增两项在修复前 0 pass / 2 fail，RC 1 |
| `.cache/test-logs/dev-run-portability-stage5/fixed-bash32/` | **78 pass / 0 fail / 0 skipped**，RC 0，Bash 3.2.57 |
| `.cache/test-logs/dev-run-portability-stage5/fixed-bash53/` | **78 pass / 0 fail / 0 skipped**，RC 0，Bash 5.3.20 |
| `.cache/test-logs/dev-run-portability-stage5/final-audit/` | RC 0，两 Bash `-n`、Node `--check`、diff check、LF/ASCII-CRLF、范围/恢复/秘密标记审计 |

各回归目录保留 `test.log`、`exit.txt`、`cases.json`、`versions.json`、`source.diff`、`sources/`；fake 工具仅在自己的隔离临时项目运行，不访问真实账号、缓存或设备。回归复现：

```bash
TEST_BASH=/bin/bash node --test scripts/tests/dev-run.test.cjs
TEST_BASH=/opt/homebrew/bin/bash node --test scripts/tests/dev-run.test.cjs
```

## 产物与恢复

真实调用前后只有既有 `entry/build/default/outputs/default/entry-default-unsigned.hap`，759853 字节，修改时间 `2026-10-12T14:20:24.267Z`，SHA256 `d1cf9040a431cf8d135304b6bfc5a545cd0d01dd41e0057cbc914c0f739b85e3`。前后完全相同，ZIP 可读、含 modules.abc/module.json，仅说明旧文件存在；**本轮没有 signed HAP，新产物摘要不适用，签名有效性未验证**。审计只检查 ZIP 目录与摘要，不读取嵌入签名、密钥或业务内容。

模板 before/after SHA256 均为：

```text
36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7
```

前后 helper 检查均为合法 unsigned default 模板；`.local/dev-run.lock` 与 `.local/build-profile.template.bak` 均不存在，脚本失败路径的 EXIT restore 已成功清理本次锁。没有成功文案，本报告依据独立 hash/模板/存在性检查判定恢复，不用 script RC 代替核验。未自动删除不明锁/备份。

仓库 Git 配置只由内部 Node 计算摘要，不展示内容；before/after 均 `9adac8fc69143ddef7ab1e19e7012944242ff6900ada21f75327e6ec6a3c0f81`。Git 只读检查未改配置、index 或提交。

## 工具、源码和公共证据

本机实际：darwin、Node v22.23.2、devecocli **1.3.4**、DevEco Studio 公共 plist 版本 **26.0.0**、系统 `/bin/bash` **3.2.57**、Homebrew `/opt/homebrew/bin/bash` **5.3.20**。未安装升级工具；不把仓库基线表版本当本轮实测工具版本。

| 执行源码 | 最终 SHA256 |
|---|---|
| scripts/dev-run.sh | `24bd2b4a2daee4e4d26f4af2f1b13d999bebe50e81f2c811c1fd1af535dfe1fd` |
| scripts/dev-run.cmd | `cc182080c9e9a850e0246c178ba9b396c157449c37078824f96988a3c36f3bea` |
| scripts/dev-run-support.cjs | `576a3e7eef59ce4aefb7d42efa459ac3ca480283e9a95e3113aca0f561d71618` |
| scripts/capture-test-log.sh | `9ce0bc2acdda0736175d65fad4389493c7c180960fa524c79bc9a8528a089526` |
| scripts/tests/dev-run.test.cjs | `d7aac441497181c76d5431f9bee7beea8153d61cabf10ce92b2a721de8a446ac` |

正式执行前后上述源码不变；修复后的完整回归与真实调用使用相同摘要。阶段 5 新改 helper/tests，必要同步 AGENTS 第六节/README，新增本报告；没有再次修改 main/cmd/capture。阶段 4 原有修改全部保留，implementation-report 保持历史记录；tasks checkbox 未改。

| 路径（相对工程根） | 内容 |
|---|---|
| `.cache/test-logs/dev-run-portability-stage5/` | 首次只读前置失败的 before/inventory/artifacts/versions/blocked JSON，realScriptCalls=0 |
| `.cache/test-logs/dev-run-portability-stage5/real-mac/` | `before.json`、`after.json`、`inventory-before.json`、`inventory-after.json`、`artifacts-before.json`、`artifacts-after.json`、`versions.json`、`invocation.json`、`window-evidence.json`、`summary.json` |
| `.cache/test-logs/2026-10-13-dev-run-portability-stage5-mac-2ac9098/` | `host.log`、`device.log`、`log-diagnostic.log`、`meta.txt`，真正命令后的目标日志与分层 RC |
| `.cache/test-logs/index.tsv` | capture 自动追加本次行；不改旧证据 |
| `.cache/test-logs/dev-run-portability-stage5/final-audit/` | `checks.json`、`source-hashes.json`、`exit.txt`、`stage5-helper-fix.diff`、`evidence-manifest.json`，文档/脚本/范围/恢复/公共流审计与最终报告摘要 |

capture 元数据：commit `2ac9098`、dirty_files=9、工作区指纹 `4031df0b75d96b7b081636aa27d375eb9d3b5a3e6dca74a00db663faba950e9d`；这是当时执行版本，不代表后来新增报告的状态。命令摘要 `3f428a3c666fde6492c1e4f89970db39dd2fc8772834716649bbca459da7da6e`。device.log 为 0 字节，摘要为空文件 SHA256；日志错误仅内部归类 `tool-failed`，未打开或引用原始诊断文本。

## 秘密、存量与未覆盖

工具原始流由生产 helper 放在本次权限保护的 `.local/dev-run.lock`，capture 原始流在独占 `.local/capture-*`；它们只由脚本内部处理并清理本次所有物，未经 read/grep/截图进入 AI。审计的临时原始清单/窗口流也只在工程外权限 0700 的专属目录处理，正常退出清理。公共 evidence 目录为 0700，公共流只审计 bytes/hash/秘密标记 boolean；未把 device/log-diagnostic 原文读入上下文。模板只在无签名状态检查；没有读取真实签名缓存/证书/账户内容，也没有 auth/signature 调用。

最终公共流未检出签名配置、密码、证书、账户或私钥标记；这是有限保守审计，不宣称通用秘密扫描保证。没有应用截图、UI layout/窗口读取；因 run 未成功，窗口/进程核验明确 skipped。

没有 Git config/checkout/commit/push/merge/rebase；没有直接 hdc；没有 uninstall/cleardata/force-sign/login/license accept；没有创建、改名或操作其他模拟器。其他三目标前后 stopped；本轮没有进入安装与业务交互，未触知识库资料/旧 fixtures，也未运行 96 host 或五故事 M1 UI。无应用、权限、依赖、SDK、旧 M1 契约文件变更；AGENTS 第六节外逐字一致。

**Windows 限制**：通过的只是 macOS 上跨平台分派与包装源码合同，未执行原生 cmd.exe 或 Windows Git Bash 签名/构建/安装；不能宣称两端实机 PASS。**Mac 限制**：真正签名/构建/部署关键步骤仍缺证据，所以本轮整体 INCOMPLETE。停止在当前安全边界，不以延长超时、改目标、假缓存或清数据获得通过。
