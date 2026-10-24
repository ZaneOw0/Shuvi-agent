> 历史来源文档：来自 local-ai-gateway 固定提交 `21017a1`，正文保留原文，仅供追溯。原机器路径、状态与操作记录不代表 Shuvi 当前环境。当前规则见主仓库 `docs/01-协作与工程约定.md`；接入和验证见本目录 README.md。

# Local AI Gateway 项目总计划与技术决策全览

文档状态：供项目所有者完整审阅的单一汇总文档
汇总日期：2026-09-22
仓库：`C:\claude-gateway`
当前工作分支：`codex/develop`
当前功能集成里程碑：`codex/develop@ce1d338`
最近合并：`ce1d338 Merge self-use installation policy`（来源分支 `codex/feature/self-use-install-policy@a08f7a1`）

## 1. 文档目的与真源顺序

本文把项目目标、完整路线图、技术选型、已经发生的实现决策、当前验证证据、后续拟定方案和仍待决定事项集中到一个文档，便于项目所有者从头到尾审阅。

本文是汇总视图，不改变以下真源顺序：

1. `TECHNICAL_DECISIONS.md`：长期技术设计真源。
2. `PROJECT_STATUS.md`：实际进度真源。
3. `README.md`：开发和使用入口。
4. `HANDOFF.md`：交接快照和续作边界。
5. 当前代码、Git 状态和当次测试输出：最终实现证据。

本文中的状态标签含义如下：

- **已锁定**：已经写入技术设计真源，后续实现必须遵守。
- **已实现**：当前工作树中已有代码或脚本，但不自动代表已经提交或验证。
- **已验证**：有当前仓库的自动化测试、构建或实际烟测证据。
- **拟定**：推荐设计，尚待项目所有者确认后进入实现。
- **待决定**：没有足够依据锁定，实施前必须明确选择。
- **受阻**：缺少权限、环境、外部资源或必要证据，不能诚实宣称完成。

## 2. 项目摘要

Local AI Gateway 是一个面向 Windows x64 的可复用本地 AI 网关。它用固定的本机 HTTP 入口统一 Claude、Codex CLI 和其他 OpenAI/Anthropic 兼容客户端，并在内部管理配置、凭据、LiteLLM 私有运行时、进程树、控制面、蓝绿切换、客户端集成和后续运维能力。

首版目标是：

- 最终用户可在无管理员权限、无全局 Python、无全局 .NET、无 PowerShell、无网络的环境安装和运行。
- 对外固定监听 `127.0.0.1:4000`，内部 LiteLLM 使用随机回环端口。
- 支持 OpenAI Chat Completions、OpenAI Responses、Anthropic Messages、模型列表、健康和就绪接口。
- 支持文本、流式输出和工具调用，不承诺首版多模态。
- 上游密钥只进入 Windows Credential Manager 和受控子进程环境，不进入配置、命令行、日志或诊断输出。
- 运行时和依赖均为哈希锁定、可审计、可重建、可离线验证的私有载荷。
- 配置切换使用候选实例 ready 后再切流的蓝绿模型，不中断旧请求和 SSE。

当前状态：M0-M6e、安全日志生命周期、Runtime+Tray 成对登录自启、当前用户 PATH 与 Tray Start Menu shell integration 均已进入 `codex/develop` 并完成本机验证；真实登录事件也已通过。当前工作站已安装绑定 `f1de4b0` 的完整 unsigned development 包，自启关闭且尚未配置 Profile。`main` 仍固定于 `3050ac8`；真实客户端配置未执行。

分支采用稳定线、集成线和短期功能线三级结构：`main` 当前固定于 M3a `3050ac8`，`codex/develop`
从 M4d 文档检查点 `c9f6e9a` 继续接收已验证功能；已完成的 M4e、M5、M6a-M6e、安全日志、安装体验和
shell integration 源 feature 分支均保留供审计。
功能验证完成后先以 merge commit 合入 `codex/develop`；只有完整里程碑达到交付条件时才更新 `main`。
发布分支和 hotfix 分支仅在实际需要时创建，避免长期分支膨胀。

## 3. 产品边界

### 3.1 首版包含

- Windows x64、.NET 10、自包含发布。
- CLI 产品名 `aigw`，运行时进程 `aigw-runtime.exe`。
- LiteLLM 1.95.0 私有文本代理后端。
- OpenAI-compatible、Anthropic、Azure OpenAI、本地 endpoint 四类 provider。
- Profile、Provider、Model alias、默认模型和当前 active profile。
- Windows Credential Manager 凭据存储。
- Kestrel/YARP 固定回环 Edge。
- 当前用户 Mutex、Named Pipe、Job Object 和蓝绿后端切换。
- 离线 ZIP、当前用户安装、登录自启、客户端 launcher、用量与运维能力按里程碑逐步加入。

### 3.2 首版不包含

- Windows ARM64、Linux、macOS。
- 多模态、金额核算、在线更新、第三方动态插件。
- Codex 桌面应用自动接入。
- 未经确认修改 Codex、Claude、VS Code 或其他外部配置。
- 默认产生真实模型请求；只有显式 `doctor --probe <model>` 才允许。
- 迁移旧密钥、旧用量、旧日志或复用旧实现。

### 3.3 许可证边界

- 当前项目不授予公开许可证。
- 发布制品必须携带完整第三方许可证和 notices。
- `litellm-enterprise` 的许可证为 `LicenseRef-Proprietary`，不得进入分发包。
- `soundfile`/libsndfile 不属于文本首版，当前最终运行时排除它，避免无必要的 LGPL 原生载荷。

## 4. 总体架构

```text
Claude / Codex CLI / 通用客户端
                |
                | 固定本地令牌认证
                v
     127.0.0.1:4000 (.NET Edge)
       Kestrel + YARP + 严格策略
                |
                | 每实例随机内部令牌
                v
  127.0.0.1:<随机端口> (私有 LiteLLM)
                |
                v
       远程或本地模型提供方
```

控制链路独立于公开 HTTP 端口：

```text
aigw CLI / Tray / Launcher
            |
            | 当前用户 Named Pipe
            v
   aigw-runtime.exe control server
            |
            +-- status
            +-- reload configuration source
            +-- stop after acknowledgement
```

主要组件：

- `LocalAIGateway.Core`：配置领域模型、严格校验、稳定错误、控制协议、后端生命周期契约。
- `LocalAIGateway.Windows`：ACL、Credential Manager、Named Pipe 客户端、Mutex 等 Windows 平台实现。
- `LocalAIGateway.Cli`：System.CommandLine 用户入口，业务逻辑委托给 Core 或控制面客户端。
- `LocalAIGateway.Runtime`：公开 Edge、认证、请求策略、正式 daemon、控制服务器和 route 生命周期。
- `LocalAIGateway.LiteLlm`：派生配置、进程启动规范、挂起创建、Job Object、ready/drain/stop。
- `LocalAIGateway.Launcher`：M4 按需创建，用于客户端启动和局部环境注入。
- `LocalAIGateway.Tray`：M5 按需创建，用于状态和 Token 仪表盘。
- `LocalAIGateway.Updater`：M5 按需创建，用于离线升级、健康检查、回滚和卸载辅助。

不提前创建 Launcher、Tray、Updater 空项目，以免把未设计接口固化为兼容负担。

## 5. 技术选型与实现决策登记

### 5.1 平台、语言和构建

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D001 | 已锁定、已实现 | 仅支持 Windows x64 | 产品依赖 Credential Manager、ACL、Named Pipe、Mutex、Job Object 和 Task Scheduler；首版不承担跨平台抽象成本。 |
| D002 | 已锁定、已实现 | 使用 .NET 10，目标 `net10.0-windows` | 提供现代 BCL、Kestrel、原生 Windows API 互操作和自包含发布能力。 |
| D003 | 已锁定、已验证 | 发布为 win-x64 self-contained、无 trimming | 最终用户不依赖全局 .NET；不 trimming 避免反射型第三方组件被裁剪。 |
| D004 | 已锁定、已验证 | 开发包使用确定性 ZIP | 相同输入必须生成相同 SHA-256，便于离线审计和升级验证。 |
| D005 | 已锁定 | 正式签名前只发布 `unsigned development` 包 | 当前没有正式 Ed25519 私钥，不把未签名包表述为正式发布。 |
| D006 | 已实现 | NuGet 版本集中管理，`global.json` 固定 SDK | 减少项目间版本漂移；当前验证 SDK 为 10.0.302。 |
| D007 | 已锁定 | 最终用户安装和运行不依赖 PowerShell | PowerShell 脚本只用于开发、打包和验收；产品安装逻辑最终必须在自包含 EXE 内。 |

### 5.2 CLI 和机器契约

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D010 | 已实现、已验证 | 使用 System.CommandLine 2.0.0 | 提供严格解析和可测试命令树；移除默认 help/version 后建立项目自己的稳定契约。 |
| D011 | 已锁定、已实现 | `Program.Main` 保持薄入口，核心为可测试的 `CliApplication.RunAsync` | 避免进程级测试成为所有 CLI 行为的唯一验证方式。 |
| D012 | 已锁定、已实现 | 全局选项为 `--json`、`--lang`、`--no-color`、`--verbose` | 所有命令层级一致；机器 JSON 不受 UI 语言影响。 |
| D013 | 已锁定、已实现 | 人类输出可中英文，机器字段、错误码和 JSON schema 使用英文 | 保证脚本兼容性与本地化解耦。 |
| D014 | 已锁定 | 退出码固定为 0、2、10、11、12、13、14、15、20、70 | 将参数、配置、凭据、冲突、后端、集成、文件、探测和内部错误稳定分类。 |
| D015 | 已锁定 | 不接受命令行明文密钥 | 密钥只通过隐藏输入或 `--secret-stdin`。 |

