# 启动与日志脚本

本目录提供本机使用入口；不配置 Git、不登录账号、不接受协议、不卸载或清数据。需要已有 Bash 3.2+（Windows 使用 Git for Windows）、Node、Git、devecocli 与仓库批准的 DevEco 工具链，不安装升级依赖。

## 启动入口

```bash
scripts/dev-run.sh --help
scripts/dev-run.sh
scripts/dev-run.sh --emulator 'Mate 90 Pro' --product default
scripts/dev-run.sh --device '<serial>' --no-emulator --product default
scripts/dev-run.sh --device '<serial>' --emulator '<完整实例名>' --product default
```

```bash
scripts/dev-run-mac.sh --help                 # macOS 专用（本机开发用）
scripts/dev-run-mac.sh --emulator 'Mate 90 Pro'
scripts/dev-run-mac.sh --device '127.0.0.1:5555' --no-build
```

`dev-run-mac.sh` 与 `dev-run.sh` 相互独立：流程一致（设备/模拟器 → 登录预检 → 许可预检 → 启动并等待就绪 → 签名合成 → 构建 → 安装运行），但仅面向 macOS，且

- **登录预检**：`devecocli auth status` 必须含 `Current user:` 才继续，否则提示 `devecocli auth login`（脚本不代为登录）；
- **模拟器许可预检**：先只读检查本机 `.emu_config` 的 `HarmonyOS_SDK_Agreement`（`agree`/未接受/未知），启动后还会识别 CLI 的 `license agreements are not accepted` 文案并给出 `devecocli emulator license` 指令（脚本不代为接受协议）；
- 目标选择用 `device list` / `emulator list` 的 `--format json`（实例名含空格安全），不用表格切分；
- **不做任何 Git 写操作**（不 `checkout`、不设置 `hooksPath`）；模板脏、已暂存或含签名时直接停止；
- 工具原始输出只落 `.local/mac-run/`，终端只输出阶段、RC 与类别（失败时可查该目录定位）；模板在退出时按字节恢复并核验；
- JSON 清单解析容忍 CLI 的尾部版本提醒（`New version … available, run \`devecocli update\` to upgrade`，`postAction` 追加在 stdout），其余任何尾随文本仍按畸形清单失败关闭；同时对该 CLI 调用关闭版本检查（`DEVECO_CLI_DISABLE_UPDATE=check`、`DEVECO_CLI_SKIP_VERSION_CHECK=1`）；
- 登录失败时若继承到 `DEVECO_CLI_AUTH_SOURCE`/`DEVECO_CODE_AUTH_DIR`（DevEco Code 环境变量），会额外提示其可能改变登录解析，并打印实际使用的 CLI 路径；
- **已知故障（2026-10-14 实测）**：CLI 长时间停在 `Installing artifacts to device <serial>...` 时，通常是设备侧 hdc 会话停摆——`hdc file send` 一直不传字节（目标目录为空、设备 `shell` 仍可用），与实例反复启停/重启 hdc server 有关。恢复：先 `devecocli emulator stop '<name>'` 再 `start`（必要时 `hdc kill` 让 server 重建），然后重跑脚本；本脚本的 `run` 阶段不设内置超时（首次安装可能较慢），停摆需人工中止（Ctrl-C，脚本会还原模板）。重启后实测传输 100 KB 用时 5 ms。

隔离回归：`TEST_BASH=/bin/bash node --test scripts/tests/dev-run-mac.test.cjs`（Homebrew Bash 同理；12 例，覆盖启动锁定、复用运行中实例、登录/许可阻断、清单畸形、尾部版本提醒容忍与未知尾随文本失败关闭、`--no-emulator`、JSON5 签名缓存复用、构建失败不安装与模板恢复）。

```bat
scripts\dev-run.cmd --help
scripts\dev-run.cmd --emulator "Mate 90 Pro" --product default
```

默认只自动选择唯一活动设备；多个活动设备要求显式指定。无活动设备时采用 JSON 清单第一项模拟器，没有实例则停止，不创建/改名。`--emulator` 优先于其他活动设备；双参数必须能证明是同一实例，否则启动前停止。`--device` 找不到时不启动不相关模拟器。

`--no-emulator` 不启动停止态实例，运行态可用。`--no-build` 明确跳过构建，仍需目标/签名条件并使用已有产物，不能当作构建证据。`--force-sign` 仅用户显式要求时强制生成，本轮验证不用。`-h/--help` 无副作用。

环境变量保留 `EMULATOR_NAME`、`PRODUCT`（默认 `default`）、`DEVECOCLI_BIN`（可执行文件整体路径，不是带参数的命令字符串）；选项覆盖前两项。产品贯穿签名、缓存、build、run；未知产品停止。run 始终带 `--skip-build --product <product> --device <锁定 serial>`，构建失败不安装。

