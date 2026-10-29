# Implementation Plan: dev-run 跨平台可用性

**Input**：`/Users/zane/DevecostudioProjects/Shuvi-agent/spec/dev-run-portability/spec.md`
**状态**：2026-10-13，阶段 2 设计审核中，未修改脚本、未实际签名/启动。

## Summary

保留仓库脚本作为启动入口，修复结构化目标发现、显式目标优先与固定序列、产品贯穿、独占签名拼装和模板恢复。Shell 使用 Bash 3.2 公共语法；现有 Node 承担 JSON 校验及小型跨平台辅助，不引入 jq 或其他新依赖；Windows cmd 包装仍从 Git for Windows 定位 Bash、不使用 PATH 上可能命中 WSL 的 bash。

隔离回归不调用真实工具或访问私有缓存；真实验证只在 macOS 通过 `dev-run.sh --emulator "Mate 90 Pro" --product default` 构建、安装启动，Windows 相关分支回归与原生 Windows 实机未覆盖分别记录。不改变应用代码或知识库业务验收。

## Technical Context

- **Language/Version**：Bash 3.2+、Windows ASCII/CRLF cmd、Node 内置库 CommonJS；沿用已安装 DevEco/CLI/SDK，不安装升级工具。
- **Primary Dependencies**：已有 Git、Node、devecocli，Bash 常见系统工具；不依赖 jq/GNU sha1sum/flock/readlink -f，不依赖 IDE 菜单。
- **State Management**：显式目标/签名锁/备份所有权/阶段状态，不涉及 ArkUI 或 V1/V2变更。
- **Storage**：运行日志留 `.cache/test-logs`，敏感临时拼装/缓存只在 gitignore 的 `.local`，独占备份保留至还原核验成功。
- **Testing**：Node 自带 test/assert/child_process 的隔离 CLI 回归；本机 `/bin/bash`3.2和Homebrew Bash5.3；Windows后缀/入口参数分支测试，不冒充真实cmd.exe执行。
- **Target Platform**：macOS；Windows Git for Windows + cmd.exe。实际本机目标只Mate90Pro，其余实例不启动。
- **Performance Goals**：保留启动等待最多240秒和有限安装重试，不无界轮询；失败、身份/授权冲突不盲重试。日志/临时空间有清理所有权。
- **Constraints**：不泄露私有配置/证书/Token，不Git配置或checkout，不卸载/清用户资料，不自动登录/接受协议/强签/创建模拟器；现有普通签名生成仅在本次已授权常规流程中由工具处理。
- **Scale/Scope**：3条脚本用户故事；不用重验原M1五故事，不改.ets/模块/依赖/签名模板或平台基线。

## Project Structure

| 绝对路径 | 职责与允许修改 |
|---|---|
| `/Users/zane/DevecostudioProjects/Shuvi-agent/scripts/dev-run.sh` | 主启动流程：工具/目标、独占模板拼装/还原、缓存/产品、构建与运行 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/scripts/dev-run.cmd` | Windows入口：Git Bash定位、空格/特殊字符参数、退出码，ASCII/CRLF |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/scripts/dev-run-support.cjs` | 新增小辅助：CLI结构化输出/目标模型校验、摘要/模板公共结构检查和Windows工具分派；不输出敏感内容 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/scripts/capture-test-log.sh` | 日志入口：跨平台摘要、空数组、独占目录、命令/日志顺序和真实退出 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/scripts/tests/dev-run.test.cjs` | 新增隔离回归，临时项目/假CLI/合成无秘密缓存，测试不碰真实.local或设备 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/scripts/README.md` | 新增/更新脚本用途、环境/两端命令、默认与失败规则、测试入口及Windows待复验 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/AGENTS.md` | 仅第六节启动/缓存/钩子说明更新，取消自动Git配置，保留其他规则 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/feature.json` | 当前执行目录指针，M1文件不覆盖 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/dev-run-portability/spec.md`、`/Users/zane/DevecostudioProjects/Shuvi-agent/spec/dev-run-portability/plan.md`、`/Users/zane/DevecostudioProjects/Shuvi-agent/spec/dev-run-portability/tasks.md` | 本轮需求/设计/任务 |
| `/Users/zane/DevecostudioProjects/Shuvi-agent/spec/dev-run-portability/implementation-report.md`、`/Users/zane/DevecostudioProjects/Shuvi-agent/spec/dev-run-portability/verification-report.md` | 后续真实实现/验证结果、日志/指纹/未覆盖 |