### 5.3 配置模型

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D020 | 已锁定、已实现 | 版本化 JSON 是唯一配置真源 | LiteLLM YAML 只作为运行时派生文件，禁止手工维护双真源。 |
| D021 | 已锁定、已实现 | schema v1 严格拒绝未知、重复、损坏和未来字段 | 防止静默降级、字段拼写错误和新版本被旧程序破坏。 |
| D022 | 已锁定、已实现 | Profile 隔离 provider、model、route、limit 和凭据引用 | 切换 active profile 不混合不同供应商状态。 |
| D023 | 已锁定、已实现 | 每个完整 profile 恰好一个默认模型 | 保证 `aigw/default` 有确定路由；草稿 profile 可以不完整但不能激活。 |
| D024 | 已锁定、已实现 | 远程 endpoint 强制 HTTPS，本地 endpoint 才允许私有地址 HTTP | 降低远程密钥明文传输风险，同时保留本机模型服务。 |
| D025 | 已锁定、已实现 | 配置写入使用 ACL、跨进程锁、revision、完整校验、原子替换和 `.bak` | 防止并发覆盖、半写文件和权限过宽。 |
| D026 | 已锁定 | 配置/状态根为 `%LOCALAPPDATA%\LocalAIGateway` | 当前用户、无需管理员、与程序文件分离。 |

### 5.4 凭据和隐私

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D030 | 已锁定、已实现 | 上游密钥存于 Windows Credential Manager | target 为 `LocalAIGateway/<profile>/<provider>/api-key`。 |
| D031 | 已锁定、已实现 | 安装级客户端令牌 target 为 `LocalAIGateway/runtime/client-token` | Runtime 只读取；生成、轮换和删除由安装/认证生命周期负责。 |
| D032 | 已锁定、已实现 | 上游密钥只进入受控 LiteLLM 子进程环境 | 不进入 JSON、YAML、命令行、日志、诊断或输出。 |
| D033 | 已锁定 | 不记录 prompt、response、工具参数、认证头或金额 | 只允许必要请求元数据、真实 usage Token 和受控错误元数据。 |
| D034 | 已锁定、已验证 | 源码、配置、输出、包和日志执行 canary/密钥扫描 | 关键阶段必须报告扫描文件数和结果。 |
| D035 | 已锁定 | 不承诺抵御已经控制当前 Windows 用户账户的恶意程序 | 安全边界为当前用户隔离，而不是同账户强对抗。 |

### 5.5 公开网络和协议

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D040 | 已锁定、已实现 | Edge 固定监听 `127.0.0.1:4000` | 客户端配置稳定；端口冲突明确失败，不换端口、不杀进程。 |
| D041 | 已锁定、已实现 | LiteLLM 使用随机内部回环端口和每实例随机令牌 | 避免暴露固定管理面和跨实例令牌复用。 |
| D042 | 已锁定、已实现 | 公开 API 只含三套文本 POST、models、health、ready | 缩小 LiteLLM 巨大代理面的攻击和兼容范围。 |
| D043 | 已锁定、已实现 | 请求认证先于路由判断 | 未认证请求不能利用路径差异探测服务能力。 |
| D044 | 已实现、已验证 | 本地认证支持 Bearer 或 `x-api-key`，拒绝重复/冲突并固定时间比较 | 兼容不同客户端，同时避免模糊认证语义。 |
| D045 | 已实现、已验证 | 请求体严格 JSON、深度 64、上限 8 MiB | 限制资源占用和畸形输入。 |
| D046 | 已实现、已验证 | 清除客户端认证、Cookie、转发头和后端 Cookie/Server 头 | 防止本地凭据、伪造转发信息和后端指纹泄漏。 |
| D047 | 已锁定、已实现 | 上游 4xx/5xx 原样返回；超时为 504，响应头前断连为 502 | 保留协议语义；流开始后不追加网关错误正文。 |
| D048 | 已锁定、已实现 | 基础阶段不重试、不聚合流 | 避免重复请求和破坏 SSE；M6a 现由 Edge 统一执行严格的响应前重试。 |

### 5.6 模型和 provider 映射

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D050 | 已锁定、已实现 | 公开模型 alias 大小写不敏感校验并规范化 | 客户端使用稳定 `aigw/*` 名称，未知模型在触达后端前拒绝。 |
| D051 | 已锁定、已实现 | LiteLLM `model_name` 保持公开 alias | `litellm_params.model` 才承载 provider/upstream 名称，避免内部标识泄漏。 |
| D052 | 已锁定、已实现 | 每个私有 LiteLLM 实例只承载一个 profile | 蓝绿切换和凭据隔离更清晰。 |
| D053 | 已锁定、已验证 | Azure OpenAI 使用 v1：`azure/<deployment>`、资源根 `api_base`、`api_version=v1` | 已用 LiteLLM 1.95.0 真实回环验证。 |
| D054 | 已锁定 | 首版模型映射严格一对一 | fallback、负载均衡和多目标池留到 M6。 |

### 5.7 私有 Python/LiteLLM 运行时

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D060 | 已锁定、已实现、已验证 | 固定 CPython 3.14.5 和 LiteLLM 1.95.0 | 构成可复现的 Windows x64 文本运行时。 |
| D061 | 已锁定、已验证 | 最终锁由 87 wheels、Python embed、`cl100k_base.tiktoken` 构成 | 锁文件为 `runtime-manifests/m3b-text-runtime.lock.json`，不手工修改大清单。 |
| D062 | 已锁定、已验证 | `litellm-enterprise` 不进入候选或最终 assembly | proprietary 许可证且目标文本代理不依赖它。 |
| D063 | 已锁定、已验证 | `soundfile`/libsndfile 和 19 个非目标 wheel 不进入 assembly | 减少攻击面、体积和不必要许可证负担。 |
| D064 | 已实现、已验证 | 使用 `python -B -I -c "from litellm import run_server; run_server()"` | 官方包没有 `litellm/__main__.py`；`-B` 防止 `-I` 条件下产生字节码缓存。 |
| D065 | 已锁定、已实现 | 不用 shell；固定参数列表、清空继承环境、校验环境变量 | 防止注入和继承开发机配置。 |
| D066 | 已锁定、已实现 | `LITELLM_LOCAL_MODEL_COST_MAP=True`，关闭 retry、telemetry 和第三方 callbacks；M5a 只启用自有 usage callback | 避免隐式联网、金额逻辑和未设计的回调行为。 |
| D067 | 已锁定、已实现 | TEMP、HOME、AppData、pip、uv、HF、Transformers、Torch 缓存均指向 per-instance `runtime-state` | 候选实例结束后可以精确清理，不污染用户全局缓存。 |
| D068 | 已锁定、已验证 | `cl100k_base.tiktoken` 随包携带 | 禁止 tiktoken 首次启动联网下载。 |
| D069 | 已验证 | assembly 从 109 个锁定源 fresh rebuild | 当前 10,699 文件、206,297,020 字节；不依赖旧 assembly。 |

### 5.8 进程和资源生命周期

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D070 | 已锁定、已实现 | `CreateProcessW` 挂起创建私有 Python | 允许在任何用户代码运行前完成句柄限制和 Job 分配。 |
| D071 | 已锁定、已实现 | 标准流只继承指向 `NUL` 的受限句柄 | 不继承 CLI、终端或秘密相关句柄。 |
| D072 | 已锁定、已实现 | 先加入 `KILL_ON_JOB_CLOSE` Job，再恢复主线程 | daemon 崩溃或句柄关闭时回收完整子进程树。 |
| D073 | 已实现、已验证 | 状态持有真实 process/job handle，不只依赖 PID | 避免 PID 重用和无法控制后代进程。 |
| D074 | 已实现 | 环境 Unicode 内存块在 CreateProcess 返回后逐字节清零 | 降低密钥在非托管堆中滞留时间。 |
| D075 | 已实现、已验证 | Stop 会终止 Job、等待进程树退出并只删除实例拥有目录 | 失败状态可重试，不伪装成功。 |
| D076 | 已锁定、已实现 | ready 采用 100 ms 间隔、默认最多 60 秒的有界探测 | 真实 LiteLLM 冷启动证明单次探测会误判。 |