设备/模拟器目标选择与就绪等待：`dev-run.sh`（提交版）按 CLI 表格文本解析；`dev-run-mac.sh` 用公开 JSON 清单（schema 不符即按阶段停止：`设备清单 JSON 无效（阶段: device list）`），实例名含空格安全。两者都在启动后核验同一 serial，就绪等待最多 240 秒；`dev-run-mac.sh` 每次工具调用使用独占输出文件，本轮链路继承旧描述符的后代进程无法污染后续调用读取的文件。未知安装错误立即停止，只有已识别临时连接故障最多 3 次；授权/许可/身份冲突不重试，不代为登录或接受协议。

> 状态说明（2026-10-14）：`dev-run.sh` / `dev-run.cmd` 均已恢复到提交版；跨平台重写中仍有效的取证基建（`dev-run-support.cjs`、重写后的 `capture-test-log.sh`）随本次提交入库，面向已回退实现的 86 例 `dev-run.test.cjs` 已移除（备份在仓库外，历史见 `spec/dev-run-portability/`）。macOS 本机开发请用 `scripts/dev-run-mac.sh`（独立回归 `scripts/tests/dev-run-mac.test.cjs`）。

需要启动实例时，脚本先跑一次只读的系统镜像核对（`devecocli emulator image list --all --format json`，约 10 秒，含网络）：目标 device type 与 OS 版本在清单中明确标记未下载时立即 `emulator-image-missing` 停止，不试着启动（本机实测约 32 秒停止，对比此前 240 秒超时且原因不明）；查询失败、超时或字段不认识时只提示“未能确认”，继续原有启动路径，不新增阻断。启动后 CLI 仍可能“已拉起但未进入 hdc”而退出码为 0，脚本保持最多 240 秒就绪等待，超时信息附带 `start-diagnostic=emulator-not-joined-hdc` 说明，不把 CLI 文案当就绪证据。

**模拟器前置（人工，脚本不代办）**：系统镜像不随 DevEco Studio 分发（`Contents/tools/emulator` 只有引擎），需要本机先接受协议并下载：

```bash
devecocli emulator license            # 或 devecocli emulator license accept
devecocli emulator image download --device-type phone --os-version 'HarmonyOS 7.0.0(26.0.0)'
```

未下载镜像时 `~/.Huawei/Emulator/deployed/` 里的实例只是配置桩，`emulator start` 会启动引擎但无法引导，任何脚本都无法让其进入 hdc。

Windows 包装（提交版 `dev-run.cmd`）用 `where git` 推导 Git Bash、标准安装位置备选，不使用 PATH 的 `bash`，显式拒绝 System32 WSL 入口，原样转发 `%*` 并返回 `.sh` 真实退出码；保持 ASCII/CRLF。`where git.exe` 推导、延迟展开关闭、`cygpath` 转 native 路径与 batch 环境槽参数分派属于未提交的跨平台重写，未在本机/原生 Windows 复验（2026-10-14 与原 `dev-run.sh` 一并回退）。

cmd.exe 本身会解释调用者输入的 `%VAR%`；需要逐字百分号等复杂数据时优先从 Git Bash 调 `.sh`，按当前 Shell 规则引用。本机只跑了 macOS 上的 Windows 分派/源码合同测试，不能宣称原生 Windows 完整链路已通过。

## 模板、缓存与恢复

`build-profile.json5` 必须是已跟踪且工作区/index 均无改动的无签名模板；签名残留、未知产品、既有 `.local/build-profile.template.bak` 或 `.local/dev-run.lock` 都停止。脚本不 checkout、提交、设置 hooksPath，不覆盖用户编辑。

缓存仅在 gitignore 的 `.local` 内。新缓存名 `signed-v1-<identity>.json5`：identity 为实际模板 SHA256 与产品的组合摘要，不以 HEAD 哈希代替当前模板。只在完整模板形状、产品签名关联与材料路径存在时复用，证书是否有效仍需真实构建/安装验证。旧 default 缓存可在实际字节 Git blob id 与 unsigned 模板一致时内部迁移，旧文件不删；不匹配则常规生成，不盲用。

没有可用缓存时内部预检 `auth status` 的退出与已知完整格式，再常规 `signature generate --product`。不执行自动登录、协议接受或强签。真实私有配置、账号和证书不得读入 AI 上下文、公共证据或 Git；所有 CLI stdout/stderr 留独占私有运行目录，公共输出只有阶段、RC 与类别，不输出私有原文。

