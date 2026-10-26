> 历史来源文档：来自 local-ai-gateway 固定提交 `21017a1`，正文保留原文，仅供追溯。原机器路径、状态与操作记录不代表 Shuvi 当前环境。当前规则见主仓库 `docs/01-协作与工程约定.md`；接入和验证见本目录 README.md。

# Local AI Gateway 交接说明

更新时间：2026-09-28
仓库：`C:\claude-gateway`
当前工作分支：`codex/develop`
当前功能集成里程碑：`codex/develop@b415eeb`
最近合并：`b415eeb Merge hosted Windows CI test fixes`（来源分支 `codex/feature/github-ci-test-fixes@16ff95b`）

## 1. 接手时的真源顺序

下一智能体开始前必须完整阅读：

1. `TECHNICAL_DECISIONS.md`：长期技术设计真源。
2. `PROJECT_STATUS.md`：当前实际进度真源。
3. `README.md`：面向开发者的使用入口。
4. 本文：交接快照和续作边界，不覆盖前三者。
5. 代码、Git 状态和当次测试输出：最终实现证据。

不要寻找或恢复旧对话。若本文与前三份文档或代码冲突，以真源顺序和当前验证结果为准。

## 2. 当前仓库状态

已形成以下本地里程碑提交：

- `74563a6`：M0 CLI 和发布基线。
- `1cda1b3`：M1 配置和 Windows Credential Manager。
- `095bac2`：M2 最小本地网关 Runtime。
- `3050ac8`：M3a LiteLLM 配置、启动规范和托管进程契约。
- `bb7b7ec`：M4e 所有权感知的 integration status/unintegrate feature。
- `ed40771`：M4e 以非快进 merge commit 合入 `codex/develop`。
- `07e8504`：M5a 隐私受限 usage callback 与 SQLite WAL 用量存储 feature 实现。
- `69324fa`：记录 M5a 完整包双重重建与清理证据。
- `57d538f`：M5a 以非快进 merge commit 合入 `codex/develop`。
- `f59f5cf`：记录 M5a 集成状态和 M5b 边界。
- `74c662e`：M5b 私有 Python/SQLite 只读聚合核心与 `usage today`。
- `6988bb1`：M5b WPF Tray、控制/reload、测试、解决方案和完整包集成。
- `df5905d`：完整包隔离 Tray WindowsDesktop 自包含载荷，并验证父包根解析。
- `f8d60aa`：记录 M5b Tray 完整包和本机验收证据。
- `df3ab14`：M5b 以非快进 merge commit 合入 `codex/develop`。
- `1c57722`：记录 M5b 集成状态和 M5c 边界。
- `ec217cc`：M5c 普通/加密 provider secrets 备份、事务恢复和 CLI。
- `a392111`：记录 M5c 完整包和本机验收证据。
- `763c8f8`：M5c 以非快进 merge commit 合入 `codex/develop`。
- `a8fd2d4`：M5d 离线 updater WIP 安全断点。
- `0474d69`：完成受限外置 updater、实际原子切换和自动回滚验收。
- `997bd0b`：记录 M5d 完整包和本机验收证据。
- `bc12a0e`：M5d 以非快进 merge commit 合入 `codex/develop`。
- `d483ec0`：记录 M5d 集成状态和 M5e 边界。
- `48d50cd`：M5e owned credential/state data cleanup 基础。
- `afc2abb`：M5e 九类显式卸载契约、CLI 和协调器。
- `1be6e11`：M5e 外置卸载 worker、固定目标布局和完整包验收脚本。
- `4ec5a8a`：记录 M5e 完整包和本机验收证据。
- `92cb617`：M5e 以非快进 merge commit 合入 `codex/develop`。
- `7ac672d`：记录 M5e 集成状态并把下一边界切换到 M6。
- `1478979`：M6a Edge 单目标有界重试、`Retry-After`、回放测试和自包含 Runtime 专项脚本。
- `7aaa279`：记录 M6a 完整包和本机验收证据。
- `32c084d`：M6a 以非快进 merge commit 合入 `codex/develop`。
- `04f7ea8`：M6b per-target 熔断、控制协议 v2、status/doctor/Tray 状态和完整包专项验收。
- `77008a0`：记录 M6b 技术决策、验证证据和 M6c 续作边界。
- `8b9a477`：M6b 以非快进 merge commit 合入 `codex/develop`。
- `5afcbb3`：Tray dashboard 响应式布局、统一字体和可访问自定义 Profile 选择器。
- `ca774e9`：记录 Tray dashboard polish 验证证据。
- `1d6308f`：Tray dashboard polish 以非快进 merge commit 合入 `codex/develop`。
- `4aff995`：M6c schema-v1 兼容 ordered fallback、CLI、独立目标 backend 与首字节边界测试。
- `9b3032f`：记录 M6c 技术决策、验证证据和 M6d 续作边界。
- `d9a2e3f`：M6c 以非快进 merge commit 合入 `codex/develop`。
- `bcb7236`：M6d schema-v1 兼容 smooth weighted round robin、权重/策略 CLI、熔断跳过和专项验收。
- `24c2e00`：记录 M6d 技术决策、验证证据和 M6e 续作边界。
- `4b05bfe`：M6d 以非快进 merge commit 合入 `codex/develop`。
- `13d9c29`：记录 M6d 集成状态并把下一边界切换到 M6e。
- `2297ddd`：M6e profile/provider/model 分层并发、RPM、TPM、CLI、流式 usage 记账和专项验收。
- `888d535`：记录 M6e 技术决策、验证证据和当时拟定的 M6f 边界；M6f 后由项目所有者取消。
- `8d133d0`：M6e 以非快进 merge commit 合入 `codex/develop`。
- `78916ca`：记录 M6f 取消决定并把后续边界切换到发布收口。
- `aa80607`：首版发布收口的固定 schema、安全有界 operational log 生命周期实现与专项验收。
- `19c053f`：记录安全日志设计、完整包证据和后续发布决策点。
- `4d8f438`：安全日志 feature 以非快进 merge commit 合入 `codex/develop`。
- `efa7cc0`：记录安全日志集成状态和安装体验边界。
- `fab0cec`：Runtime+Tray 成对登录自启、交互/JSON 安装选择、自包含验收脚本。
- `fcac91b`：将 package、runtime credential 和成对自启纳入单一安装事务并补齐失败/取消回滚。
- `80ad89a`：记录成对自启安装体验、完整包和清理验证证据。
- `f799aa8`：安装体验 feature 以非快进 merge commit 合入 `codex/develop`。

M5a 已从 `codex/feature/m5a-usage-storage` 以非快进 merge 合入 `codex/develop`。源 feature 分支暂留
供审计；该阶段当时没有远程仓库，也没有推送。

M5b 只读聚合 reader、`aigw usage today` 和 WPF Tray 已从 `codex/feature/m5b-tray` 以非快进 merge 合入
`codex/develop`；来源分支保留供审计。没有读取或修改真实用量库、真实配置、Credential Manager 或 Task Scheduler。

M5c 普通与加密 secrets 备份已从 `codex/feature/m5c-backup` 以非快进 merge 合入 `codex/develop`；来源
分支保留供审计。验收只使用内存凭据和隔离 LocalAppData，没有读取或写入真实 Credential Manager。