### 5.9 daemon、单实例和控制面

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D080 | 已锁定、已实现 | 正式入口为 `aigw-runtime.exe --serve` | 固定从程序目录读取 `runtime/python/python.exe`，不回退全局 Python 或开发 artifacts。 |
| D081 | 已锁定、已实现 | 启动先取得 `Global\LocalAIGateway.runtime.<SID>` Mutex | 在读取凭据和准备后端前保证当前用户跨会话单实例。 |
| D082 | 已锁定、已实现 | Mutex 最后释放；清理失败时保守保留到进程退出 | 避免旧后端未清完时新 daemon 重叠。 |
| D083 | 已锁定、已实现 | 控制 pipe 为 `LocalAIGateway.Control.v1.<SID>`，`CurrentUserOnly` | 不开放 TCP 管理端口。 |
| D084 | 已锁定、已实现 | v1 为 4 字节 little-endian 长度加 UTF-8 JSON，最大 64 KiB，一连接一问一答 | 易于严格边界控制和版本化。 |
| D085 | 已锁定、已实现 | 命令只有 `status`、`reload`、`stop` | reload 只读配置真源，IPC 不传配置或密钥；stop 先响应后关闭。 |
| D086 | 已实现、已验证 | 服务最多 8 个并发连接槽 | 防止慢客户端无限占用任务和句柄。 |
| D087 | 已实现、已验证 | 完成任务从跟踪表移除，非预期失败独立汇总 | 避免任务表增长、关闭竞态和未观察异常。 |

### 5.10 蓝绿配置切换

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D090 | 已锁定、已实现 | 高 revision 先准备候选并通过 ready，再原子发布 | 候选失败不破坏当前可用实例。 |
| D091 | 已锁定、已实现 | 每请求取得不可变 route lease | 同时固定 configuration、profile、rewriter、internal token 和 backend。 |
| D092 | 已锁定、已实现 | SSE 持有 route lease 到流结束 | 旧实例不能在流式响应中途停止。 |
| D093 | 已锁定、已实现 | 新请求切到候选后，旧 route 停止接租约，等待归零再 drain/stop | 实现无请求错配的蓝绿切换。 |
| D094 | 已实现、已验证 | 相同 revision 幂等，旧 revision 拒绝，并发 reload 串行化 | 保证版本单调和可解释状态。 |
| D095 | 已实现、已验证 | status 暴露 active/pending revision、switching 和稳定错误码 | 不暴露令牌、内部端口或进程参数。 |
| D096 | 已实现、已验证 | candidate ready 后再次检查取消和 disposed | 封闭 ready 与发布之间的关闭竞态。 |

### 5.11 发布包和安装

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D100 | 已锁定 | 程序目录为 `%LOCALAPPDATA%\Programs\LocalAIGateway` | 当前用户安装，无管理员权限。 |
| D101 | 已锁定 | 运行状态写 `%LOCALAPPDATA%\LocalAIGateway\runtime` | 程序文件保持只读式布局，状态与版本载荷分离。 |
| D102 | 已锁定 | 最终包内固定 `runtime/python/python.exe` | `--serve` 不猜测路径，不回退开发 assembly。 |
| D103 | 已实现并验证（M3f） | 完整包新增严格 `PACKAGE-MANIFEST.json` | 按路径、大小、SHA-256 验证所有安装载荷。 |
| D104 | 已实现并验证（M3f） | 不把 `runtime-state`、`.pyc`、`__pycache__` 打进包 | 这些属于运行时临时状态，不是程序载荷。 |
| D105 | 已实现并验证（M3f） | 安装先复制到同级随机 staging，验证后原子重命名 | 新安装失败不留下半成品目标。 |
| D106 | 已实现并验证（M3f） | 同 manifest 重复安装幂等；不同 manifest 明确冲突 | M3f 不提前实现升级覆盖，升级由 M5 管理。 |
| D107 | 已实现并验证（M3f） | 卸载核心只删除 manifest 拥有的文件，未知文件保留并报告 | 不对整个目录执行盲目递归删除。 |
| D108 | 已实现并验证（M3f） | manifest 拒绝绝对路径、`..`、重复/大小写冲突、额外文件和 reparse point | 防止路径逃逸、包夹带和链接攻击。 |
| D109 | 已锁定 | 最终用户安装器必须是自包含 EXE 逻辑 | 开发脚本可以是 PowerShell，但不能成为用户运行依赖。 |
| D116 | 已实现并验证（M3f） | 依赖中的敏感模式误报只能按完整文件 SHA-256 精确例外，canary 永不例外 | 两个上游文件含静态 private-key 标记文本；字节变化立即恢复 fail-closed。 |
| D117 | 已实现并验证（M3f） | 本地验收用 `Get-Process` 的可执行路径检查私有进程残留 | 沙箱拒绝 CIM；当前用户从 acceptance 根启动的进程路径可读，无权读取的无关系统进程不影响精确根检查。 |

### 5.12 客户端集成

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D110 | 已锁定 | 客户端稳定 alias 为 `aigw/default`、`aigw/claude/*`、`aigw/codex/default` | Profile 切换不要求重写客户端模型名。 |
| D111 | 已锁定 | Claude CLI 首选 `aigw run claude` | 不写 `~/.claude/settings.json`。 |
| D112 | 已锁定 | Codex CLI 使用有所有权标记的 TOML provider/profile 块和 Responses API | 只修改本工具拥有区域，不覆盖用户默认配置。 |
| D113 | 已锁定 | Codex 桌面首版不自动接入 | 未经明确授权不得修改 Codex 用户配置。 |
| D114 | 已锁定 | 外部配置写入前重新读取当前官方契约和本机配置，展示 diff、备份、确认 | 未知主版本或所有权冲突时拒绝修改。 |
| D115 | 已锁定 | unintegrate 只恢复仍由本工具拥有的字段 | 避免覆盖用户安装后自行修改的内容。 |
| D118 | 已实现、已验证（M4a） | Launcher 先验证请求和安装级令牌，再幂等启动 daemon，最后启动客户端 | 请求或令牌错误时不创建 daemon/客户端进程；令牌读取使用固定 Credential Manager target。 |
| D119 | 已实现、已验证（M4a） | 客户端必须是已存在的绝对路径，使用 `UseShellExecute=false` 与 `ArgumentList` | 不经 shell 解释用户参数，保留交互式标准流并原样返回子进程退出码。 |
| D120 | 已实现、已验证（M4a） | Launcher 自身只覆盖适配器指定的 base URL 与 token 子进程环境项 | 本地令牌不进入命令行、输出或父进程环境；进程创建后从托管启动计划移除。 |
| D121 | 已锁定、已实现（M4a） | M4a 不固化 Claude/Codex 环境变量名 | 后续适配器必须先重查官方契约；当前阶段不修改或运行真实客户端。 |
| D127 | 已实现、已验证（M4b） | Claude 使用 `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`；Codex 使用一次性 Responses custom provider | 依据 2026-09-07 当前官方契约，不写 Claude settings 或 Codex TOML。 |
| D128 | 已实现、已验证（M4b） | 已知客户端只解析绝对 PATH 目录中的 native `.exe`，拒绝 shell shim 与 reparse point | 保持 `UseShellExecute=false`，其他布局由显式 `--client` 承担。 |
| D129 | 已实现、已验证（M4b） | 已知适配器拒绝 model/provider 覆盖，CLI 静默透传子进程退出码 | 防止绕过固定本地路由，也不污染交互式客户端标准输出。 |
| D130 | 已实现、已验证（M4c） | Claude VS Code 只管理 JSONC `claudeCode.claudeProcessWrapper`；wrapper 首参数是扩展传入的 bundled Claude EXE | 保留注释和其他字段；launcher 仍固定本地模型/base URL/token 且不使用 shell。 |
| D131 | 已实现、已验证（M4c） | Codex 只预览独立 `$CODEX_HOME/aigw.config.toml` Responses profile | 默认 `config.toml` 不被读取或改写；文件只存 `env_key`，不存令牌。 |
| D132 | 已实现、已验证（M4c） | `integrate preview` 只读显式 fixture 或表示新建，不自动读取 target、不写文件 | 真实配置与客户端完全不在 M4c 验证边界；输出明确 `applyPerformed=false`。 |
| D133 | 已实现、已验证（M4c） | 版本范围和托管块所有权 fail-closed，冲突统一退出码 14 | Claude 2.x + VS Code 1.94+、Codex 0.134+ major 0；标记内混入用户内容也拒绝覆盖。 |
| D134 | 已实现、已验证（M4c） | 预览只输出托管块 diff 与 before/after SHA-256 | fixture 的非托管值不进入命令输出；为 M4d 并发校验留下稳定输入。 |
| D135 | 已实现、已验证（M4d） | apply 必须同时绑定 preview before/absent 与 after hash，并精确输入 `--confirm APPLY` | 确认在 target 读取前执行；过期或不同生成结果不得写入。 |
| D136 | 已实现、已验证（M4d） | apply 仅接受严格 UTF-8，更新时保留 BOM，拒绝 target/祖先 reparse point | 防止编码静默替换和链接路径越界；不自动创建目录。 |
| D137 | 已实现、已验证（M4d） | 同目录 write-through 临时文件；已有文件用 `File.Replace` 同时生成唯一备份，新文件无覆盖移动 | 保持同卷原子性，不覆盖既有备份。 |
| D138 | 已实现、已验证（M4d） | 变更前再次读取并校验；原子 backup 不匹配时恢复介入内容 | 覆盖常规并发窗口，并对最后一刻竞态提供自动回退。 |
| D139 | 已实现、已验证（M4d） | 失败清理临时文件；取消只在 mutation 前观察 | 避免半事务取消和垃圾文件；故障注入覆盖 replace/move 失败。 |
| D140 | 已实现、已验证（M4d） | apply 输出仅含 action、哈希、结果和 backup path | 不回显用户配置或备份内容；真实配置仍需另行精确授权。 |
| D146 | 已实现、已验证（M4e） | status 只检查一个显式 target，返回 absent/not-integrated/owned | 不扫描默认目录，不探测客户端，不建立隐式状态。 |
| D147 | 已实现、已验证（M4e） | status 不要求客户端版本，只识别既有 v1 所有权标记 | 客户端升级后仍可安全撤销；创建和更新继续经过版本门。 |
| D148 | 已实现、已验证（M4e） | unintegrate 绑定 status before/after hash 或明确 delete 计划，并精确确认 `UNINTEGRATE` | 确认先于 target 读取，变化后的计划不得执行。 |
| D149 | 已实现、已验证（M4e） | Claude/带注释 Codex 使用原子替换；纯受管 Codex 文件原子移动到恢复备份 | 保留非托管内容和 BOM，也不遗留空专用配置文件。 |
| D150 | 已实现、已验证（M4e） | 删除后验证备份 hash，最后一刻竞态在安全时恢复 | 失败时保留恢复材料，不静默丢失介入内容。 |
| D151 | 已锁定（M4e） | 当前不实现 integrate list | 无 registry 时 list 只能扫描真实配置，越过显式授权边界。 |

