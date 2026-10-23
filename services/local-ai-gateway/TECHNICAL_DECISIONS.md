> 历史来源文档：来自 local-ai-gateway 固定提交 `21017a1`，正文保留原文，仅供追溯。原机器路径、状态与操作记录不代表 Shuvi 当前环境。当前规则见主仓库 `docs/01-协作与工程约定.md`；接入和验证见本目录 README.md。

# Local AI Gateway 技术决策

状态：当前设计基线
更新日期：2026-09-22

本文只记录会长期影响实现与兼容性的技术决策。讨论过程不进入仓库；修改这些决策时，应同步更新本文。

## 1. 产品边界

- 产品名为 `Local AI Gateway`，命令行为 `aigw`。
- 仅支持 Windows x64，使用 .NET 10，自包含发布，最终用户离线安装、运行和升级，无需管理员权限。
- 首版以 LiteLLM 为后端；.NET 边缘层是稳定的外部入口。
- 首版正式支持 OpenAI Chat Completions、OpenAI Responses、Anthropic Messages。
- 首版只承诺文本对话、流式输出和工具调用。
- ARM64、多模态、GUI 配置表单、Codex 桌面接入、在线更新、金额统计和动态插件系统不在首版范围内。
- 当前项目不授予公开许可证；发布制品仍必须包含完整第三方许可证和 notices。
- 不复用旧实现和旧数据，不迁移旧密钥、用量或日志。

## 2. 组件和依赖边界

- `LocalAIGateway.Core`：配置领域模型、校验、profiles、providers、models、routes、limits、稳定错误模型和后端生命周期契约。
- `LocalAIGateway.Cli`：基于 System.CommandLine 的用户入口；业务逻辑委托给 Core 或控制面客户端。
- `LocalAIGateway.Runtime`：Kestrel/YARP 边缘代理、Named Pipe 控制面、单实例守护和生命周期管理。
- `LocalAIGateway.LiteLlm`：生成确定性的派生 YAML 兼容配置，准备、探测、排空并终止私有 LiteLLM 实例。
- `LocalAIGateway.Launcher`：启动 Claude、Codex 和通用客户端，仅向目标子进程注入本地认证信息。
- `LocalAIGateway.Tray`：WPF 托盘和只含 Token 的用量仪表盘。
- `LocalAIGateway.Updater`：离线升级、健康检查、回滚和卸载辅助进程。
- Windows ACL、凭据管理器、Named Pipe、Mutex、Job Object 等平台实现与领域逻辑隔离。

LiteLLM 只通过由 Core 所有的最小 `IBackendHost` 边界接入。该边界负责：准备候选实例、返回内部端点、健康探测、排空和停止。后端错误携带配置、凭据或不可用类别，以保留稳定退出码。首版不建立第三方插件加载机制。

请求链路固定为：

```text
客户端 -> 127.0.0.1:4000 (.NET Edge) -> 随机本地端口 (LiteLLM) -> 上游
                    |                         ^
                    +-- 认证、限制、重试 ------+
```

## 3. 网络与公开 API

- .NET 边缘层固定监听 `127.0.0.1:4000`。
- 端口冲突时返回运行冲突错误；不得改用其他端口，也不得终止占用进程。
- LiteLLM 只监听随机内部回环端口，并使用每个实例独立的临时内部令牌。
- 公开面仅包含三套核心文本 API、models、health 和 ready；其他 LiteLLM API 不透传。
- 公开路径固定为 `POST /v1/chat/completions`、`POST /v1/responses`、`POST /v1/messages`、
  `GET /v1/models`、`GET /health` 和 `GET /ready`；请求在路由判定前认证。
- 流式响应和工具调用必须保持各公开协议的兼容语义。
- 外部请求使用安装级随机本地令牌认证；令牌保存在 Windows Credential Manager。
- 安装级客户端令牌的稳定 Credential Manager target 为 `LocalAIGateway/runtime/client-token`；Runtime
  只读取，不自动生成、覆盖或输出该令牌。

M2 先建立稳定边缘代理边界：Kestrel/YARP 只向通过启动 readiness 的回环后端直连；请求体最多
8 MiB，并在转发前完成严格 JSON 和模型别名校验。客户端认证头、Cookie 和可伪造转发头不得进入
后端，后端 Cookie 和 Server 头不得返回客户端。上游 4xx/5xx 原样透传，不聚合响应、不自动重试；
超时和响应头前断连分别映射为 504 和 502，流首字节发出后不得追加网关错误正文。重试、熔断、
fallback 和 Token 限制仍属于 M6。

公开模型名在边缘层只做大小写不敏感校验和规范化，转发给后端时仍使用 active profile 中的公开
alias。每个私有 LiteLLM 实例只承载一个 profile，其 `model_name` 使用该公开 alias，
`litellm_params.model` 才映射 provider 和 upstream model；响应不需要反向替换内部模型名。

## 4. 配置领域模型

- 版本化 JSON 是唯一配置真源。
- LiteLLM YAML 是运行时派生文件，不允许手工编辑。
- 配置和状态目录为 `%LOCALAPPDATA%\LocalAIGateway`；程序目录为 `%LOCALAPPDATA%\Programs\LocalAIGateway`。
- 产品安装根和状态根继续使用上述当前用户 Local AppData 固定布局；不得用目录联接、符号链接或隐式路径重定向绕过 manifest、ACL、升级和卸载边界。开发期的大型下载、缓存、一次性发布和验收目录在路径所有权明确时优先使用非系统盘；当前允许使用 H 盘。既有仓库和已锁定制品不因该偏好自动迁移或删除。
- Profiles 完全隔离 provider、model、route、limit 和凭据引用；一次只激活一个 profile。
- 首版 provider 类型固定为：OpenAI-compatible、Anthropic、Azure OpenAI、本地端点。
- Azure OpenAI 使用 LiteLLM 1.95.0 已验证的 v1 组合：`model=azure/<deployment>`、资源根 `api_base`、`api_version=v1`。配置 endpoint 可写资源根或以 `/openai/v1` 结尾，编译器统一规范化为资源根。
- 远程端点强制 HTTPS；只有明确的本地端点类型允许私有地址 HTTP。
- 文本模型公开别名在首版严格一对一映射；未知模型拒绝请求。
- 每个 profile 必须有且只有一个默认模型。
- 多模态、自动 fallback 和负载均衡不进入基础配置阶段；多目标池由后续路由里程碑兼容扩展。
- 配置写入使用当前用户 ACL、跨进程锁、完整校验、原子替换和上一版本备份。
- 损坏 schema、未来 schema、悬空引用和并发写入必须明确失败，不能静默修复。