**Structure Decision**：既有Harmony应用不重构，不新增MVVM、路由或应用模块。只在scripts中增加一个生产辅助与一个集中测试入口，保持Bash/cmd负责使用入口，Node负责结构化数据和平台小适配；不转写成新的部署框架。

## Complexity Tracking

需要Node小辅助以避免脆弱表格/文本解析和GNU专属工具。Node已是DevEco工具链/仓库host前置，无新运行依赖安装；集中辅助少于多段内嵌Node/多个Shell脚本。隔离项目与真实运行分离是秘密/资料保护边界，不能用真实签名文件充当测试fixture。

## Research & Decisions

### R1：结构化发现与退出状态

**Decision**：读取 `device list --format json`、`emulator list --format json`、需要时 `device view -t <target> --format json`。只解析成功命令的JSON、类型/字段/状态/唯一性；stdout与诊断stderr分开，畸形或查询错误停止。退出状态/查询后的实际状态为准，不匹配英文“started successfully”或“Current user”作为唯一证据。

**Rationale**：现CLI已实测表格中名称有空格，$1/$2选择无效；JSON名称完整。未活动列表返回空数组，不能把查询报错当存在设备。

**Alternatives considered**：不按表格空格拆分，不依赖翻译/进度文案，不忽略CLI非零后继续。

### R2：默认与显式目标

**Decision**：显式目标先验证；仅emulator指定按完整名称找到唯一实例，停止态启动它，运行态直接等待就绪并锁定实际序列；仅device指定需要它存在/可关联所选实例，不为不可知serial启动其他模拟器。双参数必须在可核验映射中一致，未知/矛盾停止。默认只有唯一活动设备自动使用，多活动停止；无活动按模拟器列表首个启动。启动之后再次读取JSON核对指定实例/序列，run始终传明确target。

**Rationale**：避免其他活动设备抢占明确emulator；serial变化需运行态查询，不用任意第一个设备证明目标已就绪。

**Alternatives considered**：不硬编码Phone26或把它映射到Mate90Pro，不遍历启动所有实例，不默认多设备随便选。

### R3：Shell与Windows入口

**Decision**：Bash3.2语法，数组仅安全非空展开或分支处理，不用Bash4关联数组/大小写扩展。Node/Git系统能力检测可解释缺工具；CLI路径整体作为可执行目标，不eval。Unix不选择Windows包装；GitBash保留.cmd/.exe后缀、空间路径，必要Windows cmd转发只在Windows实现，并严格引用参数/退出码。cmd入口显式GitBash定位，避免用户参数被延迟变量扩展破坏，LF/ASCII-CRLF保持。

**Rationale**：macOS系统Bash3.2、PATHHomebrew5.3均需运行；Windows PATH bash可能WSL且GitBash不按PATHEXT自动补后缀。

**Alternatives considered**：不依赖安装jq/Coreutils，不退回WSL，不把Windows分支模拟称Windows实机执行。

### R4：模板/产品和缓存

**Decision**：先确保共享build-profile是批准的无签名模板且工作区/index均无改动；只读校验元信息，不输出内容。缓存键以实际模板内容摘要及产品身份组成，保留兼容已有default缓存的安全匹配入口（无法证明匹配则不盲用，正常生成）。使用实际内容而非HEAD哈希掩盖暂存变更；签名、build、run均带相同product，未知产品明确失败。

**Rationale**：旧模板校验只比较工作区/index，缓存对HEAD且无product，可复用不匹配签名。已有真实缓存只能脚本内部处理不读进AI。