### 5.13 用量、托盘、备份、升级和卸载

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D160 | 已锁定、已实现、已验证（M5a） | 用量记录只接收 Token 和必要请求元数据，失败 fail-open | 统计故障不阻断模型请求。 |
| D161 | 已锁定、已实现、已验证（M5a/发布收口） | SQLite WAL 默认保留一年；固定 schema 日志单文件 10 MiB、保留 30 天、受管总量 100 MiB | 日志只含 allowlist 生命周期事件与 revision，当前用户 ACL、严格 owned 清理、reparse 拒绝和 fail-open 均有测试。 |
| D162 | 已锁定、已实现、已验证（M5b） | WPF Tray 展示状态、active profile、今日 Token 和控制动作 | 独立 EXE 和当前用户单实例提供 Windows 原生桌面体验。 |
| D163 | 已锁定、已实现、已验证（安装体验） | 登录自启使用当前用户 Runtime+Tray 成对计划任务；交互安装默认启用，JSON 必须显式选择 | 不使用需要管理员权限的 Windows Service；外部写入仍需精确授权。 |
| D164 | 已锁定、已实现、已验证（M5c） | 普通备份不含密钥；含密钥包使用 Argon2id + AES-256-GCM | 明确区分可移植配置和高敏感秘密备份。 |
| D165 | 已锁定 | 离线升级使用 Ed25519 manifest 签名、逐文件哈希、侧载健康检查和自动回滚 | 未配置正式私钥前只能验证 unsigned development 流程。 |
| D166 | 已锁定、已实现、已验证（M5e） | 九类卸载交互逐项询问；非交互每类必须明确 `keep|remove` 并精确确认 | 防止误删用户数据。 |
| D167 | 已实现、已验证（M5a） | 用私有 CPython 标准库 `sqlite3` 写用量库，不新增包 | 避免新的全局安装、NuGet/wheel 和缓存，同时复用已锁定运行时。 |
| D168 | 已实现、已验证（M5a） | callback 只读取 terminal `standard_logging_object` 的公开 alias、三类 Token 和受控错误码 | 不接触 prompt/response/tool/header/amount；未知 alias 与畸形 usage 不落库。 |
| D169 | 已实现、已验证（M5a） | callback/alias 映射为受保护 per-instance 文件，数据库为当前用户持久 `usage/usage.db` | 临时执行资产随候选回收；预期用量数据独立保留并继承当前用户 ACL。 |
| D190 | 已实现、已验证（M5b 查询核心） | 聚合读取复用私有 Python `sqlite3`，使用只读 URI/query-only，不新增包 | 避免新包缓存，并保证查询不迁移、修复或写入用量库。 |
| D191 | 已实现、已验证（M5b 查询核心） | 固定查询脚本随包发布；进程 `-B -I`、最小环境、5 秒超时并终止进程树 | 形成可重复使用且可回收的 CLI/Tray 读取边界。 |
| D192 | 已实现、已验证（M5b 查询核心） | `usage today` 使用本地午夜 UTC 边界、严格 JSON 和聚合一致性校验 | Tray 可复用同一 reader，未知 schema/reparse/畸形输出显式失败。 |
| D193 | 已实现、已验证（M5b Tray） | Tray 用 SID Mutex 单实例，生命周期持有 lease 到应用退出 | 防止重复托盘和过早释放互斥锁。 |
| D194 | 已实现、已验证（M5b Tray） | profile 切换先原子保存；运行中用既有 reload/蓝绿切换，停止时只保存 | 避免强制 restart，并保持配置真源与运行态语义明确。 |
| D195 | 已实现、已验证（M5b Tray） | UI 只消费 `IUsageSummaryReader`；刷新允许 daemon/config 成功而 usage 独立失败 | 不让 UI 绕过 SQLite 安全边界，也不让统计故障遮蔽控制状态。 |
| D196 | 已实现、已验证（M5b Tray） | 完整包将 WindowsDesktop 自包含载荷隔离于 `tray/` 并从父包根定位共享资产 | 保持同名异内容 runtime 文件的 fail-closed 碰撞检查。 |
| D197 | 已实现、已验证（M5c） | 普通备份只序列化严格配置；加密包只枚举配置 provider target，永不导出 runtime token | 避免秘密意外落盘和安装身份跨机器复制。 |
| D198 | 已实现、已验证（M5c） | create 绝对新路径、当前用户 ACL、同目录 flush + 无覆盖原子移动；inspect 只读 | 不覆盖用户文件，失败不留下临时载荷。 |
| D199 | 已实现、已验证（M5c） | restore 绑定 SHA-256、当前 revision 和 `RESTORE`，credentials 先写且失败逆序回滚，配置最后原子提交 | 防止过期计划、半恢复和隐式凭据删除。 |
| D200 | 已实现、已验证（M5c） | 复用私有 `cryptography` Argon2id 64 MiB/3/4 + AES-256-GCM，stdin 口令、30 秒进程树边界 | 不新增依赖，同时锁定可审计加密参数和失败语义。 |
| D201 | 已实现、已验证（发布收口） | 安装把程序根作为 owned 当前用户 PATH 条目加入 `HKCU\Environment\Path` | receipt 保证类型、原文、分隔符和既有目录可逆恢复；冲突不覆盖。 |
| D202 | 已实现、已验证（发布收口） | Start Menu 只创建指向安装包 Tray 的一个当前用户快捷方式 | 不创建 CLI/daemon 捷径；同名非 owned 目标 fail-closed。 |
| D203 | 已实现、已验证（发布收口） | Runtime 启动失败日志只增加有界稳定 error code 与已加载 revision | 提升可诊断性，不开放异常文本、路径、配置或敏感值写入日志。 |

### 5.14 M6 高级路由

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D170 | 已锁定、已实现、已验证（M6a） | LiteLLM 隐式 retry 关闭，Edge 最多重试两次 | 只重试响应前 YARP request/timeout 与 429、502、503、504；默认 100/200 ms，遵守最长 60 秒 `Retry-After`，更长值原样透传。 |
| D171 | 已锁定 | 400/401/403 不重试，流首字节后不重试或 fallback | 防止重复副作用和破坏流语义。 |
| D172 | 已锁定、已实现、已验证（M6b） | 每目标 closed/open/half-open 熔断 | 单 route revision 内以 provider + public alias 标识目标；5 次逻辑终态瞬态失败打开 30 秒，单 half-open 探针；控制协议 v2 状态进入 status/doctor 和 Tray。 |
| D173 | 已锁定、已实现、已验证（M6c/M6d） | 多目标只支持 ordered-fallback 和 weighted-round-robin | M6c 实现严格有序切换；M6d 按 route revision/alias 平滑加权选择单个可用目标，终态失败不跨目标 fallback。 |
| D174 | 已锁定、已实现、已验证（M6e） | 用户显式配置的 profile/provider/model 并发/RPM/TPM 多层限额取最严格值 | 缺省不施加本地限制；不实现日/月 Token quota 或阈值告警，供应商账户配额属于外部 API 契约。 |
| D175 | 已锁定、已实现、已验证（M6e） | Token 以实际复制响应中的 usage 流式记账，允许单次有限超额 | 不缓冲完整响应，不用估算金额或文本重算替代真实 usage。 |

### 5.15 验证和发布纪律

| ID | 状态 | 决策 | 原因与影响 |
|---|---|---|---|
| D180 | 已锁定 | 测试分纯单元、进程集成、假上游协议、真实 assembly、安装和打包烟测 | 不用单一层级结果替代真实生命周期证据。 |
| D181 | 已锁定 | CI 和普通 doctor 不访问真实模型 | 真实调用必须由用户显式授权。 |
| D182 | 已锁定 | 发布前验证断网、含空格、无全局运行时、非管理员、重复安装、断电和回滚 | 当前本机证据不能冒充这些尚未执行的环境门槛。 |
| D183 | 已锁定 | 每个里程碑必须有构建、相关自动化测试和实际烟测证据 | 如实区分已实现、已验证、待完成和受阻。 |
| D184 | 已锁定 | 外部删除、覆盖、配置写入前列出精确目标并确认 | 仓库内普通实现写入不扩大到用户配置或其他磁盘。 |
| D185 | 已锁定 | 大型开发下载、缓存、一次性发布和验收目录优先使用非系统盘；允许使用 H 盘。不创建远程仓库、不推送、不修改 Codex 配置 | 产品固定 Local AppData 路径和既有仓库/锁定制品不自动迁移；不以 reparse point 绕过 manifest、ACL、升级或卸载边界。 |