跨平台独占目录锁 `.local/dev-run.lock` 内含随机 `owner`、本轮 `template.bak` 和原始/当前摘要。EXIT/INT/TERM 先等待终止本轮 CLI 进程树，再恢复并核验原始字节，成功后才清本轮文件并报完成。POSIX 使用独立进程组，忽略中断的后代有界强制结束；Windows 对本轮 PID 使用系统 `taskkill.exe /t /f`，原生 Windows 仍待复验。模板或备份被外部改、写入/核验失败时非零，保留备份和锁，不假报恢复；未知遗留不自动“清陈旧锁”。SIGKILL/断电无法保证 trap，下次必须停止供人工检查。

恢复失败时由人类在本机核对所有权、比较当前编辑和备份、保留两者后决定恢复；不要让 AI 打印文件内容，不直接删除锁/备份重跑。工具原始输出可能含秘密，不用于公共排错。

## 日志入口

```bash
scripts/capture-test-log.sh <scope> [window] [device]
CAPTURE_HOST_ONLY=1 RUN_CMD='node --test scripts/tests/dev-run-mac.test.cjs' scripts/capture-test-log.sh mac-host
RUN_CMD="scripts/dev-run.sh --emulator 'Mate 90 Pro' --product default" scripts/capture-test-log.sh portability-mac 10m 'Mate 90 Pro'
```

最后一条会操作真实目标，只能在单独批准的真实验证阶段执行。阶段 4 未执行；阶段 5 已唯一调用一次，结果见下方真实验证记录。

保留 `RUN_CMD`、`BUNDLE`（默认 `com.example.shuvi`）、`KEYWORD`、`DEVECOCLI_BIN`。先运行显式可信 `RUN_CMD`，再抓当前目标设备日志；`CAPTURE_HOST_ONLY=1` 明确跳设备，不自动把无设备当 host-only。空 device 数组在 Bash 3.2 安全，不需要 `sha1sum`/jq/flock/GNU 工具。

`.cache/test-logs/<日期>-<scope>-<commit>[-序号]/` 采用原子独占 mkdir，旧目录不覆盖；`meta.txt` 分开 cmd/log RC、platform/shell/Node、脚本 SHA256、提交/dirty/worktree 指纹、模板状态；索引有界独占追加。指纹用 Node crypto（包含未跟踪公开文件摘要），不输出 diff 私有内容。原 RUN_CMD 不公开，存命令摘要。

原始流临时在 `.local/capture-*`，只清本轮所有目录；公共 `host.log`、`device.log`、`log-diagnostic.log` 做保守秘密标记拦截，`filtered.log` 由已处理设备日志过滤。不得把任意私有输出命令交给 RUN_CMD；内容筛查不是通用保密保证。签名/账号操作只能经 dev-run 的私有阶段。

退出优先级：命令非零 > 日志非零 > 元数据/索引失败；全部成功才 0。host-only 的 log 为 `not-run`/`skipped-host-only`，不能算设备日志通过。不要沿用旧脚本“总退出 0”的判断。

## 隔离回归与平台复验

```bash
TEST_BASH=/bin/bash node --test scripts/tests/dev-run-mac.test.cjs
TEST_BASH=/opt/homebrew/bin/bash node --test scripts/tests/dev-run-mac.test.cjs
```

测试创建自己拥有的临时 Git fixture，复制脚本、假 CLI、合成非密钥模板，隔离 HOME/USERPROFILE；不执行真实工具、不访问真实 `.local`、设备或账户。`DEVRUN_TEST_PARENT` 可指定已存在的隔离父目录；`DEVRUN_EVIDENCE` 必须指向新独占已创建目录，保存 cases/versions/SHA/源码快照/diff，终端输出另存 `test.log` 和真实 `exit.txt`，不复用已有证据目录。

阶段 4 macOS Bash 3.2/5.3 各 76/76 的路径及失败轮次见 `spec/dev-run-portability/implementation-report.md`。阶段 5 发现 CLI 将非空 `DEVECO_CLI_DEBUG=0` 当作调试启用，已在工具子进程环境移除 `DEVECO_CLI_DEBUG` 和 `DEBUG`，不截取或放宽 JSON；新增两项回归先 0/2，再完整两 Bash 各 78/78，证据在 `.cache/test-logs/dev-run-portability-stage5/{debug-red-bash32,fixed-bash32,fixed-bash53}/`。该 harness 使用 POSIX 假 CLI shebang 与进程组信号，尚不宣称原生 Windows 可直接运行同一测试命令。