**Alternatives considered**：不读打印signed配置/证书，不强制删除旧缓存，不将签名字段加入Git，不自动checkout带签名的模板。

### R5：独占与可恢复还原

**Decision**：跨平台原子目录锁、一次运行的独占备份，注册trap时只认可本次所有权。发现既有锁/未还原备份即停止提示人工检查，不自动清“陈旧”状态。EXIT/INT/TERM还原核验字节一致，再清本次备份/锁并报完成；还原失败保留备份/锁及非零状态。SIGKILL/断电不保证trap，下一次检测不明状态停止，文档明确限制。

**Rationale**：cp失败后删备份会丢恢复路径，固定bak可能由其他运行拥有；原脚本完成提示先于trap无法证明还原。

**Alternatives considered**：不依赖mac缺flock，不自动覆写既有bak，不无限等待/抢占锁，不称无法捕获终止也必然自动恢复。

### R6：授权与秘密日志

**Decision**：取消隐式gitconfig与checkout，钩子单独人工操作。auth仅脚本内部做成功且已登录状态预检，原输出不进日志。signature generate是已授权工具常规操作，stderr/stdout仅私有权限保护的运行文件或内存处理，公共输出提供脱敏阶段/错误类别；敏感临时文件不进入testlogs/AI上下文。自动登录、licenseaccept、uninstall、强签/处理配额或签名身份冲突均不执行。

**Rationale**：用户只批准常规流程且仓库禁止秘密上下文和资料清除；工具输出可能含身份/签名路径，不直接println原输出。

**Alternatives considered**：不用假登录字段或缓存storeFile一项作为完整有效性证明；签名生成成功后由构建/安装证据判断使用，不为绕过身份错误卸载。

### R7：日志与失败语义

**Decision**：capture用Node内置摘要或存在性验证的标准工具替代硬依赖sha1sum。先执行RUN_CMD捕获命令结果，再抓当前目标日志；无设备host-only可显式跳设备日志，meta分开cmd/log状态。目录独占创建，索引追加有界/并发安全；命令失败优先传播原退出，日志失败明确退出/标未完成，不能总返回0。空设备参数在Bash3.2安全。

**Rationale**：旧日志先抓再run无法覆盖随后启动事件，空数组和GNU摘要不通用；既有capture status≠命令状态需分层，改善不重写过去证据。

**Alternatives considered**：不让日志成功掩盖命令失败，不公开 signed配置/auth原输出，不覆盖旧日志；保留现有scope/目录/index及RUN_CMD方式。

### R8：实际使用与跨平台证据

**Decision**：隔离回归在Bash3.2/5.3通过后，真实调用修复后的仓库脚本指定Mate90Pro/productdefault，脚本内完成build及run，不另用IDE菜单或先裸build替代脚本。只验证启动、部署/运行、模板还原和日志；不操作M1导入/管理。Win分支与cmd源合同回归通过可证明兼容设计，实际cmd.exe安装/模拟器链路在Windows待用户复验。

**Rationale**：用户只验证脚本能使用；本机只有Mac，不伪造Windows环境。构建/deploy属于Phase5且只委派一次，脚本命令内build与run证据分段记录。

**Alternatives considered**：不重复上一轮M1verifyagent，不做五故事UI或应用业务修复，不创建Phone26配置，不自动运行默认目标风险流程。

### 已查接口与环境

本机现有 `/bin/bash`3.2、Homebrew Bash5.3，Node22/CLI1.3.4已有；device列表空、四模拟器stopped、Mate90Prophone实际存在。build/run help均支持product，run支持device与skip-build；device view支持target(serialOrName)/json。auth status没有json格式，实施需可靠封装状态判断并保密；不得硬设未证实字段/登录成功。Node可读公开安装配置但禁止为探索秘密读.local或证书。

## Data Model

