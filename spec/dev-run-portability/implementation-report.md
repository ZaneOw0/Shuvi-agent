# 实施报告：dev-run 跨平台可用性

## 范围与状态

2026-10-13，阶段 4 实施完成，最终状态 **COMPLETED**（仅实施范围）。T001–T012 完成；T013–T014 留给一次阶段 5，保持未勾。未执行真实 build/run/signature/auth、设备或模拟器操作、verify_ui；未读取真实 `.local`、账户或证书。只使用无秘密的隔离假 CLI fixture。应用源码、权限、依赖、SDK 与旧 M1 证据不变；不写真实 Git 配置、index 或提交。

## Setup（T001）

- 工程根 `build-profile.json5` 与 `oh-package.json5` 有效，不 scaffold。
- 原有工作区：`spec/feature.json` 已修改，`spec/dev-run-portability/` 未跟踪。保留父阶段变更；脚本与 AGENTS 无已有 diff。
- 系统 `/bin/bash` 3.2.57；`/opt/homebrew/bin/bash` 5.3.20；Node v22.23.2；devecocli 1.3.4。未安装或升级。
- 原 `.sh` 均 LF；`.cmd` ASCII/CRLF（53 行）。
- 原 dev-run SHA256：`da9dc81280f5140097d3734a156ea3e0c150eabbb733b50fd9f115a7ea182b3c`。
- 原 cmd SHA256：`05d860ccf4ccbbef8968449cdabf945a972887ca5bb5cd536042eda5ad8d80b4`。
- 原 capture SHA256：`60958d19d8e35a01afeb1c2353a86dcbee40f7cd6ca3943ba9d1beeba09b2496`。
- 公共模板 SHA256：`36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`。
- 已完整阅读 spec/plan/tasks/AGENTS 和现有启动、日志、钩子脚本。钩子旧注释仍描述自动设置，本轮仅修改获准 AGENTS 第六节和 README，不扩展钩子源码。

## 公开接口依据

仅调用 CLI `--version` 与各子命令 `--help`。读取已安装 `@deveco/deveco-cli-common/dist/cli.js` 公开代码（不是运行配置）：device list/view 是 `{name, serial, kind, deviceType?, osVersion?}`，无 status 字段；emulator list 是 `{name,status:running|stopped,serial:string|null,deviceType:string|null,osVersion:string|null}`。running 可能暂无 serial，需等待清单与 view 共同核验。auth status 无 JSON，源码输出单行 `Current user: <name>` 或 `Not logged in`；必须成功退出且完整匹配已知输出，不公开账户文本。

## 分阶段结果

| 阶段 | 任务 | 结果 |
|---|---|---|
| Setup | T001 | 完成：工程/工具/源码/行尾/已有修改核对 |
| Foundational | T002–T003 | 完成：一个集中隔离入口、一个内置库辅助；fake CLI 无秘密、参数观测、独占临时项目 |
| US1 | T004–T005 | 完成：严格 JSON、默认唯一设备/首模拟器、显式优先、双参一致、状态/view 核验、240 秒等待、serial 固定 |
| US2 | T006–T007 | 完成：实际模板 SHA256 + product cache、脏/index/残留拒绝、独占锁/所有权备份、byte restore、中断/恢复失败保护、取消 Git 写、私有输出 |
| US3 | T008–T010 | 完成：ASCII/CRLF cmd、显式 Git Bash、native Windows CLI 分派合同、capture 先命令后日志/host-only/非零传播/独占目录与索引 |
| Polish | T011–T012 | 完成：两套 Bash 回归、syntax 与落盘，AGENTS 仅第六节、README 对齐 |
| Verification | T013–T014 | 本阶段跳过；不声明真实构建/签名/部署成功 |

## 源码文件与实现细节