M5d 离线升级已从 `codex/feature/m5d-updater` 以非快进 merge 合入 `codex/develop`；来源分支保留供审计。
验收只使用仓库内随机根和隔离 LocalAppData，没有读取或修改真实安装、凭据、计划任务、客户端配置或 usage 数据库。

M5e 已从 `codex/feature/m5e-uninstall@4ec5a8a` 通过 `92cb617` 非快进合入 `codex/develop`，来源分支保留
供审计。测试只操作随机隔离 Local AppData、fixture 集成/备份和仓库一次性发布根；未触碰真实 Credential
Manager、Task Scheduler、客户端配置、usage 数据库、模型或上游。

M6a 已从 `codex/feature/m6a-edge-retry@7aaa279` 通过 `32c084d` 非快进合入 `codex/develop`。它只改变本地 Edge
响应开始前的单目标重试，不改变配置 schema、私有 Python、包布局或外部状态；M6b 熔断在该终态分类上计数。

M6b 已从 `codex/feature/m6b-circuit-breaker@77008a0` 通过 `8b9a477` 非快进合入 `codex/develop`，来源分支
保留供审计。它不改变配置 schema 或私有 Python：当前以 route revision 内的 provider + public alias 作为
目标，默认连续 5 个逻辑终态瞬态失败打开 30 秒，单 half-open 探针恢复。

Tray dashboard polish 已从 `codex/feature/tray-dashboard-polish@ca774e9` 通过 `1d6308f` 非快进合入
`codex/develop`，来源分支保留供审计；没有改变控制、配置、usage 查询或打包依赖。

M6c 已从 `codex/feature/m6c-ordered-fallback@9b3032f` 通过 `d9a2e3f` 非快进合入 `codex/develop`，来源
分支保留供审计。它兼容扩展 schema v1，按目标完整执行 M6a 链并复用 M6b circuit，自动跳过 open 目标，
严格禁止首字节后 fallback；未新增依赖。

M6d 已从 `codex/feature/m6d-weighted-round-robin@24c2e00` 通过 `4b05bfe` 非快进合入 `codex/develop`，
来源分支保留供审计。它按 route revision/alias 平滑加权选择单个可用目标，目标内部完成 M6a/M6b，
终态瞬时失败不跨目标 fallback；未新增依赖或控制协议字段。

M6e 已从 `codex/feature/m6e-rate-limits@888d535` 通过 `8d133d0` 非快进合入 `codex/develop`，来源分支
保留供审计。它为 profile、provider、公开模型增加可选并发/RPM/TPM；限流状态跨蓝绿 reload 保留，
Token 只从实际复制的 JSON/SSE usage 流式记账，不缓冲响应或估算文本。未新增依赖、私有 Python 包或
控制协议字段。

首版发布收口的日志生命周期已从 `codex/feature/release-log-lifecycle@19c053f` 通过 `4d8f438` 非快进
合入 `codex/develop`，来源分支保留供审计。它只记录固定 allowlist 的 daemon/reload 生命周期事件；活动文件、保留期、受管总量、
当前用户 ACL、严格 owned 清理、reparse 拒绝和 fail-open 均有测试。未新增依赖、下载或外部写入。

该阶段当时没有远程仓库，也没有推送。M3b-M4d 实现、测试和文档已汇总到本地累计检查点 `a802cc5`；接手时仍应先运行 `git status --short`，避免误丢后续工作。

### 分支架构

- `main` 固定在已稳定验收的 M3a 基线 `3050ac8`；只有完整里程碑通过验收后才前移。
- `codex/develop` 是已验证功能的长期集成线，从 M4d 文档检查点 `c9f6e9a` 继续接收完成的 feature。
- `codex/feature/m4e-integration-lifecycle` 是已完成并合并的 M4e 来源分支，暂时保留供审计；删除前需确认合并结果和项目所有者意图。
- 后续功能分支统一使用 `codex/feature/<milestone>-<topic>`，验证完成后以保留里程碑边界的 merge commit 合入 `codex/develop`。
- 只有需要稳定发布时才创建 `codex/release/<version>`；紧急修复从 `main` 创建 `codex/hotfix/<topic>`，并同时合回 `main` 与 `codex/develop`。
- 已合并的 feature 分支可在确认合并结果后删除；不得在未建立保护引用时移动 `main`、重写或丢弃开发提交。

当前最近一次完整验证结果：

- .NET SDK：`10.0.302`。
- Release build：0 warnings、0 errors。
- 自动化测试：547/547，通过数为 Core 128、Windows 106、CLI 77、Runtime 118、LiteLlm 28、Launcher 63、
  Tray 18、Updater 9。
- 源码敏感信息扫描：279 个非生成文件通过。
- M5a callback 专项验证通过 WAL/schema/一年保留/未来 schema 拒写/锁冲突 fail-open/敏感 canary 不落盘；
  真实 LiteLLM 1.95.0 callback-load、13/5/18 Token 假上游事件和真实产品工厂 1/1 均通过。
- M5a 完整包从 feature commit `07e8504` 独立重建两次且 SHA-256 一致：
  `8a9fd199e25e51790a6a216c9971119c4c583ca2df32ab6dbb04bc02cd25fde2`；ZIP 为 134,632,858 字节、
  11,071 个条目，sidecar、callback 嵌入、Runtime commit marker/smoke 均通过。一次性包根、测试根与
  私有 Python 进程残留均为 0。
- M5b 查询核心 Release 全量测试 346/346：Core 90、Windows 60、CLI 51、Runtime 54、LiteLlm 28、
  Launcher 63；源码敏感扫描 194 个文件。真实私有 Python/WAL 只读聚合、未来 schema 拒绝、100 ms 超时
  进程回收、隔离 LocalAppData 实际 CLI 和 216 文件自包含发布检查均通过，所有 M5b 临时根为 0。
- M5b Tray 定向 14/14 和自包含 EXE smoke 通过；`df5905d63d5a6533ba7be2491cc40601920b9bb0` 上的
  完整包 manifest 11,546/11,546，包内禁用全局 .NET 的 Tray smoke 与 ProductVersion commit marker 通过，
  ZIP SHA-256 为 `07814885268c5496bf0391d8e95011b35546448a4c38b635ad05840d7018b760`。一次性检查目录均已删除。
- M5c 专项 Core 9/9、Windows 7/7、CLI 4/4；实际私有 Python Argon2id/AES-GCM、错误口令、超时/取消、
  隔离 CLI restore、ACL 和零残留通过。`ec217cc7e0ee4a674c4a403ea3eeab443acd2fde` 完整包 manifest
  11,548/11,548，SHA-256 `2bcdd367c1b0f41f534f60e3435eabbcb476458cc73352b1b2ae915b8beb6e79`，包内加密 smoke 通过。
- M5d 定向 Core 15/15、Windows 15/15、Updater 6/6、CLI 4/4；`0474d692e9abe6ebe72035671c206e202b39e2a8`
  上的完整包扫描 11,747 文件，SHA-256 `7ffbc03da83f2a1d4c44573f3f7395a7ae43b9d8d87c1e8415283e143ac49af3`。
  实际 Ed25519 verifier、自包含外置 worker、成功原子切换、后置健康故障自动回滚及零测试根残留均通过。