| 模型/记录 | 内容与约束 |
|---|---|
| TargetInventory | 已验证device/emulator数组，名称/serial/deviceType/status；完整名称、不允许重复冲突，null serial仅停机态合法 |
| SelectedTarget | 选择来源、实例名、运行serial、product；不得跨阶段改变到别的设备，实例启动后再校验映射 |
| RunOwnership | 锁/备份路径、所有者标识、模板指纹、恢复状态；只清本次所有物，失败保持恢复路径 |
| CacheIdentity | 模板实际摘要、产品、缓存版本；私有配置内容不是公共数据 |
| ExecutionResult | 阶段、真实退出、可恢复/授权阻塞类别；不输出秘密/证书/账号原值 |
| Evidence | scope、platform/shell/工具版本、命令状态/设备日志状态、提交/工作区/脚本SHA、模板是否还原 | 

产品/名称/路径参数作为数据传递，控制字符/无效形态明确失败，不将其拼进任意Shell表达式；本机安全备份/签名缓存不得生成公共JSON输出。

## Contracts & Interfaces

### 原有使用入口与行为

保留dev-run.sh的emulator/device/product、force-sign/no-build/no-emulator/help以及EMULATOR_NAME/PRODUCT/DEVECOCLI_BIN；不变成“启动应用”需要用户点击IDE。默认行为与双参数一致性规则见R2。no-build仍执行明确部署/使用条件检查，不偷偷build；本轮真实使用不传no-build/force-sign。

`.cmd`定位Git forWindows，整体传递同样参数，返回.sh真实退出；内部Windows工具包装调用需覆盖Unicode/带空格路径，用户参数特殊字符不能被延迟扩展破坏，cmd.exe本身未在Mac模拟为真实系统。

capture保持scope/window/device与RUN_CMD、KEYWORD等，必要新增明确host-only开关（命令测试无需读设备）；本轮文档说明其真实退出与日志顺序变化。公开日志保留构建/安装状态与脱敏错误，秘密由签名工具运行私有阶段隔离。

### Regression Matrix

隔离测试使用临时项目/Git初始化和假工具，由Node创建受控文件；可在预批准临时目录或.cache子树，先验证父目录，不触碰真实.local/设备。测试不加载实际签名内容，合成字段以非秘密占位表示，安全验证结束只清自己创建的临时目录。

必测：空格/Unicode名、空/唯一/多active、defaultfirst emulator、显式目标优先、dual一致/冲突、运行/stopped/状态变化、missing/malformed/nonzeroinventory、startfailure/timeout/license、CLI后缀/空间路径、product、buildfailure不run、run退出与有限重试、auth拒绝、cache复用/失配、dirty/indexdirty/signed模板拒绝无checkout、lock/concurrent/既有bak/INTTERM/restorefailure、help无副作用、Bash3.2日志空设备/无GNUchecksum/hostskip/commandfailure/logfailure/不覆盖目录、秘密输出不进入公共日志、LF/cmdASCII-CRLF合同。

### Requirements Coverage

FR001/014：脚本scope及真实Mac仅Mate90Pro、无M1UI。FR002/003/004/005：R1–R3。FR006/007/008：R4/R5。FR009/010/012：R6及错误前置。FR011：R7。FR013/015：R8、回归与文件行尾/文档。

### Verification Strategy

Phase4只隔离回归/脚本syntax/必要lint和文档，不执行真实signedbuild或启动。Phase5依据tasksmarker执行真实脚本，其中build先成功才run，再核对serial/app运行及共享模板字节完全还原；报告可记分项PASS/环境阻塞，不把mock回归称真实deploy。纯.sh/.cmd/.cjs变更不跑arkts_check，仍需脚本内devecocli build产物证据。验证只委派一次，不在Phase5问UI；本轮无UI需求，Phase3选择仅verification来满足build/deploy。

最终Windows实机没有证据仍待复验，不因此否定已通过的跨平台回归，也不宣称已实测；无唯一安全授权/登录/许可/签名条件如实INCOMPLETE，不自动登录/接受/强签/卸载。

## Changelog

- 2026-10-13：首次跨平台脚本设计，基于实际源码、两套Bash、当前JSON清单与CLI帮助核对；只写设计，不执行签名/真实启动。