## 6. 已完成里程碑和实现证据

### M0：工程与 CLI 基线

状态：已实现、已验证、已提交（`74563a6`）。

交付：解决方案骨架、薄 CLI 入口、帮助/版本/语言/JSON/错误契约、本地构建与扫描、确定性 unsigned 自包含 ZIP。

关键验收：无全局 .NET 条件下解压 EXE 可运行；ZIP 两次生成哈希一致；无脚本载荷和密钥 canary。

### M1：配置、Profile、Provider、Model、凭据

状态：已实现、已验证、已提交（`1cda1b3`）。

交付：严格 schema v1、原子配置存储、ACL、跨进程 revision、完整 CLI CRUD、Credential Manager、隐藏/STDIN 密钥输入。

关键验收：真实隔离配置流程、真实精确 Credential Manager canary 写读删、稳定 JSON 和错误码、无密钥落盘。

### M2：最小可用网关和确定性假上游

状态：已实现、已验证、已提交（`095bac2`）。

交付：Kestrel/YARP Edge、认证、公开路径、模型校验、三协议文本与工具调用、SSE、头清理、错误映射、确定性假后端、独立 runtime EXE。

关键验收：真实 socket 回环、独立进程 smoke、固定端口冲突、断连/取消/超时、无全局 .NET 的解压包运行。

### M3a：LiteLLM 契约

状态：主体已提交（`3050ac8`）；后续 `run_server` 与 `-B` 修正已验证并纳入累计检查点 `a802cc5`。

交付：确定性无密钥 LiteLLM 配置、公开 alias 映射、环境计划、受控启动参数、`IBackendHost`、托管生命周期、Azure v1。

### M3b：哈希锁定私有文本运行时

状态：已实现、已验证并纳入累计检查点 `a802cc5`。

交付：109 个审计源、最终 lock、fresh assembly、许可证补充、四 provider/五类协议真实 LiteLLM 回环烟测、含空格和限网验证。

关键事实：assembly 为 10,699 文件、206,297,020 字节；enterprise、libsndfile、`.pyc` 和 `__pycache__` 均不在最终静态载荷或验收残留中。

### M3c：挂起启动和 Job Object

状态：已实现、已验证并纳入累计检查点 `a802cc5`。

交付：受限句柄继承、挂起进程、Job 分配、环境清零、真实父子进程树回收、私有实例目录清理。

### M3d：正式 daemon 与单实例

状态：已实现、已验证并纳入累计检查点 `a802cc5`。

交付：`--serve`、安装级客户端令牌读取、当前用户 Mutex、60 秒 readiness、完整 Edge/backend/Mutex 关闭顺序。

### M3e：Named Pipe 与蓝绿切换

状态：已实现、已验证并纳入累计检查点 `a802cc5`。

交付：当前用户 v1 控制 pipe、严格帧协议、status/reload/stop、并发状态查询、不可变 route lease、候选原子发布、旧实例 drain/stop 和关闭失败汇总。

### M3f：完整发布包与隔离安装核心

状态：已实现、已验证并纳入累计检查点 `a802cc5`。

交付：包含私有 CPython/LiteLLM 的完整确定性 ZIP、严格 package manifest、精确哈希敏感扫描例外、原子安装、同包幂等、异包冲突、失败清理、保守卸载和集中验收脚本。

当前最新证据：

- Release 全解决方案自动化测试 336/336：Core 90、Windows 53、CLI 49、Runtime 54、LiteLlm 27、Launcher 63。
- Release build：0 warnings、0 errors。
- 源码敏感信息扫描：M4e 当前 180 个非生成文件通过；扫描例外安全回归 4/4。
- 一次性自包含 M4c 包的 SHA-256 sidecar、Codex/Claude 两类 `integrate preview` 及目标未创建检查通过；临时 ZIP SHA-256 为 `c576701d1242a120a0e97017ebada7f65bc125505d30303b64a935347c914c90`，包根已删除，未覆盖 M3g 成品。
- 一次性自包含 M4d 包的 Codex/Claude create/update、backup、确认拒绝和零临时文件检查通过；临时 ZIP SHA-256 为 `04e82d0e8b856da62607fe4f38a20282c87be5d7bc38ee2c08e83feffbbcde42`，包根与匹配 fixture 均已删除。
- M4e 实际构建 CLI 的 Codex delete、Claude update、恢复备份、输出脱敏和零临时文件 smoke 通过；一次性完整包生成及 11,070 文件扫描通过，ZIP SHA-256 为 `0badda89873982ddc1ade81dde4f85de0bcfb4ba3f4cddd65bf33f7857c838f3`，全部临时根已删除。
- 两份完整 ZIP SHA-256 一致：`b5c7d8a31bc036983d1cf309121b196aae599edda2b24b1de30aae481b94ad26`；manifest 11,066 条，ZIP 134,469,563 字节。
- 隔离安装、真实 M3e 和卸载各 1/1 通过；验收后私有 Python 进程、acceptance root、runtime-state、`.pyc`、`__pycache__` 残留为 0。
- 没有远程 CI 证据，没有 clean-machine/VM 安装证据，没有正式签名证据。

## 7. 后续完整路线图

### M3f：完整发布包与隔离安装核心

状态：已实现并于 2026-08-31 完成本机隔离验证，已纳入累计检查点 `a802cc5`。

目标：把已经验证的私有 Python assembly 纳入确定性 ZIP，并建立不触碰真实用户状态的安全安装/卸载文件生命周期核心。

输入：

- 只读 `artifacts/m3b-runtime-assembly`。
- `runtime-manifests/m3b-text-runtime.lock.json`。
- assembly receipt、runtime environment、第三方许可证和现有 .NET notices。
- 不下载、不改变 109 个源输入、不写 H 盘。

包内布局：