- M5e `1be6e11` 上 Release 466/466：Core 118、Windows 106、CLI 74、Runtime 54、LiteLlm 28、Launcher 63、
  Tray 14、Updater 9；源码敏感扫描 256 文件。定向 46/46、五个自包含 EXE 和实际外置卸载 worker 通过；
  完整包扫描 11,751 文件，SHA-256 `3fc35ad19cdf656aa4d75b656de4c8e43cb5959c4543bea1f71650b3111a75de`，
  隔离发布/Local AppData/worker/receipt/测试进程残留为 0。
- 收尾时 M5a callback、M5b query/Tray、M5c backup 和 M5d update 专项均再次通过；M5d 使用当前 11,751
  文件包完成实际原子切换、注入后置健康失败回滚及零测试根清理。
- M6a `1478979` 上全量 Release 498/498、0 warning/0 error，最终源码扫描 259 文件；Runtime 86/86 和
  自包含 EXE/commit marker 专项通过。完整包 manifest 11,751、ZIP 11,753 文件，三次重建 SHA-256 均为
  `c4563804a61765548c786ea99d1a16b680a6d9689db702bc2060e21a4872bc92`，随机发布根和进程残留为 0。
- M6b `04f7ea8` 上全量 Release 506/506、0 warning/0 error，源码扫描 262 文件；专项五组 406 项和
  Runtime/CLI/Tray 自包含 EXE 通过。两次完整包均扫描并逐项验证 11,751 个 manifest payload，五个 EXE
  marker 正确，SHA-256 均为 `5af692be1cdd07e199afce6b208716e5ad4a48feb480b2dc8d3c5614e9ba6c3f`，
  随机发布根和进程残留为 0。
- Tray dashboard polish `5afcbb3` 上全量 Release 510/510、0 warning/0 error，源码扫描 266 文件；M5b Tray
  18/18 和自包含 EXE smoke 通过。当前 M6b 专项五组 410 项及 Runtime/CLI/Tray smoke 通过，两次完整包
  manifest 均为 11,751，SHA-256 均为
  `5a118040a2184b25c73c9aadb1e2b61bc8025ed1e470d029d6a237583f7cd03a`，随机根和测试进程残留为 0。
- M6c `4aff995` 上全量 Release 518/518、0 warning/0 error，源码扫描 268 文件；专项 Core 3、CLI 1、
  Runtime 3 与 Runtime/CLI 自包含 smoke 通过。最高完整包专项五组 419 项、Runtime/CLI/Tray smoke 和
  两次 11,751 项 manifest 重建通过，SHA-256 均为
  `be7477d025ff9731061fa919df8f4daf974e994285b5888261cf34a643ba1be8`，随机根和测试进程残留为 0。
- M6d `bcb7236` 上全量 Release 523/523、0 warning/0 error，源码扫描 270 文件；专项 Core 2、CLI 1、
  Runtime 6 与 Runtime/CLI 自包含 smoke 通过。最高完整包专项五组 423 项、Runtime/CLI/Tray smoke 和
  两次 11,751 项 manifest 重建通过，SHA-256 均为
  `3bc84f529ec4c622887d71b4c242f99a37c690e69476756d782fd8d2b700f109`，随机根和测试进程残留为 0。
- M6e `2297ddd` 上全量 Release 540/540、0 warning/0 error，源码扫描 276 文件；专项 Core 2、CLI 1、
  Runtime 14 与 Runtime/CLI 自包含 smoke 通过。最高完整包专项五组 440 项、Runtime/CLI/Tray smoke 和
  两次 11,751 项 manifest 重建通过，SHA-256 均为
  `91f1452627657b1feb57af10d2afa6effaef2ae73504d7b3a2fd664a885adabf`，随机根和测试进程残留为 0。
- 日志实现 `aa80607` 上全量 Release 547/547、0 warning/0 error，源码扫描 279 文件；专项 12 项、真实私有
  Runtime composition 和无全局 .NET 的 Runtime 自包含 smoke 通过。最高完整包专项五组 447 项、
  Runtime/CLI/Tray smoke 与两次 11,751 项 manifest 重建通过，SHA-256 均为
  `861db3ac2a477df5020795e0e629d24ccfae79c9ede77f34fc7b59821f02d28e`，随机根和测试进程残留为 0。
- M3b assembly 导入烟测和四 provider/五类协议回环烟测通过；109/109 下载源大小与哈希复核通过，最终锁可确定性再生成；runtime-state、`.pyc`、`__pycache__`、私有 Python 进程和含空格镜像残留均为 0。
- M3c 原生测试已验证 suspended Job 中的父进程和后代进程同时回收；真实 M3b assembly 已经由产品工厂完成挂起启动、Job 分配、ready、drain、stop，测试目录和私有 Python 进程残留均为 0。
- M3d 专用 `scripts/test-m3d-runtime.ps1` 已验证真实 assembly 的 Mutex → 配置/令牌 → Job → ready →
  Edge `/ready` → stop 完整闭环；脚本在 assembly 缺失、测试根与 assembly 重叠或任一进程、目录、
  字节码、缓存残留时失败。
- M3e 专用 `scripts/test-m3e-runtime.ps1` 已验证当前用户 Pipe status/reload/stop、revision 2 候选
  Job ready、原子切换、旧实例回收和 Edge `/ready`；测试后两个私有进程树、测试根、runtime-state、
  `.pyc` 和 `__pycache__` 残留均为 0，没有模型请求。