## 5. 凭据和隐私

- 上游凭据目标名为 `LocalAIGateway/<profile-id>/<provider-id>/api-key`。
- 密钥只允许通过隐藏输入或 `--secret-stdin` 写入，禁止命令行明文参数。
- 上游密钥不进入 JSON、YAML、命令行参数、日志或诊断输出；仅作为 LiteLLM 子进程环境变量存在。
- 本地客户端令牌由 launcher 从凭据库读取，只注入目标子进程。
- 产品不记录提示词、回复正文、工具参数、认证头或金额。
- 允许持久化的数据仅为必要请求元数据、真实 usage Token 和受控错误元数据。
- 日志、数据库、配置、备份、诊断包、进程参数和 JSON 输出均需执行 canary 泄漏测试。
- 默认不信任同机其他进程；但不承诺抵御已经控制当前 Windows 用户账户的恶意程序。

## 6. 运行时和离线交付

- Runtime 在读取凭据或准备后端前，先持有 `Global\LocalAIGateway.runtime.<current-user-SID>` 命名
  Mutex 对象的唯一创建租约，以保证同一 Windows 用户跨会话单实例；租约最后释放。使用受当前用户
  ACL 保护的 Named Pipe 作为控制面。
- 控制管道固定命名为 `LocalAIGateway.Control.v1.<current-user-SID>`，使用
  `PipeOptions.CurrentUserOnly`，不开放额外 TCP 管理端口。协议 v1 使用 4 字节 little-endian 长度前缀
  和 UTF-8 JSON，单帧最大 64 KiB、每连接一问一答；重复/未知字段、畸形 JSON、超大帧、未知版本/
  命令和慢请求必须返回稳定 `aigw_control_*` 错误。
- 控制命令首版只包含 `status`、`reload`、`stop`。状态只暴露运行状态、active profile、active/pending
  revision、切换状态和稳定 reload 错误码，不输出本地/内部令牌、端口或进程参数；`reload` 只重读
  配置真源，不接受客户端传入配置或密钥；`stop` 必须先写完响应，再触发优雅关闭。
- 使用 `CreateProcessW(CREATE_SUSPENDED)` 创建私有后端，先通过受限继承句柄列表将标准流定向到 `NUL`，再分配启用 `KILL_ON_JOB_CLOSE` 的 Job Object，最后恢复主线程；任何分配或恢复失败都必须终止进程并关闭原生句柄。状态必须持有真实 process/job handle，不能只依赖 PID。
- 配置变更采用蓝绿内部实例切换：新实例准备并通过 ready 后才切流；失败时保留旧实例并记录 pending
  配置版本。每个请求取得绑定 configuration/profile/model rewriter/internal token/backend instance 的不可变
  route lease，SSE 持有到流结束；活动 route 原子切换后旧 route 禁止新租约，等待在途租约归零，再
  drain/stop。相同 revision 幂等，旧 revision 明确拒绝，reload 与关闭使用同一生命周期门控。
- 后端 Prepare 返回不等于 ready。边缘层启动前以 100 ms 间隔执行有界 readiness 探测，默认最多
  60 秒；超时必须终止候选后端并释放单实例租约。
- 最终包携带可重定位 CPython 3.14.5、LiteLLM 1.95.0 和哈希锁定依赖。
- M3b 文本运行时选择以 `runtime-manifests/m3b-text-runtime.lock.json` 为唯一锁定清单：87 个 wheel、CPython 和 `cl100k_base.tiktoken`；下载审计集保留被排除 wheel，但 assembly 只能提取锁中 `wheels.included` 项。
- 禁止 LiteLLM 隐式联网更新；成本表必须本地固定，但产品不展示、估算或存储金额。
- LiteLLM 子进程必须使用参数列表而非 shell 命令行，清空继承环境后只加入必要 Windows 变量和受控变量；固定使用 `-B -I`、设置 `LITELLM_LOCAL_MODEL_COST_MAP=True`、禁用用户 site、字节码写入和遥测。TEMP、HOME、AppData 及第三方缓存根必须指向每个候选实例自己的 `runtime-state`。
- 离线运行时必须携带 LiteLLM 导入所需且经 SHA-256 锁定的 `cl100k_base.tiktoken`；不得依赖 tiktoken 首次运行联网下载。
- 完整发布包必须包含规范化、确定性序列化的 `PACKAGE-MANIFEST.json`，逐项声明除 manifest 自身外的所有普通文件路径、大小和 SHA-256。路径按 Windows 语义拒绝绝对路径、反斜杠、父目录、保留设备名、尾随点/空格、大小写冲突、manifest 自引用、额外文件/目录和 reparse point。
- 完整包只复制 M3b assembly 的 `runtime/python`、第三方许可证、锁、receipt 和 runtime environment；不得包含 `runtime-state`、`.pyc`、`__pycache__`、下载源、wheel 归档或包管理器缓存。
- 安装核心先完整验证 source，在目标同级随机 staging 逐文件复制并复核，最后通过目录重命名原子发布；相同 manifest 完整复核后幂等，不同 manifest 明确冲突且不得覆盖。失败只清理本次 staging，清理本身失败必须汇总原失败并报告精确路径。
- 卸载核心只删除大小和 SHA-256 仍匹配 manifest 的自有文件及随后变空的目录；未知或被修改内容必须保留并报告，不允许盲目递归删除安装根。
- 敏感扫描例外只能绑定到经过人工确认的完整文件 SHA-256；任一字节变化恢复 fail-closed，canary 命中永不适用例外。该机制只处理依赖源码/元数据中的静态私钥标记文本，不允许按路径或模式宽泛放行。
- 发布目标为 win-x64、自包含、无 trimming、确定性 ZIP。
- 最终用户环境不依赖全局 Python、.NET、PowerShell、网络或管理员权限。
- 开发阶段在没有正式 Ed25519 私钥时，只生成明确标记的 unsigned development 包。
- M2 的 `--m2-test-serve` 仅是显式环境变量门控的开发验证入口；它不构成安装、守护或凭据装载
  契约，M3 以 Named Pipe、Credential Manager 和私有 LiteLLM 生命周期替换该临时入口。