```text
LocalAIGateway package root
|-- aigw.exe and .NET self-contained payload
|-- aigw-runtime.exe
|-- runtime/python/python.exe and private runtime
|-- manifests/assembly-receipt.json
|-- manifests/runtime-environment.json
|-- manifests/m3b-text-runtime.lock.json
|-- THIRD-PARTY-LICENSES/
|-- LOCAL-AI-GATEWAY-LICENSE.txt
|-- THIRD-PARTY-NOTICES.md
|-- DOTNET-LICENSE.txt
|-- DOTNET-THIRD-PARTY-NOTICES.txt
|-- PRIVATE-RUNTIME-COMPONENTS.json
|-- PACKAGE-MANIFEST.json
`-- UNSIGNED-DEVELOPMENT-BUILD.txt
```

明确不包含：`runtime-state`、`.pyc`、`__pycache__`、下载目录、wheel 源归档、包管理器缓存、PowerShell/CMD/BAT 运行依赖。

隔离安装核心：

1. 严格读取 package manifest。
2. 验证 source root 正好包含 manifest 声明的普通文件和允许的 manifest 文件。
3. 拒绝绝对路径、父目录、空路径、重复路径、Windows 大小写冲突和 reparse point。
4. 在 install root 同级建立随机 staging。
5. 逐文件复制、大小复核和 SHA-256 复核。
6. install root 不存在时，以目录重命名原子发布。
7. 已安装相同 manifest 时完整复核后幂等成功。
8. 已有不同 manifest 时明确冲突，不覆盖、不升级。
9. 任一步失败只清理由本次创建的 staging；清理失败保留精确路径并上报。
10. 卸载核心只删除 manifest 拥有的文件和变空目录；未知文件、reparse point 或打开文件均保留并明确失败。

M3f 不做：

- 不添加公开稳定 `aigw install/uninstall` 交互契约。
- 不写真实 `%LOCALAPPDATA%`。
- 不写 Credential Manager、计划任务、PATH、Start Menu 或外部客户端配置。
- 不实现升级替换、签名验证或断电回滚；这些属于 M5。

精确写入目标：

- 保留最终产物：`C:\claude-gateway\artifacts\m3f-package-output`。
- 一次性验收：`C:\claude-gateway\artifacts\m3f-install-acceptance`。
- 两者如开始前已存在则拒绝覆盖或删除。
- 验收结束只删除本次创建的 acceptance 目录，保留一个最终 ZIP 和 `.sha256`。
- 不删除现有 `repro-1`、`repro-2` 或其他历史 artifacts。

M3f 验收：

- 完整包独立生成两次，ZIP SHA-256 相同。
- package manifest 每个条目的路径、大小和 SHA-256 通过。
- 许可证、receipt、lock、Python 和 LiteLLM 必需数据存在。
- CLI 和 Runtime 版本 smoke 在禁用全局 .NET 条件下通过。
- 私有 Python import smoke 通过。
- 从隔离安装目录运行现有真实 M3e 蓝绿验收。
- 安装幂等、损坏包拒绝、额外文件拒绝、复制失败回滚、路径逃逸拒绝和保守卸载有自动化测试。
- 测试后私有进程、acceptance root、runtime-state、`.pyc` 和 `__pycache__` 残留为 0。

建议文件变更：

- 修改 `scripts/package.ps1`：接入私有 assembly、runtime notices 和 deterministic manifest。
- 新建 `scripts/verify-m3f-package.ps1`：集中完成两次打包、解压、隔离安装和真实 M3e 验收。
- 新建 `src/LocalAIGateway.Core/Installation/PackageManifest.cs`。
- 新建 `src/LocalAIGateway.Core/Installation/PackageManifestJson.cs`。
- 新建 `src/LocalAIGateway.Core/Installation/InstallationException.cs`。
- 新建 `src/LocalAIGateway.Windows/Installation/WindowsPackageInstaller.cs`。
- 新建对应 Core/Windows 自动化测试。

实际结果：两份独立完整 ZIP 的 SHA-256 均为 `b5c7d8a31bc036983d1cf309121b196aae599edda2b24b1de30aae481b94ad26`；manifest 共 11,066 个载荷条目，最终 ZIP 134,469,563 字节。M3f 验收时 Release 测试 199/199、构建 0 warnings/0 errors、源码扫描 131 个文件、扫描器安全回归 4/4；无全局 .NET smoke、私有 Python import、隔离安装、真实 M3e 和卸载通过，acceptance/私有进程/缓存残留为 0。最终输出只保留 ZIP 与 `.sha256`。后续 M3g 生命周期代码尚未重新打入该保留 ZIP。
- 更新 `THIRD-PARTY-NOTICES.md`、`README.md`、`TECHNICAL_DECISIONS.md`、`PROJECT_STATUS.md` 和 `HANDOFF.md`。

### M3g：真实当前用户安装与 daemon 生命周期

状态：令牌、路径、package + credential 事务、跨进程安装锁、生命周期 CLI、daemon 控制、只读 `doctor`、真实当前用户安装后 daemon 启停/卸载和 Task Scheduler action 闭环已验证；真实重新登录事件未执行。

目标：把 M3f 的文件安装核心接入真实当前用户安装、运行控制和登录启动。

计划内容：

- 默认程序目录 `%LOCALAPPDATA%\Programs\LocalAIGateway`。
- 状态目录 `%LOCALAPPDATA%\LocalAIGateway`。
- 生成高熵安装级客户端令牌并写入 `LocalAIGateway/runtime/client-token`。
- 令牌不得输出、记录或进入 package manifest。
- 接入 `install`、`start|stop|restart|status|doctor`。
- 使用当前用户 Named Pipe 控制正在运行的 daemon。
- 登录自启采用当前用户、非提升、交互令牌的 Task Scheduler 任务；不使用 Windows Service。
- 若安装事务后半段失败，按相反顺序撤销本次创建的任务、令牌和程序文件。
- 重复安装相同版本幂等；不同版本仍拒绝并引导后续 `update`。

已实现的仓库内准备层：

- `RuntimeClientTokenGenerator` 使用 CSPRNG 生成 32 字节熵并编码为 64 字符小写十六进制；结果对象不携带令牌。
- `CurrentUserInstallationPlan` 从 package source 和 Local AppData 计算固定程序、状态、runtime 和 credential target，拒绝相对路径、卷根及 source 重叠。
- `CurrentUserInstallationCoordinator` 保留格式正确的既有令牌；创建凭据失败时只回滚本次新安装；保守卸载部分保留时不删除凭据。
- 相关测试使用随机临时目录和内存凭据库，不写真实 `%LOCALAPPDATA%`、Credential Manager 或计划任务。
- 2026-09-07 全量验证为 254/254 测试、0 warnings/0 errors、145 个非生成文件扫描通过、扫描器安全回归 4/4。
- SID 级 `install` Mutex 覆盖安装、卸载和自启变更；顶层生命周期与 `autostart enable|disable|status` 已接线。交互式 `install` 以 `[Y/n]` 默认启用 Runtime+Tray；`install --json` 必须显式 `--autostart enable|disable`。
- Task Scheduler 固定任务路径为 `\LocalAIGateway.Runtime` 和 `\LocalAIGateway.Tray`，分别运行安装根 `aigw-runtime.exe --serve` 与 `tray\aigw-tray.exe`。两者均为当前用户、登录触发、交互令牌和最低权限；语义不匹配的任一同名任务 fail-closed 并保留。Runtime-only legacy 状态为 incomplete，重复 enable 只补齐 Tray。
- package、runtime credential 和成对任务使用同一安装锁。任务冲突在文件/凭据变更前拒绝；后段失败或取消只反序回滚本次新建的任务、凭据和程序文件，保留所有预存完整资源。
- `scripts/test-m3g-installed-runtime.ps1 -TestAutostart` 已提供只读精确目标预览和显式 `-Execute` 门，执行分支覆盖注册幂等、语义回读、Scheduler action 启动、撤销幂等及 finally 零残留清理。
- daemon start 只启动固定安装 EXE 并等待 Pipe ready；提前退出、超时和清理失败均有稳定错误测试。安装根内自卸载在任何状态变更前拒绝。
- 真实 daemon 验收候选 ZIP 两次独立生成哈希一致：`7465b105e0c544ec43ec069e48a68048ef5f413bfc69c77e39f8892d4ae7a231`，11,066 个载荷文件扫描通过。
- `doctor` 只检查本地存在性和 Pipe 状态，明确不执行模型探测或上游访问；实际 CLI 执行后真实程序/状态目录仍不存在。
- 真实安装首次创建程序和 runtime credential，复装完整复核且不轮换令牌；安装目录 EXE 的 doctor/status 通过，未启动 runtime。
- 从外部解压包卸载后，程序根、状态根、staging、安装进程、credential、候选 ZIP、sidecar、解压目录和 acceptance root 均不存在。
- 垃圾审计发现并删除 71 个历史 daemon 控制测试目录（36,412 字节）；xUnit 2.9.3 清理契约由未生效的 `IAsyncDisposable` 修正为 `IDisposable`，定向 5/5 和当时全量测试通过后 temp 残留为 0。
- 真实 Local AppData 复现并修复配置 `File.Replace` access denied；回退只在源/目标完整且异常类型精确匹配时采用双原子移动，current revision 2、backup revision 1、临时文件 0。
- daemon 原生启动器改为受限句柄列表和 `NUL` 三标准句柄，夹具确认不继承调用方管道；真实 `start --json` 可在 daemon 继续运行时返回。
- 安装后真实 token daemon 闭环通过：active revision 4、重复启动幂等、Pipe status、无令牌 401、stop、外部卸载及六类零残留；没有模型请求或上游访问。
- 包含 Task Scheduler 规范化修复的最终 M3g development ZIP 已两次独立重建并保留在 `artifacts/m3g-package-output`，SHA-256 为 `03a2c977d38ee868ee904018f479b4bd521fc1182d21239208dc15547689004a`。ZIP 为 134,504,162 字节，输出目录只含 ZIP 与 sidecar。

当时尚未完成的 Tray 真实 action 与 Runtime+Tray 成对 logon event 已在 2026-09-22 后续授权验收中完成；M5e 完整卸载辅助流程已完成本机隔离验证。

M3g 真实执行前必须再次列出并确认：

- 精确程序目录。
- 精确状态目录和拟创建文件。
- 精确 Credential Manager target。
- 精确 Task Scheduler 任务路径和 action。
- 是否修改用户 PATH 或创建 Start Menu shortcut。
- 验收后保留还是卸载测试安装。

M3g 不自动修改 Claude、VS Code 或 Codex 配置；这些属于 M4。

### M4：Launcher 与可逆客户端集成

状态：M4a 客户端无关 launcher、M4b `aigw run`、M4c 只读 preview、M4d fixture apply 和 M4e fixture status/unintegrate 已实现并验证；真实配置仍未触碰。

目标：让 Claude、Codex CLI 和通用客户端通过稳定 `aigw/*` alias 使用本地网关，同时保持外部配置可预览、可备份、可撤销。

实施顺序：

1. 实现 `start|stop|restart|status|doctor` 完整 CLI 控制体验。
2. 创建 Launcher 项目，只向目标子进程注入本地令牌。（M4a 已完成）
3. 实现 `aigw run claude|codex|--client`。（M4b 已完成）
4. Claude CLI 默认只使用 launcher，不写全局 settings。（M4b 已完成）
5. 重新核对当前 Claude/Codex CLI 和 VS Code 持久化契约。（M4c 已完成）
6. 实现 fixture 驱动的 `integrate preview`。（M4c 已完成）
7. 展示 diff、校验 source hash、备份并经确认后 `integrate apply`。（M4d fixture 已完成）
8. 用所有权标记实现 `status` 和 `unintegrate`。（M4e fixture 已完成；list 因无 registry 明确不实现）

验收重点：未知版本拒绝、用户修改不被覆盖、备份可恢复、令牌不进入文件、Codex 默认配置不被改写。

### M5：用量、Tray、备份、升级和完整卸载

状态：M5a-M5e 已实现、验证并合入集成线；M6 已开始，M6a 已完成。

目标：补齐长期运行产品体验和数据生命周期。

子阶段建议：

- M5a：LiteLLM usage callback、元数据边界、SQLite WAL、保留策略（已实现、已验证）。
- M5b：只读聚合核心、`usage today`、WPF Tray、状态、启停、reload 和 profile 切换（已实现、已验证）。
- M5c：普通备份与加密 secrets 备份（已实现、已验证）。
- M5d：Ed25519 离线升级、侧载健康检查、原子切换和自动回滚（已实现、已验证）。
- M5e：交互式/非交互式九类完整卸载、显式集成/备份目标、外置 worker 和原子 receipt（已实现、已验证）。

完整卸载必须分别处理程序、计划任务、客户端集成、runtime token、provider credentials、配置、用量、日志和备份，不能用一个递归删除替代用户选择。

M5e 的集成/备份删除不执行发现或目录扫描，只接受显式绝对路径并验证 ownership/schema/hash。安装根内 CLI
通过已安装 updater 调度当前用户受保护 Temp GUID worker；worker 等待调用进程退出、获取安装 Mutex、停止
daemon、完成所选类别并原子写 receipt。程序继续按 manifest 保守删除，状态目录拒绝 reparse point。真实卸载
后 worker/receipt 作为无 secrets 审计证据保留，必须在核对 receipt 与进程退出后按精确 GUID 路径清理。

### M6：Edge 重试、熔断、多目标路由和 Token 限制

状态：M6a 单目标重试、M6b per-target 熔断、M6c ordered fallback、M6d weighted round robin 和 M6e
可选分层并发/RPM/TPM 已实现并验证，M6 到此完成。原拟定 M6f 日/月 Token quota 与阈值告警已取消。

实施顺序：

1. 单目标重试分类和 `Retry-After`。（M6a 已实现、已验证）
2. per-target 熔断状态机。（M6b 已实现、已验证）
3. ordered fallback。（M6c 已实现、已验证）
4. weighted round robin。（M6d 已实现、已验证）
5. profile/provider/model 并发、RPM、TPM 限制。（M6e 已实现、已验证）
6. 日/月 Token quota 和阈值告警。（已取消，不实现）

所有流式请求首字节发出后禁止重试和 fallback。

M6a 当前结果：一次原始尝试加最多两次回放；429/502/503/504 和响应前 YARP request/timeout 才进入
重试，400/401/403/500 及客户端/请求体/响应体错误不进入。无 header 时确定性等待 100/200 ms；有效
`Retry-After` delta/date 按响应到达时间计算，超过 60 秒则原样返回而不提前重试。全部尝试持有同一 route
lease，并回放现有 8 MiB 上限内的严格 JSON 内存流；取消和首字节边界均有真实回环测试。

验证证据：`1478979` 上 Release 498/498、Runtime 86/86、最终源码敏感扫描 259 文件、自包含 Runtime EXE 和
ProductVersion smoke 通过。完整包 11,751 个 manifest 载荷逐项哈希通过，ZIP 共 11,753 文件，三次重建
SHA-256 均为 `c4563804a61765548c786ea99d1a16b680a6d9689db702bc2060e21a4872bc92`，随机检查根为 0。

M6b 当前结果：单 route revision 内每个 `providerId + public model alias` 使用独立 closed/open/half-open
状态机。连续 5 个逻辑请求在 M6a 尝试耗尽后仍为瞬态终态时打开 30 秒，open 由 Edge 返回稳定 503 和
`Retry-After`，到期仅允许一个完整重试链探针。非瞬态 HTTP 成功观察重置序列，取消及客户端/请求体/响应体
错误保持中立。严格控制协议 v2 把状态传给 status、只读 doctor 和 Tray，协议版本进入 Pipe 名隔离旧进程。

验证证据：`04f7ea8` 上 Release 506/506、源码敏感扫描 262 文件；M6b 专项覆盖五组 406 项测试、三个
自包含 EXE 和两次完整包。每包 11,751 个 manifest payload 逐项验证，五个包内 EXE 提交标记正确，两次
SHA-256 均为 `5af692be1cdd07e199afce6b208716e5ad4a48feb480b2dc8d3c5614e9ba6c3f`，随机检查根和进程残留为 0。

M6c 当前结果：schema v1 兼容增加每模型最多 8 项的 `fallbacks`，旧单目标 JSON 继续通过；主 backend 共享，
每个 fallback 以保持公开 alias 的独立私有 backend 运行。每个目标先完成完整 M6a 链，再按配置顺序切换；
open/忙碌 half-open 自动跳过，400 等非瞬态、取消、请求/响应体错误和首字节后断连绝不 fallback。

验证证据：`4aff995` 上 Release 518/518、源码敏感扫描 268 文件；M6c 专项 Core 3、CLI 1、Runtime 3 与
Runtime/CLI 自包含 EXE 通过。最高完整包专项五组 419 项、Runtime/CLI/Tray smoke 与两次 11,751 项
manifest 重建通过，SHA-256 均为 `be7477d025ff9731061fa919df8f4daf974e994285b5888261cf34a643ba1be8`，
随机检查根和进程残留为 0。

M6d 当前结果：schema v1 兼容增加 `routingStrategy` 和 1..100 的目标 `weight`，旧配置继续默认为
ordered fallback/权重 1；加权策略至少两个目标。每个 route revision/alias 使用 smooth weighted round robin，
仅当前 circuit 可用目标参与，open/忙碌 half-open 自动跳过且不积累恢复突发债务。每个逻辑请求只选一个目标，
该目标完成 M6a 重试链和 M6b 记账，终态瞬时失败不跨目标 fallback；reload 重置调度状态。

验证证据：`bcb7236` 上 Release 523/523、源码敏感扫描 270 文件；M6d 专项 Core 2、CLI 1、Runtime 6 与
Runtime/CLI 自包含 EXE 通过。最高完整包专项五组 423 项、Runtime/CLI/Tray smoke 与两次 11,751 项
manifest 重建通过，SHA-256 均为 `3bc84f529ec4c622887d71b4c242f99a37c690e69476756d782fd8d2b700f109`，
随机检查根和进程残留为 0。

M6e 当前结果：schema v1 兼容增加 profile/provider/model 可选 `limits`，并发、RPM、TPM 均有严格正值和
上界校验。profile/model admission 覆盖完整逻辑请求，provider 只在实际目标尝试时提交；所有适用层同时
检查，取消、异常和流完成均释放并发许可。RPM/TPM 使用滚动 60 秒窗口，状态由 coordinator 按逻辑 scope
共享并跨 reload 保留。TPM 从实际复制的 JSON/SSE usage 流式提取；有 TPM 的 chat 流强制 usage summary，
不改变公开 alias 或其他 stream options。CLI 提供三层 `set|clear`，未新增依赖或控制协议字段。

验证证据：`2297ddd` 上 Release 540/540、源码敏感扫描 276 文件；M6e 专项 Core 2、CLI 1、Runtime 14 与
Runtime/CLI 自包含 EXE 通过。最高完整包专项五组 440 项、Runtime/CLI/Tray smoke 与两次 11,751 项
manifest 重建通过，SHA-256 均为 `91f1452627657b1feb57af10d2afa6effaef2ae73504d7b3a2fd664a885adabf`，
随机检查根和进程残留为 0。

### 首版发布收口：operational log lifecycle

状态：已实现、已验证，已从 `codex/feature/release-log-lifecycle@19c053f` 通过 `4d8f438` 非快进合入。

Runtime 在取得单实例 Mutex 后初始化状态根 `logs/gateway.log`。JSONL schema 仅含 UTC 时间、固定 event/level
和可选 revision；固定 API 不接收任意文本。活动文件 10 MiB、30 天保留、受管总量 100 MiB，严格 owned
时间戳文件名清理，lookalike 不删除，reparse point 不跟随，当前用户 ACL 与 write-through flush 生效；所有
日志失败 fail-open。事件覆盖 daemon start/stop 和 configuration reload 成败。

验证证据：`aa80607` 上 Release 547/547、源码敏感扫描 279 文件；专项 12 项、真实私有 Runtime composition
和 Runtime 自包含 EXE 通过。最高完整包专项五组 447 项、Runtime/CLI/Tray smoke 与两次 11,751 项
manifest 重建通过，SHA-256 均为 `861db3ac2a477df5020795e0e629d24ccfae79c9ede77f34fc7b59821f02d28e`，
随机检查根和进程残留为 0。

### 首版发布收口：install experience 与成对自启

状态：已实现、已本机隔离验证；`codex/feature/release-install-experience@80ad89a` 已通过 `f799aa8` 非快进合入 `codex/develop`。

交互安装以 `[Y/n]` 默认启用 Runtime+Tray 成对登录自启；JSON 安装必须显式选择 enable
或 disable，缺失时在变更前拒绝。两个固定当前用户任务成对查询/启用/停用；同名冲突
fail-closed，legacy Runtime-only 状态可补齐。package、runtime credential 和任务在同一 SID 锁中
组合，失败/取消只回滚本次创建的资源。后续 shell integration feature 固定加入 owned 当前用户 PATH 条目，
并只创建指向 Tray 的 Start Menu shortcut；两者共享 receipt、冲突门和组合回滚边界。

验证证据：`fcac91b` 上 Release 560/560、源码敏感扫描 280 文件；专项 Core 7、Windows 36、
CLI 14 共 57 项，自包含 CLI help、选择门和版本绑定 smoke 通过。最终完整包五组 460 项、
Runtime/CLI/Tray EXE smoke 与两次 11,751 文件 manifest 通过，SHA-256 均为
`2f43c3ccac454fef00f59c4a51a8e51208583d8da1f655b34af591004706ae43`，随机根和进程残留为 0。
该轮未写真实 Task Scheduler/Credential Manager/LocalAppData；成对真实 action/logon 闭环已在 2026-09-22 后续精确授权后完成。

shell integration 实现提交 `f1de4b0` 上 Release 580/580、源码扫描 282 文件；最终完整包 manifest
11,751，SHA-256 `91c41e959b8ed9451eb967476e30e0ae725913ccb31d7a5760848bbaf4ae03de`，五个自包含
EXE smoke 通过。授权的真实当前用户验收确认 Tray task action 与 shell 创建/卸载零残留。Runtime 初次在
Task Scheduler 上看到 revision 0，后由同 SID/Session/`LOCALAPPDATA` 的任务探针证明 Codex 执行器写入的
marker 对独立 Scheduler 进程不可见。改由 Scheduler 上下文生成 revision 4 配置后，原始 direct action 与
Runtime+Tray 成对真实 logon event 均通过，随后完整卸载并清理为零残留。

### M7：未来自研 backend host 研究

状态：研究项，不进入首版生产。

目标：评估是否用自研 provider adapter 替代 LiteLLM。只有在兼容性、维护成本、协议覆盖、安全和离线体积有明确收益时才推进。M7 不应反向阻塞首版交付。

## 8. M3f 实施计划（已完成）

以下任务已按顺序完成并保留为实现/复验说明。

### Task 1：锁和 assembly 前置验证

- 运行 lock 生成器并核对固定 SHA-256。
- 运行下载/assembly verification 和 import smoke。
- 核对 assembly 无 runtime residue。
- 失败时停止，不修改锁或重新下载。

验收命令：

```powershell
./scripts/new-m3b-runtime-lock.ps1
./scripts/verify-m3b-runtime.ps1 -ImportSmokeTest
```

### Task 2：严格 package manifest 领域模型

- 先增加拒绝路径逃逸、重复、大小写冲突、错误 hash/size、未知字段的测试。
- 实现 schema v1 manifest 和严格 JSON。
- 增加 deterministic serialization 测试。

### Task 3：隔离 Windows 安装核心

- 先增加真实临时目录测试。
- 实现 source 验证、staging copy、copy 后复核和原子发布。
- 实现同包幂等与异包冲突。
- 实现失败清理和保守卸载。
- 使用故障注入覆盖复制/哈希/清理失败。

### Task 4：完整 deterministic package

- 扩展 package 脚本复制私有 runtime、receipt、lock、组件清单和许可证。
- 生成排序 manifest。
- 排除 runtime-state、缓存和下载源。
- 默认输出若存在则拒绝覆盖；仅显式内部 acceptance 路径由测试拥有。

### Task 5：完整包验收脚本

- 在 `m3f-install-acceptance` 内生成两份包并比较 hash。
- 解压一份并逐项验证 manifest。
- 执行 CLI/Runtime/Python smoke。
- 调用安装核心安装到含空格目录。
- 从安装目录运行真实 M3e acceptance。
- 卸载隔离安装并确认未知文件保护。
- 清理本次 acceptance root 并检查私有进程和缓存残留。
- 将唯一最终 ZIP 与 `.sha256` 输出到 `m3f-package-output`。

### Task 6：全量回归与文档同步

```powershell
dotnet test LocalAIGateway.slnx -c Release --no-restore
dotnet build LocalAIGateway.slnx -c Release --no-restore
./scripts/scan-sensitive-data.ps1 -ExcludeGenerated
./scripts/verify-m3f-package.ps1
git diff --check
git status --short
```

实际输出已全部通过，M3f 已标记为本机已验证。未经用户要求仍不提交、不推送。

## 9. 外部写入和删除矩阵

| 对象 | 当前授权状态 | 默认动作 |
|---|---|---|
| `C:\claude-gateway` 仓库 | 允许项目实现写入 | 可编辑源码、测试、脚本和必要文档。 |
| `artifacts/m3b-runtime-assembly` | 现有只读输入 | M3f 不修改、不删除。 |
| `artifacts/m3b-runtime-download` | 现有审计输入 | 不重新下载、不改变 109 文件。 |
| `artifacts/m3f-package-output` | 已创建并保留 | 当前只含最终 ZIP 和 hash；复验脚本拒绝覆盖。 |
| `artifacts/m3f-install-acceptance` | 已清理 | 验收完成后不存在；脚本只删除本次创建内容。 |
| 现有 `repro-1`、`repro-2` | 未授权删除 | 不触碰。 |
| H 盘 | 允许，并优先承载大型开发临时/保留制品 | 当前保留 `H:\LocalAIGateway\install-source-f1de4b0`；新增或删除仍需精确 owned 路径，避免把整个盘或宽泛目录作为清理目标。 |
| `%LOCALAPPDATA%\Programs\LocalAIGateway` | 已授权永久自用安装 | 当前存在，来自绑定 `f1de4b0` 的已验证完整包；程序路径契约仍固定于此。 |
| `%LOCALAPPDATA%\LocalAIGateway` | 已授权永久自用安装 | 当前存在 installation ownership state；尚无 Profile 配置，Runtime 未启动。 |
| Credential Manager runtime token | 已授权永久自用安装 | 当前存在；不得读取、输出或无故轮换。 |
| Task Scheduler `\LocalAIGateway.Runtime` | 成对真实 action/logon 验收已授权并完成清理 | 当前不存在；direct action、95 秒稳定观察和重新登录触发已验证。 |
| Task Scheduler `\LocalAIGateway.Tray` | 成对真实 action/logon 验收已授权并完成清理 | 当前不存在；手动 action 和重新登录唯一 owned 进程已验证。 |
| 当前用户 PATH / Tray Start Menu shortcut | 已授权永久自用安装 | owned PATH 条目和指向安装包 Tray 的 shortcut 当前存在，并由 installation receipt 管理。 |
| Claude/VS Code/Codex 配置 | 未授权 | 不修改。 |
| 远程仓库、push | 未授权 | 不创建、不推送。 |

## 10. 当前风险、限制和受阻项

- M3b-M4d 已纳入累计检查点 `a802cc5`；继续工作时仍不得用 destructive Git 命令丢弃后续未提交修改。
- 正式 Ed25519 私钥未配置，不能发布签名正式包。
- GitHub Actions 未实际运行，因为没有远程仓库。
- 尚未在全新、断网、无 .NET/Python/PowerShell 的 Windows x64 VM 完成安装级验证；项目所有者已为当前自用阶段主动延期该门槛。
- Codex 沙箱拒绝外网时的冷启动证据不能替代独立 OS 防火墙或 air-gap 验证。
- Runtime+Tray 手动 action 与真实重新登录触发均已验收并清理；Codex 执行器外部文件视图差异已通过
  Task Scheduler 上下文 staging 规避并由 marker 探针证实，不属于产品回归。
- 当前用户 PATH 和只创建 Tray Start Menu shortcut 的策略已锁定、实现并验证。
- 成对任务的仓库内定义、默认选择、回滚和自包含发布已完成，但这不能替代真实当前用户任务注册验收。

## 11. 待项目所有者决定的事项

以下内容没有被本文擅自锁定：

1. 正式 Ed25519 私钥的生成、托管和签名环境。
2. clean-machine/air-gap 验收在当前自用阶段不执行；若未来对外分发，再决定使用本地 VM、独立物理机还是 CI 自托管 runner。
3. M4c 当前 reviewed 范围为 Claude Code 2.x、VS Code 1.94+、Codex 0.134+ major 0；是否扩大范围必须重新核对官方契约并补测试。

## 12. 项目工作规则

- 每次只推进一个里程碑。
- 以实现和真实验证为主，不维护每日流水账或冗长追踪矩阵。
- 关键安全、配置、协议、安装和进程生命周期逻辑必须测试。
- 普通脚手架不强制仪式化测试。
- 不把“已编码”表述为“已验证”。
- 不把本机验证表述为 remote CI、clean-machine、air-gap 或正式签名已经通过。
- 下载未知依赖前列出目标、大小、SHA-256、许可证和空间影响并取得确认。
- 删除、覆盖外部配置或执行不可逆操作前列出精确目标并取得确认。
- 如果终端再次出现 `helper_unknown_error: setup refresh had errors`，立即停止，不修改文件并报告原始错误。
- 未经明确要求不使用 worktree、不频繁提交、不创建远程仓库、不推送、不修改 Codex 用户配置。

## 13. 审阅结论入口

项目所有者审阅本文时，建议重点确认：

1. 第 5 节技术决策是否符合长期产品方向。
2. 第 7 节 M3g 真实安装边界是否合适。
3. 第 8 节 M3f 复验说明是否充分。
4. 第 9 节写入/删除边界是否符合预期。
5. 第 11 节待决定事项是否需要现在锁定。

M3f 和 M3g 生命周期及 Task Scheduler action 闭环已按项目所有者批准完成并清理，M4a-M4e launcher/客户端适配器/预览/apply/status/unintegrate 也已完成仓库内 fixture 验证，M5a 用量写入、M5b 只读聚合/Tray、M5c 备份、M5d 离线升级和 M5e 完整卸载均已完成本机验证并合入。M6a-M6e 已完成本机验证并合入集成线，M6 到此完成；原拟定 M6f 日/月 quota 与阈值告警已取消。任何真实外部写入仍需精确目标与授权。