- M3f 完整开发包两次独立生成哈希一致：`b5c7d8a31bc036983d1cf309121b196aae599edda2b24b1de30aae481b94ad26`；manifest 11,066/11,066 条通过，ZIP 134,469,563 字节，输出目录仅保留 ZIP 和 `.sha256`。
- 完整包的无全局 .NET EXE smoke、私有 Python import、隔离安装、真实 M3e、隔离卸载均通过；acceptance、私有进程、runtime-state、`.pyc` 和 `__pycache__` 残留为 0。
- M3g 已实现并验证 256 位 CSPRNG runtime token、固定当前用户路径、package + credential 事务、SID 级安装锁、生命周期 CLI 和 daemon 控制；测试只使用随机临时目录、内存凭据库和假进程/控制客户端，未执行真实安装或真实 Credential Manager 写入。
- 真实 daemon 验收候选包哈希为 `7465b105e0c544ec43ec069e48a68048ef5f413bfc69c77e39f8892d4ae7a231`；两次独立打包哈希一致，11,066 个载荷文件扫描通过。
- 只读 `doctor --json` 已由实际构建 CLI 进程验证，报告安装/配置缺失、`modelProbePerformed=false` 和 `upstreamContacted=false`；命令后两个真实 Local AppData 目标仍不存在。
- 真实当前用户安装、重复安装幂等、安装目录 EXE 只读诊断和安装根外卸载已通过。首次创建程序与 runtime credential，复装不轮换令牌；卸载后程序根、状态根、staging、进程、credential 及项目验收根均不存在。
- 最终垃圾审计清除了 71 个历史 daemon 控制测试临时目录（36,412 字节）。根因是 xUnit 2.9.3 未识别测试类的 `IAsyncDisposable`；改用 `IDisposable` 后定向 5/5、当时全量测试均通过且新增/最终匹配残留为 0。
- 真实路径发现并修复两项问题：`File.Replace` access denied 采用严格受限的双原子移动回退；daemon 改用 `CreateProcessW`、受限句柄列表和 `NUL` 标准句柄，避免 `start --json` 捕获输出时被后台进程持有管道。
- 安装后真实 token 的 daemon 闭环已通过：active revision 4、重复 start 幂等、Pipe status 正常、无令牌 `/ready` 为 401、无模型/上游访问；stop/卸载后六类残留为 0。
- 可选登录自启真实闭环已完成：固定任务 `\LocalAIGateway.Runtime`，当前用户登录触发、交互令牌、最低权限、固定安装 EXE `--serve`；注册、系统规范化回读、重复 enable、Scheduler action 启动、重复 start、disable、卸载和零残留均通过。2026-09-22 后续验收又完成了 Runtime+Tray 成对真实 logon event。
- `scripts/test-m3g-installed-runtime.ps1 -TestAutostart` 默认只读展示全部精确目标；只有再加 `-Execute` 才会执行真实安装、任务注册/幂等/回读、Task Scheduler action 启动、撤销、卸载和残留审计。
- 当前可交付 M3g development ZIP 保留在 `artifacts/m3g-package-output`，SHA-256 为 `03a2c977d38ee868ee904018f479b4bd521fc1182d21239208dc15547689004a`。两次独立重建一致；目录只含 ZIP 和 sidecar；ZIP 134,504,162 字节、11,067 个文件、manifest 11,066 个载荷条目。
- 同一 ZIP 和 sidecar 已复制到 `C:\Users\Admin\Desktop\LocalAIGateway-M3g`，桌面目录只含两个文件且哈希复核一致。
- M4a 新增 `LocalAIGateway.Launcher` / `aigw-launcher.exe`：严格绝对客户端路径、无 shell `ArgumentList`、
  固定 Credential Manager runtime token、按需 daemon 启动、子进程局部 base URL/token 环境和退出码透传。
  M4a 当时尚未实现 `aigw run` 适配器且不固化 Claude/Codex 环境变量名；该缺口已由下述 M4b 完成。
- 打包脚本已纳入 launcher。一次性 `artifacts/m4a-package-check` 通过自包含/manifest/参数拒绝烟测后已彻底删除；
  桌面与仓库保留的 M3g ZIP 没有被覆盖，因此不能把它称为 M4a 成品。
- M4b 已实现 `aigw run claude|codex|--client`：Claude 使用官方 base URL/Bearer token 环境契约；Codex
  使用一次性 Responses provider 配置，不写 TOML。已知客户端拒绝 model/provider 覆盖，只解析 native
  `.exe`，CLI 静默透传退出码。验证只用 fixture，没有读取、运行或修改真实客户端。
- 一次性 `artifacts/m4b-package-check` 已完成自包含发布、11,070 项 manifest、无全局 .NET 帮助和冲突拒绝
  烟测，随后完整删除；桌面 M3g 包仍未覆盖，不能称为 M4b 成品。
- M4c 已实现只读 `aigw integrate preview`。Claude VS Code 只表示带所有权标记的
  `claudeCode.claudeProcessWrapper` JSONC 字段，并支持扩展 wrapper 的 bundled-Claude-first 参数形状；
  Codex 只表示独立 `$CODEX_HOME/aigw.config.toml` Responses profile，不动默认配置、不落令牌。
- 预览只读显式 fixture、不会读取 target，输出仅有托管块 diff 和哈希。未知版本、非托管同名字段、损坏
  标记或标记内用户字段均以退出码 14 拒绝。一次性 `artifacts/m4c-package-check` 两类包内 smoke 通过后已
  完整删除；临时 ZIP SHA-256 为 `c576701d1242a120a0e97017ebada7f65bc125505d30303b64a935347c914c90`。
  没有读取、运行或修改真实 Claude/Codex/VS Code，也没有写 H 盘。
- M4d 已实现 `aigw integrate apply`：必须绑定 preview before/after hash 和精确 `--confirm APPLY`；现有文件
  以同目录 write-through 临时文件 + `File.Replace` 原子更新并生成唯一 backup，新文件无覆盖移动。严格
  UTF-8、BOM 保留、reparse path 拒绝、stale target/生成结果拒绝和最后一刻竞态自动恢复均有测试。
- 一次性 `artifacts/m4d-package-check` 已完成 Codex 新建、Claude 新建/更新、backup 和确认拒绝 smoke；
  ZIP SHA-256 为 `04e82d0e8b856da62607fe4f38a20282c87be5d7bc38ee2c08e83feffbbcde42`。
  包根及匹配 fixture 残留均为 0；未读取或写入真实配置，未覆盖桌面 M3g 包。
- M4e 已实现显式 target 的 `integrate status|unintegrate`。status 返回 absent/not-integrated/owned 和脱敏
  撤销计划；unintegrate 绑定 before/after hash 或 delete 计划，并要求精确 `UNINTEGRATE` 确认。
- Claude/带注释 Codex 使用原子替换和恢复备份；纯受管 Codex 文件原子移动到备份，不遗留空文件。故障
  注入覆盖 stale、replace 失败和删除竞态恢复。`integrate list` 因无 registry 且不得自动扫描而明确不实现。
- M4e 实际构建 CLI smoke 通过；一次性完整包生成并扫描 11,070 个文件，ZIP SHA-256 为
  `0badda89873982ddc1ade81dde4f85de0bcfb4ba3f4cddd65bf33f7857c838f3`。全部 M4e 临时根已删除；未触碰
  真实 Claude/Codex/VS Code 配置。

## 3. 已实现边界

M0-M2 已具备 CLI、严格配置、凭据存储、Kestrel/YARP 回环代理、公开模型 alias 校验、三套文本协议、SSE 透传、确定性假后端和自包含开发包验证。

M3a 已实现：

- 确定性、无密钥的 LiteLLM YAML 兼容配置编译。
- 公开 alias 到 provider/upstream model 的隔离映射。
- 凭据只进入受控子进程环境计划。
- `LITELLM_LOCAL_MODEL_COST_MAP=True`、关闭重试、遥测和第三方 callbacks；M5a 只启用自有 usage callback。
- 固定私有 Python 路径、`-B -I` 和固定 `-c` 调用官方 `litellm.run_server`、无 shell 的最小进程启动规范。
- 子进程 TEMP、HOME、AppData 及常见第三方缓存根收敛到实例 `runtime-state`。
- prepare、ready probe、drain、stop 的并发和失败恢复契约。
- Azure OpenAI v1 已用真实 LiteLLM 1.95.0 验证并启用：`azure/<deployment>`、资源根 `api_base`、`api_version=v1`。

M3c 已实现产品私有 Python 进程工厂和 Job Object：`CreateProcessW` 挂起创建后，使用受限继承句柄列表把标准流定向到 `NUL`，先分配 `KILL_ON_JOB_CLOSE` Job，再恢复主线程；环境块释放前清零。

M3d 已新增 `aigw-runtime.exe --serve` 正式组合：在读取凭据和准备后端前持有按当前用户 SID
隔离的全局 Mutex，从 `LocalAIGateway/runtime/client-token` 读取安装级客户端令牌，将私有 LiteLLM
接入固定 Edge，并在停止时最后释放单实例租约。真实 assembly 冷启动促使 readiness 从单次探测改为
默认 60 秒有界轮询；完整 Mutex → Job → ready → Edge → stop 链路已通过且残留为 0。