- M3a 只建立配置编译、启动规范和可测试的托管进程生命周期抽象，不下载或启动 Python/LiteLLM；
  真实哈希锁定依赖、进程工厂、Job Object、Mutex、Named Pipe、安装和蓝绿切换属于后续 M3 子阶段。
- M3d 正式入口为 `aigw-runtime.exe --serve`：程序目录下固定读取 `runtime/python/python.exe`，运行态
  只写 `%LOCALAPPDATA%\LocalAIGateway\runtime`；不得从开发 artifacts 或全局 Python 自动回退。
- M3f 只提供完整 unsigned ZIP 和不触碰真实用户状态的安装/卸载文件生命周期核心；不公开稳定 `aigw install/uninstall` 契约，不写真实 `%LOCALAPPDATA%`、Credential Manager、计划任务、PATH、Start Menu 或客户端配置。真实当前用户安装属于 M3g，必须另行确认精确外部目标。
- M3g 安装级客户端令牌固定由 CSPRNG 生成 32 字节熵，并编码为 64 字符小写十六进制；令牌不得出现在安装结果、日志、命令行、manifest 或诊断输出中。已存在且符合该生成格式的令牌必须保留，不得在重复安装时轮换；格式不符时在任何文件变更前 fail-closed。
- M3g 当前用户安装计划必须从绝对、非卷根的 package source 和 Local AppData 根推导固定程序目录、状态目录、runtime state、runtime EXE 与 Credential Manager target，并拒绝 source 与程序/状态目录重叠。
- M3g 安装事务先读取既有 runtime credential 和成对自启状态，并在任何文件或凭据变更前 fail-closed 拒绝任一同名冲突任务；然后调用 M3f 文件安装核心、创建缺失的 runtime credential，并按用户选择配置成对自启。后段失败或取消时，只能按反序回滚本次新建的任务、凭据和程序文件，不得删除安装前已存在的完整包、令牌或 owned 任务；回滚失败必须以 `aigw_install_rollback_failed` 汇总报告。
- M3g 保守卸载只有在程序包完全删除或本来不存在时才删除 runtime credential；若未知或被修改内容导致部分保留，凭据也必须保留。
- 安装、卸载和登录自启变更的整个任务/凭据/文件/回滚事务使用 `Global\LocalAIGateway.install.<current-user-SID>` 命名 Mutex 串行化；锁忙时在任何计划任务、凭据或文件变更前返回 `aigw_install_busy`，异常和回滚完成后必须释放。
- M3g 生命周期 CLI 固定为顶层 `install|uninstall|start|stop|restart|status|doctor` 和 `autostart enable|disable|status`。交互式 `install` 询问是否启用 Runtime+Tray 成对登录自启，`[Y/n]` 默认启用；`install --json` 必须显式传入 `--autostart enable|disable`，否则在任何变更前以 `aigw_install_autostart_choice_required` 拒绝。安装不自动启动进程；结果只暴露文件、凭据和成对自启状态，不暴露令牌。
- daemon `status/stop` 只使用既有当前用户 Named Pipe；`start` 只允许固定安装路径的 `aigw-runtime.exe --serve`，等待管道 ready。启动进程提前退出或超时时只终止本次创建的进程树；终止失败必须聚合启动与清理错误。
- M3g 首轮 `uninstall` 必须从安装目录外的原始解压包执行，在停止 daemon 后调用保守卸载。安装目录内自卸载在任何状态变更前以 `aigw_uninstall_running_from_install_root` 拒绝；专用卸载辅助进程留到 M5。
- `doctor` 固定为只读本地诊断：只检查固定安装根、package manifest、runtime EXE、配置文件存在性和当前用户 Pipe 状态；不读取上游密钥、不创建或修复文件、不启动 runtime，且必须明确报告未执行模型探测或上游访问。
- M3g 首轮真实当前用户验收只允许程序目录和 runtime credential 的创建/幂等复核/卸载，不创建配置、状态目录、计划任务、PATH 或 Start Menu，也不启动 daemon；验收后程序目录、凭据、staging、进程和项目临时根必须全部不存在。
- M3g 可交付物保留在 `artifacts/m3g-package-output`，只包含完整 unsigned development ZIP 和 SHA-256 sidecar。保留 ZIP 必须与真实安装验收候选字节哈希一致；打包工作目录在成功后连同空父目录清理。
- `File.Replace` 在目标文件、源临时文件仍完整但 Windows 返回 `UnauthorizedAccessException` 时，配置存储允许使用受限回退：先把旧配置写入同目录、受 ACL 保护的临时备份并以同卷 `File.Move(..., overwrite: true)` 原子发布备份，再以同一原语原子发布新配置。共享冲突、普通 I/O 错误、源/目标缺失和其他异常不得进入该回退。
- 配置读取不得先用 `File.Exists` 把不可访问路径折叠为“缺失”；直接读取后只有 `FileNotFoundException` 或
  `DirectoryNotFoundException` 返回 revision 0 空配置，拒绝访问必须保持 `aigw_config_access_denied`。