- 修改 `scripts/dev-run.sh`：Bash 3.2 语法，固定产品与 serial；目录锁 `.local/dev-run.lock`、`owner`、`template.bak`、原始/当前 SHA；成功提示在 EXIT 还原核验后。INT/TERM 转发子进程，SIGKILL 后停止待人工恢复。安装未知错误立即停止，仅已识别临时连接错误最多 3 次。
- 新增 `scripts/dev-run-support.cjs`：内置库 JSON/schema、数据式 JSON5 子集解析（不 eval）、缓存/模板检查、SHA256、Windows 分派、日志元数据。检查材料路径存在不是证书有效性证明；实际有效性由下一阶段构建/安装确认。
- 修改 `scripts/dev-run.cmd`：关闭延迟展开，不 CALL 重解析 `%*`；`where git.exe` 推导/标准位置查 Git Bash，拒绝 System32，返回原 RC。保持 ASCII/CRLF。
- 修改 `scripts/capture-test-log.sh`：兼容原 scope/window/device/RUN_CMD，新增 `CAPTURE_HOST_ONLY=1`；不用 GNU checksum/空数组展开；私有原始流在 `.local/capture-*`，公共输出保守筛除敏感标记，原 RUN_CMD 不写 meta，只存 SHA256。
- 新增 `scripts/tests/dev-run.test.cjs`：一个集中入口，76 个用例；临时项目仅本轮 mkdtemp 所有，HOME/USERPROFILE、CLI 隔离。允许 fixture 内 git init/add/commit（命令级 -c 身份，不 Git config）；不是对真实仓库的 Git 写。
- 新增 `scripts/README.md`，修改 `AGENTS.md` 第六节；更新本报告及 `tasks.md`。父阶段 `spec/feature.json`、spec/plan 不改。

## 真实落盘证据

全部路径相对工程根：`.cache/test-logs/dev-run-portability-stage4/`。每回归目录有 `test.log`、`exit.txt`、`cases.json`；最终和 semantic-red 另有 `sources/` 快照，最终含 `versions.json`、`source.diff`。

| 目录 | 结果 | 含义 |
|---|---|---|
| `foundation` | 1/1，exit 0 | help 无副作用 |
| `us1-red` | 6 pass / 14 fail，exit 1 | 旧名称/显式/错误处理失败 |
| `us1-green` | 20/20，exit 0 | JSON 目标修复 |
| `us2-red` | 0 pass / 19 fail，exit 1 | 包括旧 Git config 清理断言；不单独作为每项业务失败证据 |
| `us2-green-1` | 39/39，exit 0 | 签名安全实现 |
| `us3-red` | 2 pass / 8 fail，exit 1 | Windows/capture 原入口失败 |
| `us3-green-1` | 10/10，exit 0 | 初轮入口/日志修复 |
| `semantic-red` | 3 pass / 24 fail，exit 1 | 当前业务断言对只读 HEAD 旧脚本运行，移开 cleanup 断言干扰；含执行旧源码 SHA/快照 |
| `green-bash32`、`green-bash53` | 各 71 pass / 1 fail，exit 1 | 收尾发现 capture 私有父目录 check-then-mkdir 竞态；保留失败，不弱化断言 |
| `complete-bash32`、`complete-bash53` | 各 72/72，exit 0 | 含 mkdir 并发竞态修复 |
| `delivery-bash32`、`delivery-bash53` | 各 75/75，exit 0 | 另加日志写入/索引失败优先级 |
| `process-tree` | 7/7，exit 0 | CLI 子进程组中断/恢复专项 |
| `accepted-bash32` | **76/76，exit 0** | 最终系统 Bash 3.2.57；含已就绪且忽略 TERM 的嵌套 CLI 子进程 |
| `accepted-bash53` | **76/76，exit 0** | 最终 Homebrew Bash 5.3.20；同源码快照 |
| `static` | syntax/scope exit 0 | 两 Bash `-n`、Node `--check`、`git diff --check`、应用/平台/旧证据未改；工具/help 落盘 |
| `delivery-audit` | exit 0 | 75 用例轮次 syntax/行尾/可执行位/文档审计，作为当时证据保留 |
| `closure-audit` | exit 0 | 最终同源码 syntax/行尾/可执行位；AGENTS 第六节外逐字相同，公共模板 SHA 未变；最终文档 SHA/diff/status/证据清单 |

中间扩展轮次 `full-bash32-1`（66/66）、`final-bash32/final-bash53`（各 69/69）也保留，最终结论仅采用 `accepted-*`。

### 最终脚本 SHA256（Node crypto）

| 文件 | SHA256 |
|---|---|
| dev-run.sh | `24bd2b4a2daee4e4d26f4af2f1b13d999bebe50e81f2c811c1fd1af535dfe1fd` |
| dev-run.cmd | `cc182080c9e9a850e0246c178ba9b396c157449c37078824f96988a3c36f3bea` |
| dev-run-support.cjs | `e69ade9dde4789b795d2104c92bd99fc2473bf608b048aebfec2755aea1b8878` |
| capture-test-log.sh | `9ce0bc2acdda0736175d65fad4389493c7c180960fa524c79bc9a8528a089526` |
| tests/dev-run.test.cjs | `8ffda9fca3cc7dd12554c726640a3f6d30391dd21a85c90bbbe3f2b18b197ec7` |