M3e 已新增当前用户 SID 管道、严格 64 KiB v1 帧协议、status/reload/stop 和可复用 Windows 客户端。
reload 只重读配置真源；每个请求以不可变 route lease 固定 revision/profile/model rewriter/internal token/
backend，SSE 完成后才释放。高 revision 候选 ready 后原子切换，失败保留旧实例并报告 pending revision；
相等 revision 幂等、旧 revision 拒绝。控制连接和旧 route retirement 任务均会移除，非预期连接失败由
关闭路径汇总观察。

M3f 已把私有 Python assembly、锁/receipt/environment、许可证和组件清单纳入完整确定性 ZIP，并新增严格 package manifest、原子安装、同包幂等、异包冲突、失败 staging 清理和保守卸载。M3f 只在仓库 artifacts 内完成隔离验收，没有写真实用户安装位置、凭据、计划任务、PATH、Start Menu 或客户端配置。

## 4. M3b 最终文本运行时与下载审计

下载前已读取 Python、PyPI 和 LiteLLM 官方元数据：

- Python 根制品：`python-3.14.5-embed-amd64.zip`，12,048,447 字节，SHA-256 `ba6bd811c4eedb19195cf275770ef127e893d63701e24152606e2cb76f6d876a`。
- LiteLLM 根制品：`litellm-1.95.0-cp314-cp314-win_amd64.whl`，24,920,863 字节，SHA-256 `c3684dcf16aefe98bd6f11586d60a9a92bb1bf7e85468a6a4ac28a65532fab3e`。
- 按官方 `v1.95.0` `uv.lock`、CPython 3.14.5 和 Windows x64 marker 解析的完整 `litellm[proxy]` 闭包为 108 个兼容 wheel，缺失 0 个，wheel 总计 127,698,463 字节（121.78 MiB）。
- 连同 Python embed 的预计载荷为 139,746,910 字节（133.27 MiB）。
- 本轮临时元数据目录已精确删除，残留计数为 0；没有写入 H 盘。

官方 `[proxy]` extra 无条件包含 `litellm-enterprise==0.1.52`，PyPI 元数据将其许可证标为 `LicenseRef-Proprietary`。项目最终文本运行时在上游解析阶段明确排除该 wheel，并已用真实 LiteLLM 启动和协议烟测证明目标功能不依赖它；仍不得把该 enterprise wheel 纳入分发包。

后续只读审计还发现并修正了一个 M3a 问题：官方 v1.95.0 包目录不存在 `litellm/__main__.py`，所以 `python -I -m litellm` 无法作为启动契约；官方 `pyproject.toml` 将控制台入口声明为 `litellm = "litellm:run_server"`。检查点 `a802cc5` 使用固定 `python -B -I -c "from litellm import run_server; run_server()"`；`-B` 是真实运行时发现 `-I` 忽略 `PYTHONDONTWRITEBYTECODE` 后增加的缓存防护。配置和端口仍是独立参数，密钥仍只在环境中。

`proxy_server.py` 对 `litellm_enterprise` 的导入使用 `try/except ImportError`，缺失时置空 enterprise 配置。这证明 enterprise 在该入口点不是启动硬依赖，但不能证明删去其他 proxy 包后仍能启动。

已生成下载前保守候选清单：`runtime-manifests/m3b-proxy-without-enterprise.candidate.json`。

- 清单 SHA-256：`0bb5e21d4b8b20e5d2f0cc6df4a74362ce3c3a595fa49bfb1ee3e92d6c94e361`。
- 107 个 wheel，加 Python embed 共 108 个载荷。
- wheel 为 127,557,637 字节；总载荷为 139,606,084 字节（133.14 MiB）。
- 缺失兼容 wheel 为 0，enterprise 和不适用 Windows 的 `uvloop`/`pyroscope-io` 均不在载荷中。
- 许可证元数据未发现 proprietary、GPL、AGPL 或 SSPL 信号；wheel 内 LICENSE/NOTICE 和原生库许可证仍待下载后核验。
- manifest 的 `candidate-not-approved-not-downloaded` 是用户审批时的不可变快照状态；当前下载结果以 `PROJECT_STATUS.md` 和 verification receipt 为准。

用户已授权并完成向 `C:\claude-gateway\artifacts\m3b-runtime-download` 下载 108 个原候选制品，并将已验证的 `cl100k_base.tiktoken` 加入同一精确目标。最终下载输入为 109 个文件、141,287,210 字节，所有文件均通过大小与 SHA-256 校验；没有额外文件或 `.partial`，没有写入 H 盘。

验证收据：`runtime-manifests/m3b-download-verification.json`，SHA-256 `e47f93a9b7c05a36cdd897b1b52eccf39c1df7ddd957418a05d5df2b3f8539ed`。

归档级审计结论：

- 108 个归档均可读取，路径穿越条目为 0，enterprise 代码条目为 0。
- 26 个归档包含 DLL/PYD 等原生二进制。
- `tokenizers-0.23.1` wheel 没有内嵌许可证文件；官方 v0.23.1 LICENSE 已核对为 Apache-2.0，最终包必须补带。
- `soundfile-0.12.1` wheel 捆绑 `libsndfile_64bit.dll` 和 LGPL-2.1 文本；音频不在首版范围，默认从最终文本运行时排除。
- `runtime-manifests/licenses/tokenizers-0.23.1-LICENSE.txt` 已从官方 tag 下载并通过锁定 SHA-256。
- 最终锁为 `runtime-manifests/m3b-text-runtime.lock.json`，SHA-256 `45ed2669eb90cf6c4e8fdd4530ada0235e2eb9ccc3da391aae1b973597e4e1d8`。它选择 87 个 wheel、CPython 和 BPE 共 89 个压缩输入、83,827,724 字节，并保留 20 个下载但不组装的 wheel 及逐项理由。
- `scripts/new-m3b-runtime-lock.ps1` 从不可变 candidate/verification receipt 机械生成该锁，同时验证全部 109 个源文件；连续生成哈希一致。

当前 assembly：

- 路径：`C:\claude-gateway\artifacts\m3b-runtime-assembly`（gitignored）。
- 87 个 wheel + CPython 3.14.5 + `cl100k_base.tiktoken`；fresh rebuild 后为 10,699 个文件、206,297,020 字节。
- 排除 20 个 wheel：enterprise 不在候选 manifest；assembly 另外排除 soundfile/libsndfile、替代服务器、数据库/队列、分析、交互 CLI 和 Azure identity 等非目标组件。
- 实际 LiteLLM 1.95.0 已通过 OpenAI-compatible、本地 endpoint、Anthropic、Azure OpenAI v1 四类映射，以及 Chat Completions、Responses、Anthropic Messages、SSE 和工具调用回环烟测。
- 测试统一使用 `-B -I`。曾产生的 272 个 `__pycache__` 和 1,638 个 `.pyc` 已精确清理，复测为 0；runtime-state 烟测文件均已清空。
- assembly 内临时硬链接镜像已验证含空格路径并精确清理，残留 0；Codex 沙箱限网条件下多次冷启动通过，但独立 Windows 防火墙/VM 断网仍未验证。
- `cl100k_base.tiktoken` 已纳入下载输入和最终锁，大小 1,681,126 字节，SHA-256 `223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7`；assembly 已证明可完全从 109 个源文件重建，不再依赖旧 assembly。