- daemon 进程必须使用 `CreateProcessW`、`PROC_THREAD_ATTRIBUTE_HANDLE_LIST` 和 `NUL` 标准句柄启动，只继承明确列出的句柄；不得继承调用方控制台或 stdout/stderr 管道，也不得使用 shell。该约束保证重定向环境中的 `aigw start --json` 在 daemon ready 后能够返回。
- 登录自启固定为当前用户两个根任务：`\LocalAIGateway.Runtime` 的 action 为 `%LOCALAPPDATA%\Programs\LocalAIGateway\aigw-runtime.exe --serve`、working directory 为程序根；`\LocalAIGateway.Tray` 的 action 为 `%LOCALAPPDATA%\Programs\LocalAIGateway\tray\aigw-tray.exe`、无参数、working directory 为 `tray` 子目录。两者都只允许当前 SID 的 `LogonTrigger`、`InteractiveToken`、`LeastPrivilege`；不得在 XML、命令行或任务元数据中放置密码或令牌。
- Task Scheduler 注册使用内存 XML 和 `TASK_CREATE`，不得以 update/force 覆盖同名任务。读取后只有固定来源、URI、SID、触发器、principal、action 和关键 settings 全部语义匹配才视为 owned；任一同名不同定义返回 `aigw_autostart_conflict` 并在安装/卸载任何其他变更前保留全部状态。enable 前必须完整验证 Runtime 和 Tray 载荷，仅创建缺失任务，任一创建失败或取消时删除本次新建任务；legacy Runtime-only 状态显示为 incomplete，再次 enable 可补齐 Tray。disable/uninstall 只能删除语义匹配的 owned 任务。
- Task Scheduler 会把 LogonTrigger 的 SID 规范化为当前 `DOMAIN\User`，省略值等于 COM 实际默认值的 `Enabled=true`、`RunLevel=LeastPrivilege` 和部分 settings，并写入 `UseUnifiedSchedulingEngine=true`。owned 判定只接受当前 SID 或当前账户名这一等价身份、已由 COM 逐项确认的安全默认值和固定 unified-engine 值；不同用户、权限、action 或非默认设置仍 fail-closed。
- 当前用户 shell 集成固定把程序根作为一个 owned 条目加入 `HKCU\Environment\Path`，并只创建指向 Tray 的
  `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Local AI Gateway\Local AI Gateway.lnk`。所有权记录固定为
  状态根 `installation/shell-integration.json`；PATH 值类型、原始文本、分隔符和既有空目录状态必须可逐字节恢复，
  既有同路径条目或同名非 owned 快捷方式一律 fail-closed，不覆盖、不删除。
- 安装后真实 token 的 daemon 闭环和 Runtime+Tray 成对真实登录验收已通过。2026-09-22 初次复测时，Codex
  执行器写入的状态文件对独立 Task Scheduler 进程不可见：同一 SID、同一 Session、同一 `LOCALAPPDATA` 的
  任务探针对 marker 返回不存在和 `DirectoryNotFoundException`，因此 Runtime 看到 revision 0；旧 M3g 包也
  同样复现。改由 Task Scheduler 上下文生成 revision 4 配置后，原始固定 action
  `aigw-runtime.exe --serve` 手动启动成功并稳定运行超过 95 秒；随后注销/重新登录同时触发 Runtime 与 Tray，
  Runtime 日志记录 `daemon.started` revision 4，Tray 只启动唯一 owned 安装路径进程。最终卸载后安装根、状态
  根、任务、Credential、PATH 条目、快捷方式和进程均为 0。该证据不替代干净普通用户/air-gap 环境验收。
- 创建外部临时目录的自动化测试必须使用当前测试框架实际识别的清理生命周期，并在定向及全量回归后复查命名残留为 0；仅实现运行时接口但未被测试框架调用不能视为已清理。
- 进程测试夹具不得在 marker 文件仍持有排他写句柄时发布其最终名称；必须先写同目录临时文件、关闭句柄，
  再原子重命名，避免 Windows 上“已存在但尚不可读”的共享冲突竞态。

## 7. CLI 稳定契约

全局选项为 `--json`、`--lang`、`--no-color`、`--verbose`。默认输出中英文人类可读文本；JSON 字段、错误代码和机器契约固定使用英文。

主要命令族：

- `profile create|list|show|use|delete`
- `provider add|list|show|update|set-secret|remove`
- `model add|list|show|update|remove|set-default`
- `config show|path|validate`
- `install`、`start|stop|restart|status|doctor`
- `integrate preview|apply|list|status|unintegrate`
- `run claude|codex|--client`
- `usage show|export`
- `autostart enable|disable|status`
- `backup create|restore`、`auth rotate`、`update`、`uninstall`

退出码固定为：`0` 成功、`2` 参数错误、`10` 配置、`11` 凭据、`12` 运行冲突、`13` 后端不可用、`14` 客户端集成冲突、`15` 文件或权限、`20` 上游探测、`70` 未预期内部错误。

`doctor` 默认不能产生模型请求；只有用户显式执行 `doctor --probe <model>` 并确认后才访问上游。

## 8. 客户端集成

- 稳定虚拟模型包括 `aigw/default`、`aigw/claude/*` 和 `aigw/codex/default`。
- 每个 Local AI Gateway profile 独立绑定虚拟模型；切换 profile 不重写客户端文件。
- `aigw run` 和 `aigw-launcher.exe` 必要时自动启动网关，并只向目标子进程注入本地令牌。
- M4a 的 launcher 编排顺序固定为：先严格校验绝对客户端路径、工作目录和适配器提供的环境变量名，
  再从 `LocalAIGateway/runtime/client-token` 读取并校验安装级令牌，然后幂等启动固定安装 daemon，
  最后创建目标客户端；请求或令牌无效时不得启动任何进程。
- 目标客户端必须使用 `UseShellExecute=false` 和 `ProcessStartInfo.ArgumentList`，保留调用方控制台标准流，
  等待子进程并原样返回退出码；令牌不得进入 launcher 命令行、输出或父进程环境，进程创建后从启动计划中移除。
- M4a 只建立客户端无关的 launcher 核心和 `aigw-launcher.exe`；Claude/Codex 的环境变量名由后续适配器在
  重新核对当前官方契约后提供，当前阶段不猜测或固化外部客户端字段，也不修改任何客户端配置。
- M4b 已于 2026-09-07 重新核对官方 CLI 契约。Claude 子进程固定注入
  `ANTHROPIC_BASE_URL=http://127.0.0.1:4000` 与 `ANTHROPIC_AUTH_TOKEN=<runtime-token>`，并显式使用
  `--model aigw/default`；依据为 Anthropic 的 LLM gateway 和 CLI 文档：
  <https://code.claude.com/docs/en/llm-gateway-connect>、<https://code.claude.com/docs/en/cli-usage>。
- Codex `aigw run codex` 不写 TOML，而以一次性 `--config` 建立 `aigw` custom provider：base URL 为
  `http://127.0.0.1:4000/v1`、`env_key=AIGW_CODEX_API_KEY`、`wire_api=responses`，模型固定为
  `aigw/codex/default`。这是依据 OpenAI 当前 custom provider、`-c/--config` 和配置优先级文档形成的
  实现推论：<https://learn.chatgpt.com/docs/config-file/config-advanced>。