2026-10-14：`dev-run.sh` / `dev-run.cmd` 恢复提交版，macOS 能力迁入 `scripts/dev-run-mac.sh`。macOS 套件两 Bash 各 12/12，证据 `.cache/test-logs/2026-10-14-dev-run-mac-bash32-2ac9098-4/`、`…-bash53-2ac9098-4/`（meta 记录脚本 SHA256）；修复前对照见 `.cache/test-logs/2026-10-14-dev-run-fix-red-prefix/`。

Windows 原生待复验：在 Git for Windows 已安装机器，从 cmd 执行上面的 `--help` 包装，再在单独授权下执行 `--emulator "Mate 90 Pro" --product default`（仅该实例确实存在且获准时）；Git Bash 对照执行 `.sh` 相同参数。分别记录带空格项目/CLI 路径、完整实例名、产品/serial、非零退出、模板字节恢复、恢复锁和日志；故障用无秘密隔离项目，不使用真实证书充当 fixture。Windows CI 隔离 harness 适配需另补原生证据，不把 macOS 合同测试当 Windows 实机证据。

## 阶段 5 真实验证

2026-10-13 的唯一正式调用（经 capture 保存命令后日志）：

```bash
RUN_CMD="scripts/dev-run.sh --emulator 'Mate 90 Pro' --product default" /bin/bash scripts/capture-test-log.sh dev-run-portability-stage5-mac 10m 'Mate 90 Pro'
```

脚本 RC 1、capture RC 1、设备日志 RC 1；公开错误 `target-readiness-timeout (240 seconds)`。已请求启动唯一获准实例，但结束时四实例仍 stopped、无活动 device，未锁定 serial；实际 build/run/signature 次数均 0。未新增 signed HAP，也没有本轮安装、启动或应用进程证据；既有 unsigned HAP 不算本轮产物。模板前后 SHA256 均 `36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`，独立确认无签名模板、锁/备份不存在、Git 配置指纹不变。未重试、未扩权或读取私有原文。

权威结果 **INCOMPLETE**。公共证据在 `.cache/test-logs/2026-10-13-dev-run-portability-stage5-mac-2ac9098/` 与 `.cache/test-logs/dev-run-portability-stage5/real-mac/`，完整说明见 `spec/dev-run-portability/verification-report.md`。Windows 原生、旧 M1 UI/知识库业务均未验证；此结果不替换旧 M1 INCOMPLETE。

## 2026-10-14 真实复验记录（镜像前置缺失）

```bash
RUN_CMD="scripts/dev-run.sh --emulator 'Mate 90 Pro' --product default" /bin/bash scripts/capture-test-log.sh dev-run-fix-real-mac 10m
```

脚本 RC 1；公开错误 `emulator-image-missing: phone HarmonyOS 7.0.0(26.0.0) has no downloaded system image; download it first (devecocli emulator image download, see scripts/README.md)`，在启动前停止（四实例仍 stopped、serial 仍 null），不再进入 240 秒就绪等待。模板前后 SHA256 均 `36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`，`.local/` 无锁与备份残留。capture 的 log 阶段仍为 `log-failed`（本机无活动设备，如实记录）。该次未进入签名/build/run；镜像下载后需另行做端到端复验。证据在 `.cache/test-logs/2026-10-14-dev-run-fix-real-mac-2ac9098/`。

同日镜像下载完成后复验（`dev-run-fix-real-run2-2ac9098`）：`dev-run.sh` 走到 `Target locked: serial=127.0.0.1:5555` 后停在 `login-not-confirmed`；随后由 `scripts/dev-run-mac.sh` 完成端到端：登录预检通过、锁定 serial、复用签名缓存、构建成功、安装启动 CLI 退出码 0，设备侧 `bm dump -n com.example.shuvi` 可见该包且 `ps -A` 有 `m.example.shuvi` 进程，模板 SHA256 前后一致。capture 记录 `status=ok`、cmd/log RC 均为 0，证据 `.cache/test-logs/2026-10-14-dev-run-mac-e2e-2ac9098-4/`（首次成功 `…-3/`）。启动全过程每 5 秒采样清单 JSON 均合法，见 `.cache/test-logs/2026-10-14-dev-run-fix-boot-probe/`。

## 钩子与 CI

启动脚本不设置 Git hooks。人类另行批准后可手动执行 `git config core.hooksPath scripts/hooks`；这是独立 Git 写操作，本阶段未执行。现钩子源码旧注释仍称自动配置，以本文与 AGENTS 第六节为准。

CI 保持既有 `ci-windows.cmd`、CLT_HOME/JAVA_HOME、`--no-install` 接口，不签名、不部署、不变更平台基线。真实 Mate 90 Pro build/run 与 Windows 实机是独立验证证据。