官方来源：

- Python 3.14.5：<https://www.python.org/downloads/release/python-3145/>
- Python 制品目录：<https://www.python.org/ftp/python/3.14.5/>
- LiteLLM 1.95.0：<https://pypi.org/project/litellm/1.95.0/>
- LiteLLM `pyproject.toml`：<https://raw.githubusercontent.com/BerriAI/litellm/v1.95.0/pyproject.toml>
- LiteLLM `uv.lock`：<https://raw.githubusercontent.com/BerriAI/litellm/v1.95.0/uv.lock>
- Enterprise wheel 元数据：<https://pypi.org/project/litellm-enterprise/0.1.52/>

注意：最终逐项选择已经写入 `m3b-text-runtime.lock.json`。接手后必须运行生成器和验证脚本复核，不得从聊天记录手抄或直接修改大清单。

## 5. 建议的下一步

最终锁、可重建 assembly、M3 生命周期、M4a-M4e launcher/CLI/配置集成事务，以及 M5a 用量写入均已完成
本机验证并合入 `codex/develop`。M5b 只读聚合/WPF Tray、M5c 普通/加密 secrets 备份和 M5d 离线升级均已
合入。M5e 完整卸载也已通过 `92cb617` 合入；M6a-M6e 已合入，M6 到此完成。项目所有者已取消本地
日/月 Token quota 与 80%/90%/100% 阈值告警；不得把它作为默认下一任务恢复。
安全日志生命周期已合入；Runtime+Tray 成对登录自启已在 feature 中实现并通过仓库隔离验收。
交互安装默认 enable，JSON 安装必须显式 `--autostart enable|disable`；文件、凭据和任务使用单一 SID 锁和反序回滚。
PATH 与只创建 Tray Start Menu shortcut 的策略已锁定、实现和验证；Runtime+Tray 成对真实重新登录触发也已
通过。当前工作站已完成最新版 unsigned development 包的永久自用安装；下一实际任务是配置首个 Profile。
干净普通用户、无全局 .NET/Python/PowerShell、VM/防火墙断网的 air-gap 验收在自用阶段主动延期，仍不得称为已通过。
真实客户端配置仍需精确目标授权。

执行顺序：

1. 先只读核对绑定 `f1de4b0` 的最终完整 ZIP、sidecar、Git 状态、当前自用安装和本文记录，不重新下载或改动 M3b 输入。
2. 如修改运行时或打包逻辑，使用 `scripts/verify-m3f-package.ps1` 从零重验；该脚本在输出目录已存在时会拒绝覆盖，必须由用户决定旧输出如何处理。
3. Runtime+Tray 成对真实 action/logon event 已完成并清理；不要重复写真实任务，除非新的实现变更要求重新验收。
4. 另行规划 Windows 防火墙或 VM 级断网、普通用户、无全局 .NET/Python/PowerShell 的干净机验证；不得把 Codex 沙箱限网等同于该门槛。
5. 大型下载、缓存、一次性发布和验收目录优先使用非系统盘；当前允许使用 H 盘。仍不访问真实模型。完成的 feature 必须先独立提交并验证，再以明确 merge commit 合入 `codex/develop`。

如果最小依赖集无法稳定启动或必须加载 proprietary enterprise 代码，应停止并报告证据，不得静默回退到完整 `[proxy]` extra。

## 6. 安全和操作边界

- 已撤销“不使用 H 盘”的旧限制；大型开发缓存、下载和临时制品在路径所有权清晰时优先放非系统盘。产品固定 Local AppData 安装/状态路径、现有仓库和锁定制品不自动迁移，不使用目录联接绕过安全边界。
- 2026-09-28 已获授权创建 `AlterGo-xzy/local-ai-gateway` 私有仓库并仅推送 `codex/develop`；不修改 Codex 用户配置。
- 不覆盖 Claude、VS Code、Codex 或其他外部配置。
- 删除、覆盖外部配置，或执行不可逆操作前，必须列出精确目标并取得确认。
- 上游密钥不得进入 JSON、YAML、命令行、日志、测试输出或交接文档。
- 普通 `doctor` 不产生模型调用；只有用户明确确认的 `doctor --probe <model>` 才能访问上游。
- 如果终端再次出现 `helper_unknown_error: setup refresh had errors`，立即停止，不修改文件，并把原始错误报告给用户。
- 初次依赖下载属于联网和写入操作；不能把“继续工作”解释为对未知清单的下载授权。

## 7. 接手和验收命令

开始时只读核对：

```powershell
Get-Location
git status --short
git log -5 --oneline
Get-ChildItem -Force
```

代码改动后的基础验收：

```powershell
./scripts/build.ps1
./scripts/scan-sensitive-data.ps1 -ExcludeGenerated
./scripts/test-m3d-runtime.ps1
./scripts/test-m3e-runtime.ps1
./scripts/test-m5a-usage-callback.ps1
./scripts/test-m5b-usage-query.ps1
./scripts/test-m5b-tray.ps1
./scripts/test-m5c-backup.ps1
./scripts/test-m5d-update.ps1
./scripts/test-m5e-uninstall.ps1
./scripts/test-m6a-edge-retry.ps1
./scripts/test-m6b-circuit-breaker.ps1
./scripts/test-m6c-ordered-fallback.ps1
./scripts/test-m6d-weighted-round-robin.ps1
./scripts/test-m6e-rate-limits.ps1
./scripts/test-release-log-lifecycle.ps1
./scripts/test-release-install-experience.ps1
./scripts/test-scan-sensitive-data.ps1
git diff --check
git status --short
```

`build.ps1` 会 restore、Release build、test 和扫描；如果已确认依赖完整且要避免联网，可使用 `./scripts/build.ps1 -NoRestore`。只有在运行时和打包逻辑实际变化后，才需要执行：

```powershell
./scripts/verify-m3f-package.ps1
```

不得把当前本地验证表述为全新离线 Windows 用户环境已经通过。

## 8. 给下一智能体的首要决策点

M3b 下载和 assembly 授权边界已经完成，不要再次下载或改变 109 文件输入集。M3c-M3g 闭环和 M4a-M4e
launcher/客户端适配器/preview/apply/status/unintegrate 均已完成 fixture 验证，M5a usage storage 已完成并
合入集成线。M5b SQLite 只读聚合、`usage today`、WPF Tray、状态与控制动作、M5c 备份和 M5d 离线升级均已
合入。M5e 完整卸载已验证并合入；M6a-M6e 已合入，M6 到此完成。原拟定 M6f 已明确取消。安全日志
生命周期 feature 已完成并合入；Runtime+Tray 成对自启安装体验 feature 也已完成本机验证并通过 `f799aa8` 非快进合入。
当前用户 PATH 与 Tray Start Menu shell integration 已在 `codex/feature/release-shell-integration` 完成；成对真实
logon event 已于 2026-09-22 通过。当前工作站随后完成永久自用安装；下一实际任务为配置 Profile。干净机/air-gap
在自用阶段延期但未通过。M7 自研 backend host 仍是未来研究项，不进入首版生产。
真实客户端验收仍不得读取、运行或修改真实
Claude/Codex/VS Code，除非先取得精确目标授权。写计划任务、
真实 PATH、Start Menu、计划任务或客户端配置写入仍需精确授权。不得安装全局 Python、使用包管理器缓存或访问真实模型；大型开发缓存和临时制品优先使用非系统盘。