- 已知客户端适配器拒绝用户通过 `--model` 覆盖固定 alias；Codex 还拒绝 `-c/--config`，防止绕过本地
  provider。`aigw run` 原样返回客户端退出码且不追加成功输出；launcher 错误仍使用稳定网关错误。
- 已知客户端只从 PATH 的绝对目录解析真实 `claude.exe`/`codex.exe`，拒绝 reparse point，不执行
  `.cmd`/`.bat` shell shim；需要其他布局时使用带绝对路径和显式环境变量名的通用 `--client`。
- M4b 不自动设置 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`，因为它还会关闭更新检查、错误报告等
  非推理功能；当前保证模型请求经固定 base URL，不能据此声称 Claude 的所有非必要流量均被网关接管。
- OpenAI 自 Codex 0.134.0 起不再由 `--profile` 读取 `config.toml` 内旧式 `[profiles.<name>]`，后续
  持久化集成预览必须采用当前 `$CODEX_HOME/<profile>.config.toml` 契约或其他有明确所有权的当前格式，
  不得沿用旧式 profile 块：<https://learn.chatgpt.com/docs/config-file/config-reference>。
- Claude CLI 通过 `aigw run claude` 使用，不写 `~/.claude/settings.json`。
- Claude VS Code 只配置受支持的 process-wrapper 路径。
- Codex CLI 使用带所有权标记的 TOML provider/profile 块和 Responses API，不覆盖用户默认配置。
- Codex 桌面应用首版不自动接入，当前用户 Codex 配置未经明确授权不得修改。
- VS Code 使用保留注释的 JSONC 编辑；Codex 只修改 `BEGIN/END` 标记块。
- 所有客户端文件写入必须先重新读取当前官方契约和本机配置，再展示差异、备份并确认。
- 未知客户端主版本或字段所有权冲突时拒绝修改；unintegrate 只恢复仍由本工具拥有的字段。
- M4c 已于 2026-09-08 重新核对持久化契约。Claude VS Code 只预览 JSONC 根属性
  `claudeCode.claudeProcessWrapper`；依据 Anthropic 当前 IDE 文档，VS Code 版本下限为 1.94，扩展把
  捆绑 Claude 可执行文件作为 wrapper 首参数传入：<https://code.claude.com/docs/en/ide-integrations>。
- `aigw-launcher.exe` 的 VS Code wrapper 入口将该首参数作为实际 Claude EXE，其余参数逐项保留，并继续
  固定 `--model aigw/default` 及子进程局部 `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`；不经 shell。
- Codex 持久化预览只允许独立 `$CODEX_HOME/aigw.config.toml`，不读取或改写默认 `config.toml`；文件固定
  Responses provider、`aigw/codex/default` 和 `env_key=AIGW_CODEX_API_KEY`，不保存令牌值。依据 OpenAI
  当前 profile-file 与 custom provider 文档：<https://learn.chatgpt.com/docs/config-file/config-reference>、
  <https://learn.chatgpt.com/docs/config-file/config-advanced>。
- M4c `integrate preview` 必须显式提供 fixture `--source`（省略只表示创建）和表示用绝对 `--target`；
  不自动读取 target、不写文件、不探测或运行真实客户端。客户端/host 版本由调用者显式提供；当前只接受
  Claude Code 2.x + VS Code 1.94+，以及 Codex 0.134+ 且 major 0，其他 major fail-closed。
- JSONC/TOML 使用明确 v1 BEGIN/END 标记。只在标记结构和其中全部字段严格符合本工具生成形状时允许预览
  更新；无标记的同名字段、重复/损坏标记、标记内用户内容或 Codex 独立文件中的非注释外部 TOML 都按
  客户端集成冲突退出码 14 拒绝。预览只输出托管块 diff 和内容哈希，不回显非托管配置值。
- M4d `integrate apply` 必须绑定 preview 的 expected before/after SHA-256；现有目标使用 before hash，新建目标
  使用 `--expect-absent`，二者互斥。`--confirm` 必须精确为大写 `APPLY`，且在读取 target 前验证。
- apply 重新读取严格 UTF-8 target、重新执行 M4c 版本和所有权编译，并比对两个哈希；目标出现、消失、
  内容变化或生成结果变化都以 `aigw_integration_stale_preview` fail-closed。已有 UTF-8 BOM 必须保留。
- target 父目录必须已存在，目标与既有祖先目录不得经过 reparse point。写入先在同目录创建 write-through
  唯一临时文件；已有文件使用 `File.Replace` 原子替换并让 Windows 同时生成唯一恢复备份，新文件使用无覆盖
  `File.Move`。不创建父目录、不覆盖备份。
- 取消只在变更前观察；变更开始后完成事务。普通 replace/move 失败保留旧目标并清理临时文件；若原子 backup
  的哈希证明最后一刻出现并发变化，必须恢复该介入内容，再以 stale 失败。文件/权限类错误使用退出码 15。
- apply 输出不包含 target/backup 内容，只包含 action、before/after 哈希、是否应用和备份路径。M4d 仅在
  disposable fixture 和一次性包内验证；真实 Claude/VS Code/Codex 配置仍需另行列出精确目标并取得授权。
- M4e `integrate status` 只读取调用者显式给出的单个绝对 target，不扫描默认配置位置、不探测客户端、
  不建立注册表。状态只分为 `absent`、`not-integrated`、`owned`；损坏/重复标记、非托管同名字段或无法
  安全解析的内容继续 fail-closed。status 输出撤销 action、before/after SHA-256 和不含非托管内容的 diff。
- status 不要求客户端版本：它只识别本工具既有 v1 所有权标记，使客户端升级后仍能安全撤销旧集成；
  新增或更新集成仍必须通过 M4c 的 reviewed version gate。
- M4e `integrate unintegrate` 必须绑定 status 的 before/after SHA-256；纯受管 Codex 专用文件使用
  `--expect-delete`，其他更新使用 after hash。`--confirm` 必须精确为大写 `UNINTEGRATE`，且在读取 target
  前验证。target 或撤销计划变化统一以 stale preview 拒绝。
- Claude 撤销只删除严格受管 JSONC 块并保留非托管字段、注释、换行与 UTF-8 BOM；含外部注释的 Codex
  专用文件只删除受管块。更新沿用同目录 write-through + `File.Replace` 和唯一恢复备份。
- 仅含受管块的 Codex 专用文件不写成空文件，而是同目录原子移动到唯一恢复备份；移动后校验备份 hash，
  最后一刻竞态在 target 未被占用时自动恢复。失败保留恢复文件，临时文件必须清理。
- `integrate list` 在 M4e 明确不实现：当前没有持久化集成登记，自动扫描真实配置会越过 fixture 和授权边界；
  若未来需要 list，必须先设计当前用户 registry、事务同步和隐私边界。M4e 仍只在 disposable fixture 验证。

## 9. 用量和产品运维

- M5a 启用且只启用项目自有的 LiteLLM 异步 `CustomLogger`；仍关闭第三方 success/failure callback、重试和
  telemetry。回调只读取 terminal `standard_logging_object` 的公开 `model_group`、真实
  `prompt_tokens`/`completion_tokens`/`total_tokens` 与受控 `error_code`，不读取或持久化 prompt、response、
  工具参数、认证信息、请求方标识、上游模型名、endpoint 或任何金额字段。
- profile/provider 归属来自编译器生成的最小 alias 映射。回调 Python 源码以程序集嵌入资源随包携带，
  每实例写入受保护的候选目录；映射文件也位于该目录并随实例停止删除。两者都不含凭据。
- 用量持久目标固定为 `%LOCALAPPDATA%\LocalAIGateway\usage\usage.db`；父目录使用当前用户 ACL。SQLite
  使用私有 CPython 自带的标准库 `sqlite3`，不新增 NuGet、wheel、全局安装或包缓存。
- schema v1 仅含 UTC 毫秒时间、profile/provider ID、公开 model alias、success/failure、input/output/total
  Token 和可选受控错误码。成功事件强制三项真实 Token；失败且未报告 usage 时三项同时为 NULL，不伪造 0。
  数据库强制 WAL、`synchronous=NORMAL`、250 ms busy timeout 和 STRICT table；
  不识别的未来 `user_version` 只拒绝写入，不迁移或破坏数据。
- 保留清理每天最多执行一次，删除早于当前本机 UTC 一年的事件。缺失/畸形 payload、未知 alias、无效 Token、
  锁冲突、I/O、schema 或 callback 异常均 fail-open，不改变模型请求结果。
- callback 注册、异步 hook 和 terminal `standard_logging_object` 字段依据 LiteLLM 当前官方文档复核：
  <https://docs.litellm.ai/docs/observability/custom_callback>、
  <https://docs.litellm.ai/docs/proxy/logging>、
  <https://docs.litellm.ai/docs/proxy/logging_spec>。
- M5b 只读聚合复用私有 CPython 标准库 `sqlite3`，不新增 NuGet/wheel。固定查询脚本随 Windows 组件发布到
  `runtime-tools/aigw_usage_query.py`，使用 `file:` URI `mode=ro`、`PRAGMA query_only=ON`、250 ms busy timeout，
  只接受 schema v1，并且绝不创建、迁移、checkpoint、prune 或修复数据库。
- .NET 读取器只允许固定 state 根下的 `usage/usage.db`，拒绝已有 reparse 目标；查询窗口必须为正且不超过
  366 天。私有查询进程使用 `-B -I`、最小环境、5 秒超时和整棵进程终止；stdout 受 1 MiB 上限和严格
  JSON/聚合一致性校验。数据库不存在返回 `databasePresent=false` 和零值，不启动 Python、不创建目录。
- `aigw usage today` 从当前用户时区的本地午夜换算 UTC 边界，只读显示 request/success/failure、三类 Token、
  profile/provider/public alias 分组和最多 20 条受控错误元数据；不启动 daemon、不读取 prompt/response/金额。
- WPF Tray 是独立的 `aigw-tray.exe`，使用当前用户 SID 派生的 `Global\LocalAIGateway.tray.<SID>` Mutex
  保证单实例。它显示 daemon 状态、Runtime 报告的 active profile、配置选择和今日 Token；用量只通过
  `IUsageSummaryReader` 读取，不直接打开、迁移或写 SQLite。
- Tray 的 start/stop/restart/reload 复用现有 daemon controller 和当前用户 Named Pipe。profile 切换先经
  `GatewayConfigurationManager` 原子保存配置真源；daemon 运行时发送现有 `reload`，由蓝绿 coordinator 在
  新候选 ready 后切流，停止时只保存并留待下次 start 加载，不以强制 restart 代替 reload。
- 完整包把 WPF/WindowsDesktop 自包含载荷隔离在 `tray/` 子目录，避免与根目录 CLI/Runtime 的 .NET
  runtime facade 发生同名异内容碰撞；Tray 从受 manifest 约束的父包根定位共享私有 Python 查询资产。
- Runtime operational log 固定写入 `%LOCALAPPDATA%\LocalAIGateway\logs\gateway.log`，采用一行一个对象的
  UTF-8 JSONL。schema 只允许 UTC 时间、固定 allowlist 事件名、固定 level、可选配置 revision 和受限稳定
  error code；error code 只接受最多 128 个 ASCII 字母、数字、下划线或连字符。日志不接受
  任意 message/exception 字符串，因此请求、响应、prompt、Token、密钥、endpoint、模型和配置值均无写入入口。
- operational log 在 daemon 取得当前用户单实例 Mutex 后才初始化，记录 start/start-failure、stop/stop-failure
  和 reload success/failure。日志 I/O、ACL 或清理失败必须 fail-open，不改变网关数据面和生命周期结果。
- 活动日志严格限制为 10 MiB，超过前按 UTC 时间加四位序号无覆盖轮转；轮转文件保留 30 天，全部受管日志
  总量上限为 100 MiB。只删除严格匹配自身时间戳命名的顶层轮转文件，lookalike/未知文件保持不变；日志目录
  或活动文件为 reparse point 时拒绝跟随。目录和文件应用当前用户专属 ACL，每条事件 write-through flush。
- WPF 托盘显示运行状态、当前 profile、今日 Token，并提供启停、重启和 profile 切换。
- 仪表盘提供 7/30/90/365 天趋势、profile/provider/model 分组、最近错误元数据及 CSV/JSON 导出。
- 安装时询问登录自启，默认启用当前用户范围的守护进程和托盘计划任务。
- M5c 普通备份只含严格 schema v1 配置，不读取或导出任何 Credential Manager 值；加密备份只枚举配置中
  规范化 provider target 下实际存在的凭据，安装级 runtime client token 永不进入任何备份。
- `backup create` 只接受绝对路径、要求父目录已存在、拒绝 reparse 路径和既有目标；先在同目录创建、flush
  并收紧为当前用户 ACL 的临时文件，再无覆盖原子移动。`backup inspect` 只读返回 SHA-256、revision 和计数。
- `backup restore` 必须同时绑定 inspect 返回的 SHA-256、当前配置 revision 和精确 `RESTORE` 确认。provider
  credentials 先逐项保存原值再写入，配置最后通过既有锁和原子存储提交；失败时逆序恢复已改凭据。包内未列出
  的凭据一律保留，不以 restore 隐式删除孤立或安装级凭据。
- `--include-secrets` 固定使用私有 Python `cryptography` 的 Argon2id（64 MiB、3 iterations、4 lanes、32-byte
  key）和 AES-256-GCM；16-byte salt、12-byte nonce 及 KDF/cipher 头纳入认证。口令只经隐藏输入或
  `--passphrase-stdin` 进入最小环境的 `-B -I` 进程 stdin；30 秒超时/取消均回收进程树，明文缓冲用后清零。
- M5d 离线升级只接受严格、规范化的 package manifest/signature/trust-store。Ed25519 签名绑定 manifest
  SHA-256 和固定域分隔消息，信任根来自已安装包的 `TRUSTED-UPDATE-KEYS.json`；目标版本必须严格更新。
  正式流程拒绝未签名包，只有显式 `--allow-unsigned-development` 才允许 canonical development descriptor。
- `update inspect` 只读验证当前包、候选包、版本和信任结果；`update apply` 还必须绑定 inspect 返回的 manifest
  SHA-256 与精确大写 `UPDATE`。CLI 只调用已安装的独立 updater，不直接替换程序文件。
- updater 验证后把自身复制到当前用户状态根的受保护 `update-workers/<GUID>`。外置 worker 用 Windows
  `CreateProcessW` 的显式 handle list、三个 `NUL` 标准句柄和最小环境启动，并等待 bootstrap updater 与调用
  CLI 退出后才切换安装树；完成状态通过受保护的原子 `update-receipts/<GUID>.json` 返回。
- 更新事务逐文件 staging 并执行 CLI、Runtime、Launcher、Tray、Updater 和私有 Python 的 side-load 健康
  检查；运行中的 daemon 先停止。旧树以同卷 `Directory.Move` 移至唯一 rollback 根，候选原子发布并再次健康
  检查，随后恢复 daemon。发布后任何健康/启动失败都移出候选、恢复旧树和原运行状态；清理只接受精确 owned
  GUID transaction/worker 路径，绝不递归删除任意调用方路径。
- M5e 完整卸载把程序文件、登录计划任务、客户端集成、runtime token、provider credentials、配置、用量、
  日志和备份固定为九个独立类别。交互模式逐项询问；非交互模式必须为九类分别给出 `keep|remove`，并要求
  精确大写 `UNINSTALL`。
- 卸载不扫描客户端配置或备份目录。集成删除只接受显式 Claude VS Code/Codex 绝对目标，并复用既有
  ownership/hash/unintegrate 事务和恢复备份；备份删除只接受显式路径且必须通过严格 Local AI Gateway
  备份识别。凭据只枚举 `LocalAIGateway/` target 名称，不读取秘密值。
- 从已安装 `aigw.exe` 删除程序时，CLI 只调度已安装 updater；updater 将载荷复制到当前用户受保护的
  `%LOCALAPPDATA%\Temp\LocalAIGateway-Uninstall\uninstall-workers/<GUID>`，用受限 handle list、最小环境和
  显式参数启动，等待 bootstrap/CLI 退出后执行。目标必须匹配固定 Local AppData 程序/状态布局，完成状态
  原子写入同一受保护根下的 `uninstall-receipts/<GUID>.json`。
- 程序删除仍只移除 manifest 中大小和 SHA-256 未变的 owned 文件；配置、用量、日志和 operational state
  只处理各自固定 owned 名称/子树，并在任何删除前拒绝 reparse point。卸载 worker 不能安全递归删除仍在
  运行的自身载荷，因此 worker 目录和 receipt 作为无 secrets 的完成/恢复证据保留；消费者必须先核对 receipt
  和 worker 退出，再按 receipt 对应的精确 GUID 路径清理，禁止把任意 Temp 根作为递归删除目标。

## 10. 重试、路由和 Token 限制

- 关闭 LiteLLM 隐式重试，由边缘层统一重试。
- 最多重试两次，仅覆盖连接建立失败、429、502、503、504，并尊重 `Retry-After`。
- 400、401、403 不重试；流式响应首字节发出后绝不重试或故障转移。
- M6a 的两次重试表示一次原始尝试加最多两次回放。无有效 `Retry-After` 时使用确定性的 100 ms、
  200 ms 退避；`Retry-After` 的 delta/date 按响应到达时间计算。若要求等待超过 60 秒，则不提前重试，
  而是原样返回该响应，避免单个请求无限占用本地 Edge。
- HTTP 状态只重试 429、502、503、504；YARP 转发错误只重试发生在响应开始前的 `Request` 和
  `RequestTimedOut` 类别，客户端/请求体/响应体错误不重试。每次尝试复用同一个 route lease，并回放严格
  JSON 重写后受 8 MiB 上限保护的内存请求体；取消会中止退避，首字节发出后不会进入重试路径。
- 每个目标维护 closed/open/half-open 熔断状态，并向诊断和托盘暴露状态。M6b 在单目标 schema 阶段以
  当前不可变 route revision 内的 `providerId + public model alias` 作为目标身份；连续 5 个逻辑请求在完成
  M6a 全部尝试后仍以 429/502/503/504 或响应前 YARP `Request`/`RequestTimedOut` 结束时打开 30 秒。
- open 目标由 Edge 直接返回 503、稳定错误 `aigw_target_circuit_open` 和剩余 `Retry-After`；到期进入
  half-open 并只允许一个完整的有界重试链作为探针。探针成功关闭，瞬态终态失败重新打开；400/401/403/500
  等已完整收到的非瞬态 HTTP 响应重置连续失败，取消及客户端/请求体/响应体错误保持中立。reload 发布新的
  route revision 时新目标从 closed 开始，旧 route 的 in-flight 状态随旧 route 一起排空。
- 熔断快照通过严格控制协议 v2 暴露 `providerId`、公开 alias、state、连续失败数和 open 截止时间；协议版本也
  进入当前用户 Pipe 名，防止 v1/v2 进程误解析。`aigw status`、只读 `doctor` 和 Tray 只消费该控制状态，
  不探测上游；Tray 菜单显示汇总，仪表盘逐目标显示状态。
- 多目标路由只支持 `ordered-fallback` 和 `weighted-round-robin`；自动跳过熔断目标。
- M6c 以 schema v1 的兼容可选 `fallbacks` 数组实现 `ordered-fallback`：现有 `providerId + upstreamModel`
  仍为主目标，旧配置无需迁移；每个公开 alias 最多追加 8 个 fallback，数组顺序即尝试顺序，同一 alias
  的目标 provider 必须唯一，悬空、重复、NULL 或畸形 target 均由严格配置校验拒绝。
- 主目标继续共享 profile 私有 LiteLLM backend；每个 fallback 使用只含对应公开 alias/目标 provider 的独立
  私有 backend，从而保持请求和流式响应中的公开 alias，不把 upstream model 暴露给客户端。蓝绿候选必须
  在发布前准备并探活全部目标；失败时逆序清理已准备实例，route drain/stop 对所有实例聚合失败。
- 每个 ordered target 独立执行完整 M6a 有界重试链并维护 M6b circuit。只有逻辑终态仍为 429/502/503/504
  或响应开始前的 YARP `Request`/`RequestTimedOut` 才进入下一目标；400/401/403/500、取消及请求/响应体错误
  不 fallback。open/忙碌 half-open 目标自动跳过；任何响应首字节发出后绝不切换目标。
- M6d 在同一 schema v1 上兼容增加模型 `routingStrategy`、主目标 `weight` 和 fallback `weight`；缺失时分别
  默认为 `ordered-fallback` 和 1。权重严格限制为 1..100，`weighted-round-robin` 至少需要两个目标。
- `weighted-round-robin` 使用每个不可变 route revision、每个公开 alias 独立的平滑加权轮询状态，并在选择时
  串行化更新。只有当前可获得 circuit permit 的目标累加权重；open 或已有 half-open 探针的目标被跳过并清零
  当前权重，不积累恢复后的突发债务。reload 发布新 route revision 时调度状态随新 route 重新开始。
- 加权模式对每个逻辑请求只选择一个目标；选定目标完整执行 M6a 重试链并把终态记入自身 M6b circuit，终态
  瞬时失败原样返回，绝不跨目标 fallback。全部目标不可用时返回 503 `aigw_target_circuit_open` 和最短
  `Retry-After`。配置通过 `aigw model routing-set|weight-set` 写入既有原子配置事务。
- M6e 在 schema v1 上为 profile、provider、公开模型增加可选 `limits`，分别支持
  `maxConcurrentRequests`、`requestsPerMinute` 和 `tokensPerMinute`。并发上限为 1..10,000，RPM 为
  1..1,000,000，TPM 为 1..1,000,000,000,000；未知字段继续由严格 JSON 契约拒绝。CLI 通过
  `aigw limits profile|provider|model set|clear` 走既有配置锁、revision、完整校验和原子保存事务。
- profile 与公开模型限制在一次逻辑请求进入路由前原子预留，provider 限制只在实际选择或尝试该目标时预留；
  ordered fallback 的 profile/model RPM 只记一次，各 provider 按实际尝试分别记账。所有适用层同时检查，
  任一层达到限制即拒绝，因此多层并存时自然由最严格限制决定。
- 并发许可覆盖整个逻辑请求，包括 M6a 重试、M6c fallback、M6d 选定目标和响应流复制；完成、异常和取消均
  释放。只有确定向实际 provider 发起请求时才提交 RPM，未选中 circuit、provider 限流拒绝和其他未提交
  预留不消耗 RPM。
- RPM/TPM 使用严格滚动 60 秒窗口。限流 registry 由 route coordinator 持有，并以 profile 加 scope/subject
  的大小写不敏感逻辑身份共享，蓝绿 reload 不清空窗口。并发、RPM、TPM 分别返回 429 和稳定错误
  `aigw_concurrency_limit_exceeded`、`aigw_rpm_limit_exceeded`、`aigw_tpm_limit_exceeded`，并带正值
  `Retry-After`。
- TPM 只从实际复制给客户端的 JSON/SSE 响应 usage 增量记账，不缓冲完整响应、不读取文本内容，也不按金额或
  prompt 文本估算。OpenAI chat 流在存在任一适用 TPM 时强制 `stream_options.include_usage=true`，保留
  其他 stream options 和公开 alias。已放行请求可按真实 usage 造成一次有限超额，下一请求再返回 429。
- 项目所有者已取消原拟定的 M6f：网关不增加每日/月 Token quota、`aigw_token_quota_exceeded` 或
  80%/90%/100% Tray 阈值告警。供应商 API 自身的配额和限流属于外部契约；本地网关只在用户显式配置时
  执行 M6e 的并发/RPM/TPM，缺省配置不施加本地限制，并继续按 M6a/M6b 处理供应商返回的 429。

## 11. 验证和发布门槛

- 测试分为纯单元、进程集成、确定性假上游协议、离线安装、打包烟测和客户端配置 fixture。
- CI 不访问真实模型供应商；真实调用只能由用户显式执行 `doctor --probe`。
- 发布前验证断网、含空格路径、无全局 Python/.NET/PowerShell、非管理员、重复安装、异常断电和回滚。
- 每个里程碑只在构建、相关自动化测试和实际烟测有证据后标记为已验证。

## 12. 实施顺序

- M0：工程和 CLI 基线。
- M1：配置、Profile、Provider、Model、凭据。
- M2：最小可用网关和假上游。
- M3：离线 LiteLLM、守护进程和安装。
- M4：Claude/Codex 启动代理与可逆集成。
- M5：用量、WPF 托盘、备份、升级和卸载。
- M6：重试、熔断、多目标路由和 Token 限制。
- M7：未来自研内核研究，不进入首版生产。