两套最终 `cases.json` 含相同 SHA，`sources/` 能复查执行字节。正式交付审计另存最终文档 SHA、状态与 diff；报告自身不递归包含自己的 SHA。

公共模板仍为 Setup SHA；`closure-audit/checks.log` 保存最终 README/AGENTS/脚本 SHA256，并已核验 `.cmd` ASCII/CRLF、`.sh` LF、dev-run 可执行位。报告与任务文件 SHA 位于 `closure-audit/evidence-manifest.json`。

收尾自审补充：public log 写入失败不再由 `set -e` 抢先退出，独立记录 output-failed，仍先返回 RUN_CMD 原 RC；索引失败也不能吞掉命令失败。新增 3 个故障用例且两套 Bash 都通过，没有弱化原断言。最后补嵌套 CLI 进程组取消：POSIX 对本轮独立组转发并有界强制终止；Windows 只对本轮 PID 使用系统 `taskkill.exe /t /f`，原生执行仍未覆盖。76 个用例覆盖 foundation 1 / US1 28 / US2 32 / US3 15（实际 TAP subtest 计数）。

### 复现命令

```bash
TEST_BASH=/bin/bash node --test scripts/tests/dev-run.test.cjs
TEST_BASH=/opt/homebrew/bin/bash node --test scripts/tests/dev-run.test.cjs
```

保存逐用例证据时，先独占创建新目录，再设置 `DEVRUN_EVIDENCE=<该绝对目录>` 和 `DEVRUN_TEST_PARENT=<已存在隔离父目录>`；stdout/stderr 存新 `test.log`，真实 RC 存 `exit.txt`。目录已有则不要重用。测试不调用真实 devecocli。

## 偏差与明确限制

- 采用 data-only JSON5 子集，支持当前模板、CLI 输出、注释/单引号/未引号 ASCII key/尾逗号；特殊扩展语法失败关闭，不新增解析依赖。
- Windows batch CLI 使用环境槽及 `/v:off`，双引号/控制字符拒绝并提示用 native CLI；`%`/`!`/`&` 等分派合同已测试，但 **macOS 没有执行 cmd.exe**。用户在 cmd 输入的百分号仍遵循 cmd 原生展开语义，Git Bash/native CLI 是更复杂参数入口。
- 集中回归 harness 使用 POSIX 假 CLI shebang 与进程组信号，当前不宣称它可原生在 Windows 执行。Windows 复验按 README 的包装/工具路径/退出与恢复合同，在原生环境提供证据；不是把同一 Node 命令误称 Windows 测试入口。
- 原始 build/run 输出与 auth/signature 一并私有化：公共证据仅阶段、目标、产品、RC 和类别，不直接重放工具 stdout。后续阶段据实际产物和运行态验证，不能仅凭“CLI exit=0”宣称应用已启动。
- 旧 default cache 只在实际模板 Git blob id 一致、完整 unsigned shape 与 product 匹配、材料路径存在时内部迁移；不展示/删除旧 cache。
- 不自动处理未知锁/备份；恢复时若模板或备份被外部修改，保留备份/锁并非零，人工判定数据，不覆盖用户编辑。SIGKILL/断电不能保证 trap。
- 钩子原源码注释仍有旧自动设置描述；获准范围不包括修改钩子，README/AGENTS 已明确覆盖为人工单独授权。

## 交接阶段 5

无未完成实施任务或依赖阻塞。真实登录/许可/缓存与证书有效性、真实 signed 构建/安装/app 状态 **尚未验证**；Windows 原生 Git Bash/cmd.exe **未实测**。阶段 5 仅一次经 `scripts/dev-run.sh --emulator 'Mate 90 Pro' --product default` 执行内部同产品 build/run（serial 固定），成功构建才安装，并检查模板恢复及产物/运行证据。遇认证/许可/身份或恢复阻塞必须停止，不登录、不接受协议、不强签、不卸载/清资料，不访问秘密到上下文；不裸 build、不 UI 五故事验证。