## 9. M5d 完成断点（2026-09-14）

- 当前 feature 从 `codex/develop@3daafcb` 创建；实现提交 `0474d69` 和验收文档 `997bd0b` 已通过
  `bc12a0e` 非快进合入，来源分支保留供审计。
- 先前原子切换失败的根因是普通 `Process.Start` 仍可能继承 CLI 调用链的未列名管道句柄，使 bootstrap/CLI
  无法及时退出并锁住活动安装树。通用 `WindowsDetachedProcess` 现通过 Win32 handle list 只传递三个 `NUL`
  标准句柄，并支持参数和显式最小环境；回归测试证明任意可继承匿名管道不会进入子进程。
- 已安装 updater 验证候选后复制到受保护 `update-workers/<GUID>`，外置 worker 等待 bootstrap 与 CLI PID
  退出，再执行 staging、side-load 健康检查、目录原子切换、daemon 状态恢复和原子 receipt。清理器只接受
  状态根下精确 GUID owned 路径。
- `0474d69` 上 Release 423/423、0 warning/0 error、源码敏感扫描 239 文件。提交后完整包 11,747 文件，
  ZIP SHA-256 `7ffbc03da83f2a1d4c44573f3f7395a7ae43b9d8d87c1e8415283e143ac49af3`；实际成功更新和后置健康
  故障自动回滚均通过，安装版本、回执、worker、transaction 和测试根全部验证并清理。
- 没有新增 NuGet、wheel、全局 Python 或下载。正式 Ed25519 私钥尚未配置，当前只能生成并显式授权 unsigned
  development 包；全新 OS 级断网普通用户环境仍未验证。

## 10. M5e 完成断点（2026-09-15）

- 九类卸载选择固定为 program、autostart、integrations、runtime credential、provider credentials、
  configuration、usage、logs、backups；交互逐类询问，非交互必须逐类 `keep|remove` 并精确确认 `UNINSTALL`。
- integration 和 backup 都只接受显式绝对目标，绝不扫描真实客户端配置或备份目录。集成复用既有所有权、
  哈希和恢复备份事务；凭据仅枚举固定 target 名称，未读取 secret。
- 安装根内的 CLI 通过 `updater\aigw-updater.exe` 调度受保护 Temp GUID worker。worker 等待调用 CLI/updater
  退出，再获取 SID 安装锁、停止 daemon、处理 selected categories 并原子写 receipt；固定 Local AppData 布局、
  最小环境、受限句柄、超时/取消进程树回收均有测试。
- 程序文件仍按 canonical manifest 的大小/SHA-256 保守删除；状态只删除固定 owned 文件/子树，reparse point
  在删除前 fail-closed。运行中的 worker 无法安全删除自身树，因此真实卸载后 worker/receipt 作为无 secrets
  审计证据保留，必须先验证 receipt 和进程退出，再清理 receipt 对应的精确 GUID 路径。
- feature 提交 `48d50cd`、`afc2abb`、`1be6e11`、`4ec5a8a` 已形成，并通过 `92cb617` 非快进合入
  `codex/develop`；来源分支保留供审计，`main` 未移动。

## 11. M6e 完成断点（2026-09-18）

- 当前 feature 从 `codex/develop@13d9c29` 创建；实现提交为 `2297ddd`。profile/provider/model 可选
  limits 与 `limits ... set|clear` CLI 复用既有 strict schema、revision、配置锁和原子保存。
- profile/model permit 覆盖完整逻辑请求，provider permit 只覆盖实际目标尝试；并发跨重试、fallback 和
  响应流，取消/异常/完成均释放。RPM 只在 provider admission 后提交，拒绝请求不消耗 RPM。
- RPM/TPM 为滚动 60 秒窗口，registry 由 coordinator 共享并跨 reload 保留。429 稳定错误分别为
  `aigw_concurrency_limit_exceeded`、`aigw_rpm_limit_exceeded`、`aigw_tpm_limit_exceeded`。
- usage scanner 只解析实际复制的结构化 JSON/SSE usage，不缓冲正文或扫描模型文本；token-limited chat 流
  强制 include_usage，同时保留其他 stream options 和公开 alias。已放行请求允许一次实际 usage 超额。
- `2297ddd` 上 Release 540/540、源码扫描 276 文件；M6e 专项 Core 2、CLI 1、Runtime 14、自包含
  Runtime/CLI smoke 通过。完整包两次重建 manifest 11,751，SHA-256 均为
  `91f1452627657b1feb57af10d2afa6effaef2ae73504d7b3a2fd664a885adabf`，随机根和进程残留为 0。
- 未新增 NuGet、wheel、全局 Python 或下载，未访问真实模型、上游、配置、凭据、计划任务、真实 usage DB
  或 H 盘。项目所有者已取消原拟定 M6f 日/月 quota 和阈值告警；不得自动恢复该范围。

## 12. 安全日志生命周期完成断点（2026-09-18）

- feature 从 `codex/develop@78916ca` 创建；实现提交 `aa80607`、文档提交 `19c053f` 已通过 `4d8f438`
  非快进合入 `codex/develop`，来源分支保留供审计，`main` 未移动。
- Runtime 只在取得当前用户单实例 Mutex 后初始化 `logs/gateway.log`。固定 JSONL API 仅接受 UTC 时间、
  allowlist event/level 和可选 revision，不接受任意 message、exception、请求/响应、配置或敏感值。
- 活动文件写入前按 10 MiB 上限无覆盖轮转，轮转保留 30 天，受管总量上限 100 MiB；只清理严格匹配
  owned UTC 时间戳和序号的顶层文件，lookalike/未知文件不动，目录和活动文件 reparse point 拒绝跟随。
- 目录/文件应用当前用户 ACL，每条事件 write-through flush；I/O、ACL、清理失败全部 fail-open，不改变
  daemon 生命周期或数据面结果。事件覆盖 daemon start/stop 和 configuration reload 的成功/失败。
- `aa80607` 上 Release 547/547、源码扫描 279 文件；专项 12 项、真实私有 Runtime composition、自包含
  Runtime smoke、最高完整包五组 447 项及两次 11,751 项 manifest 重建通过。ZIP SHA-256 均为
  `861db3ac2a477df5020795e0e629d24ccfae79c9ede77f34fc7b59821f02d28e`，随机根和进程残留为 0。
- 未新增 NuGet、wheel、全局 Python 或下载；未写真实 LocalAppData、Credential Manager、Task Scheduler、
  客户端配置或 usage DB，未访问模型、上游或 H 盘。

## 13. 安装体验与成对自启断点（2026-09-18）

- feature 从 `codex/develop@efa7cc0` 创建；实现提交 `fab0cec`，安装事务回滚修复提交
  `fcac91b`，文档提交 `80ad89a`，已通过 `f799aa8` 非快进合入 `codex/develop`。
  `codex/feature/release-install-experience` 保留供审计，`main@3050ac8` 未移动。
- `install` 交互默认启用 Runtime+Tray 成对自启；`install --json` 必须显式给出
  `--autostart enable|disable`。固定任务为 `\LocalAIGateway.Runtime` 和 `\LocalAIGateway.Tray`，
  任一冲突在文件/凭据变更前 fail-closed，Runtime-only legacy 状态可幂等补齐。
- package、runtime credential 和成对任务在同一 SID Mutex 内组合；安装后段失败或取消时只反序
  回滚本次创建的资源，保留安装前完整包、令牌和 owned 任务；回滚失败统一为
  `aigw_install_rollback_failed`。
- `fcac91b` 上 Release 560/560：Core 128、Windows 114、CLI 82、Runtime 118、LiteLlm 28、
  Launcher 63、Tray 18、Updater 9；0 warning/0 error，源码扫描 280 文件。专项 57 项与自包含
  CLI 选择门/版本 smoke 通过。
- 最终完整包通过五组 460 项、Runtime/CLI/Tray EXE smoke 和两次 11,751 文件 manifest。
  SHA-256 均为 `2f43c3ccac454fef00f59c4a51a8e51208583d8da1f655b34af591004706ae43`，测试根残留为 0。
- 本轮没有写入真实 LocalAppData、Credential Manager 或 Task Scheduler，没有访问真实配置、usage DB、
  模型、上游或 H 盘。真实 Runtime+Tray action/logon 验收、PATH、Start Menu 和 clean-machine/
  air-gap 仍待精确授权或产品决策。

## 14. Shell integration 与真实 Tray action 断点（2026-09-22）

- feature 分支为 `codex/feature/release-shell-integration`；shell 核心提交 `a52b335`，PATH 原文恢复修复
  `afbf035`，Runtime 任务诊断与技术真源恢复提交 `f1de4b0`。`main@3050ac8` 未移动。
- 安装固定追加程序根到当前用户 PATH，并只创建指向 Tray 的 Start Menu shortcut。状态根 receipt 记录所有权，
  PATH 类型/文本/分隔符和既有空目录可精确恢复；冲突、reparse、取消及后段失败均 fail-closed 或反序回滚。
- `f1de4b0` 上 Release 580/580、0 warning/0 error，源码扫描 282 文件；M5a、M5b、install-experience
  专项通过。最终完整包 manifest 11,751，SHA-256
  `91c41e959b8ed9451eb967476e30e0ae725913ccb31d7a5760848bbaf4ae03de`，五个自包含 EXE smoke 通过。
- 真实当前用户验收确认 Tray task action 启动唯一安装路径进程并安全终止，`autostartActionStartedTray=true`；
  安装根、状态根、两项任务、runtime credential、快捷方式、进程和验收根清理为 0，PATH 恢复为原始
  ExpandString 807 字符且不含安装路径。
- 初次 Runtime 复测的 revision 0 已定位为 Codex 执行器外部文件视图隔离：同 SID、Session 和
  `LOCALAPPDATA` 的 Scheduler 探针对控制进程创建的 marker 返回不存在。由 Task Scheduler 上下文生成 revision 4
  配置后，未修改的 `aigw-runtime.exe --serve` action 启动成功并连续观察 95 秒；注销/重新登录时 Runtime 与
  Tray 同时触发，Runtime 日志记录 `daemon.started` revision 4，Tray 为唯一 owned 安装路径进程。

## 15. Runtime+Tray 真实 logon event 断点（2026-09-22）

- 验收包仍为 `f1de4b0` 绑定的 unsigned ZIP，SHA-256
  `91c41e959b8ed9451eb967476e30e0ae725913ccb31d7a5760848bbaf4ae03de`；未修改运行时代码或 task action。
- 注销前两项任务均为 owned/Ready，Runtime 和 Tray 进程均为 0；重新登录后两项 LastRunTime 同时推进到
  `2026-09-21T17:13:20Z`。Runtime 记录 `daemon.started` revision 4，Tray 从固定安装路径启动唯一进程。
- 原始 Runtime task action 另行手动运行并从第 11 秒至第 95 秒持续报告 active profile
  `host-logon-acceptance`、revision 4，任务保持 Running；`ExecutionTimeLimit=PT0S`，空闲与电池停止均关闭。
- 最终停止、卸载和独立残留审计通过：安装根、状态根、两项任务、runtime credential、快捷方式、PATH 条目
  和安装进程均不存在；PATH 恢复为原始 ExpandString 807 字符。一次性控制包、探针脚本和收据已删除。
- 这完成本机真实 logon event，但不替代 clean-machine、独立 OS air-gap、正式签名或 remote CI 证据。

## 16. 当前工作站永久自用安装断点（2026-09-22）

- 安装包为绑定 `f1de4b0` 的完整 unsigned ZIP，SHA-256
  `91c41e959b8ed9451eb967476e30e0ae725913ccb31d7a5760848bbaf4ae03de`；`f1de4b0..356abb1` 只有真源文档变化，没有源码、依赖或打包输入变化。
- 解压安装源保留在 `H:\LocalAIGateway\install-source-f1de4b0`，共 11,753 个文件。项目所有者已允许使用 H 盘，并要求大型开发数据尽量避开系统盘。
- 当前程序根为 `%LOCALAPPDATA%\Programs\LocalAIGateway`，状态根为 `%LOCALAPPDATA%\LocalAIGateway`；runtime credential、owned PATH 条目和 Tray Start Menu shortcut 已创建。
- 安装使用 `--autostart disable`；两个计划任务均不存在，Runtime 未运行。版本、doctor、status 和 autostart status 只读验收通过，未访问模型或上游。
- 2026-09-22 当时配置缺失是预期状态；这只是历史快照，不代表当前 Profile/Runtime 现场状态。

## 17. GitHub 私有仓库和 CI 验证（2026-09-28）

- 项目所有者已同意在 `AlterGo-xzy` 下建立名为 `local-ai-gateway` 的私有仓库；创建时已核实 `visibility=PRIVATE`、`isEmpty=true`、Actions 已启用。现已配置 `origin`，仅推送 `codex/develop`；`main` 和 feature 分支未推送。
- 本机 GitHub CLI 经浏览器授权可使用；不要读取或展示令牌。历史 83 个提交的文本补丁未命中常见 API key、GitHub token、私钥和 AWS key 格式，历史路径没有配置、密钥或 usage DB 候选；审计并非形式化无密钥证明。
- `.github/workflows/ci.yml` 已在 `codex/develop@3f599f6` 合入：对 `main`/`codex/develop` 的 push、PR 和手动触发执行 Windows 2022、`global.json` 指定 SDK、Release 构建、全解决方案测试与源码敏感扫描。删除会在干净 runner 上因缺失未入库私有 Python assembly 而失败的完整包步骤。
- 首次 GitHub CI 运行 `36443626307` 发现 CRLF fixture 假设与流式断连测试竞态；`codex/feature/github-ci-test-fixes@16ff95b` 修复并非快进合入 `codex/develop@b415eeb`。随后 [GitHub Actions 运行 `36444486374`](https://github.com/AlterGo-xzy/local-ai-gateway/actions/runs/36444486374) 在 Windows 2022 通过：Release 构建 0 warning/0 error、588/588 测试、源码扫描 282 文件。本地相同全量命令也通过。保持旧 `main@3050ac8` 不动，不推送审计用 feature 分支。
