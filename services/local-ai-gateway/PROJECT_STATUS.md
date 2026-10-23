> 历史来源文档：来自 local-ai-gateway 固定提交 `21017a1`，正文保留原文，仅供追溯。原机器路径、状态与操作记录不代表 Shuvi 当前环境。当前规则见主仓库 `docs/01-协作与工程约定.md`；接入和验证见本目录 README.md。

# Local AI Gateway 项目进度

更新日期：2026-09-28
当前里程碑：私有 GitHub 仓库已推送 `codex/develop`，Windows 源码 CI 在 `b415eeb` 上通过。当前工作站已安装包仍为旧版；Profile/Runtime 现场状态需另行只读核验
总体状态：`main` 固定于已稳定验收的 M3a `3050ac8`；shell integration 实现提交为 `f1de4b0`，最终完整包、成对 task action 与真实重新登录触发均已验证；clean-machine/air-gap 与正式签名在自用阶段主动延期，不能表述为已通过

本文只记录实际进度。设计约束见 `TECHNICAL_DECISIONS.md`。

分支规则：功能开发从 `codex/develop` 创建短期 `codex/feature/*` 分支；验证后以 merge commit 合回
`codex/develop`；只有完整里程碑达到交付条件时才更新 `main`。GitHub 私有仓库目前只推送了 `codex/develop`；`main` 和审计用 feature 分支未推送。

## 已完成

### 旧环境退役

- 旧源码、文档和脱敏配置样本已归档到 `C:\claude-projects\claude-gateway-legacy-source-20260824`。
- 归档包含 SHA-256 清单，先前已验证 16/16 个条目。
- 旧配置样本中的本地主密钥已脱敏。
- 旧 DPAPI 密钥、日志、用量、缓存和旧 EXE 已永久删除，未进入归档，无法从本项目恢复。
- VS Code 顶层 `claudeCode.*` 设置和旧自动网关任务已备份后删除。
- `%USERPROFILE%\.claude\settings.json` 已备份后整体删除。
- Claude CLI、VS Code 扩展和插件文件未卸载。
- 当前 Codex 配置未修改。

### 新工程基线

- `C:\claude-gateway` 已重新建立为本地 Git 仓库；M0 阶段分支为 `main`，当前开发分支为 `codex/develop`。
- 已形成 M0 本地初始提交；M0 阶段尚未创建远程仓库或推送。
- 已建立 .NET 10 解决方案初步结构。
- 当前项目包括：
  - `LocalAIGateway.Core`
  - `LocalAIGateway.Windows`
  - `LocalAIGateway.Cli`
  - `LocalAIGateway.Runtime`
  - `LocalAIGateway.LiteLlm`
  - `LocalAIGateway.Launcher`
  - `LocalAIGateway.Tray`
  - `LocalAIGateway.Cli.Tests`
  - `LocalAIGateway.Core.Tests`
  - `LocalAIGateway.Runtime.Tests`
  - `LocalAIGateway.LiteLlm.Tests`
  - `LocalAIGateway.Windows.Tests`
  - `LocalAIGateway.Launcher.Tests`
  - `LocalAIGateway.Tray.Tests`
- 已创建 `global.json`、集中构建属性、集中包版本、解决方案文件、基础许可证和第三方 notices。
- 已实现薄 `Program.Main` 和可测试的 `CliApplication.RunAsync(args, stdout, stderr)` 边界。
- 已实现 `--help`、`--version`、`--json`、`--lang`、`--no-color` 和 `--verbose` 基础契约。
- 已固定 JSON schema version 1、英文机器字段、参数错误码 `aigw_invalid_arguments`、退出码 `2` 和内部错误退出码 `70`。
- 已实现最小中英文人类可读输出；JSON 输出不依赖当前 UI 语言。
- 已添加本地 build/test、敏感数据扫描、确定性打包和解压烟测脚本。
- 已添加 Windows GitHub Actions 工作流；2026-09-28 在干净 Windows 2022 runner 上完成构建、测试和源码扫描。
- 已生成 `0.1.0-dev` win-x64、自包含、无 trimming、明确标记为 unsigned 的开发 ZIP。
- 开发 ZIP 携带第一方许可证、System.CommandLine notice、.NET 许可证和完整 .NET third-party notices。

### M1 配置和凭据

- 已实现 schema v1 的 Profile、Provider、Model 配置模型及严格 JSON 序列化。
- 已实现空草稿 profile；只有包含 provider、模型且恰好一个默认模型的 profile 才能激活。
- Provider 类型固定为 `openai-compatible`、`anthropic`、`azure-openai`、`local-endpoint`。
- 远程端点强制 HTTPS；本地端点只允许 HTTP/HTTPS 的 localhost、回环或私有 IP。
- 已实现悬空引用、重复 ID/别名、未来 schema、损坏 JSON、未知/重复属性和空成员的明确拒绝。
- 已实现当前用户 ACL、跨进程独占锁、revision 乐观并发、落盘刷新、原子替换和上一版本 `.bak`。
- 配置根目录遵循绝对 `%LOCALAPPDATA%`，缺失时回退 Windows 当前用户 Local AppData。
- 已实现 profile/provider/model 的 create/list/show/use/update/remove/set-default CLI 命令族及稳定 JSON 输出。
- 上游凭据目标固定为 `LocalAIGateway/<profile-id>/<provider-id>/api-key`。
- 已实现 Windows Credential Manager 的写入、读取和删除；密钥只接受隐藏输入或 `--secret-stdin`，不存在命令行明文选项。
- profile/provider 删除默认保留凭据；只有显式 `--delete-secrets`/`--delete-secret` 才删除。
- README 已补充 M1 配置流程、端点约束和密钥输入说明。

### M2 最小可用网关和确定性假上游

- 已新增独立 `aigw-runtime.exe`，使用 Kestrel 和 YARP 2.3.0，仅监听回环地址；生产默认端口为 4000。
- 公开面严格限制为三套 POST 文本 API、models、health 和 ready；认证在路由判定前执行。
- 本地令牌支持 Bearer 或 `x-api-key`，拒绝缺失、重复、格式错误和相互冲突的认证头，并使用固定时间比较。
- 已实现 active profile 模型 alias 的大小写不敏感校验和规范化；公开 alias 保持到 profile 私有后端，由后端配置映射 upstream model，未知模型在触达后端前拒绝。
- 请求体采用严格 JSON、64 层深度和 8 MiB 上限；请求认证/Cookie/转发头及后端 Cookie/Server 头均清除。
- 文本、三协议工具调用和 SSE 直接透传，不聚合响应、不重试；上游 4xx/5xx 原样返回，超时为 504，响应头前断连为 502。
- `IBackendHost` 已实现 prepare、ready probe、drain 和 stop 边界；启动先探测后端，端口冲突不替换或终止现有监听者。
- 确定性假后端使用每实例随机内部令牌和真实随机回环端口，可控制状态码、延迟、取消及响应前/流式中断连。
- M2 只提供显式 `--m2-test-serve` 开发验证入口；LiteLLM、Named Pipe、Mutex、Job Object、安装和守护生命周期仍归 M3。
- 自包含 unsigned development ZIP 已同时包含 `aigw.exe` 和 `aigw-runtime.exe`，并补齐 YARP 及其传递依赖 notices。

### M3a LiteLLM 契约（已提交）

- `IBackendHost` 已下沉到 Core；后端准备错误可区分配置、凭据和不可用类别，Runtime 保留稳定错误码及退出码类别。
- 已新增 `LocalAIGateway.LiteLlm` 和对应测试项目，不引入新 NuGet 包。
- 已实现确定性、YAML 兼容的 LiteLLM 配置编译；配置文件不含内部令牌、上游密钥或 Credential Manager target，密钥仅存在于受控进程环境计划。
- 每个 profile 私有实例使用公开 alias 作为 LiteLLM `model_name`，通过 `litellm_params.model` 映射 provider 与 upstream model，避免内部路由标识泄漏到客户端响应。
- 已关闭 LiteLLM 重试、遥测和第三方 callbacks；M5a 只重新启用项目自有的隐私过滤 usage callback。进程环境固定 `LITELLM_LOCAL_MODEL_COST_MAP=True`，禁止隐式联网获取成本表。
- 已实现 shell-free 启动规范：固定内置 Python 路径、`-B -I` 和固定 `-c` 调用官方 `litellm.run_server` 的参数列表、回环端口、清空继承环境及变量名/值/总量校验。
- 已将 LiteLLM 子进程的 TEMP、HOME、AppData、Hugging Face、Transformers、Torch、pip 和 uv 缓存根固定到每个候选实例自己的 `runtime-state`；不再继承平台 TEMP/TMP。
- 已实现托管进程 prepare、probe、drain、stop 抽象；停止与探测/排空串行化，并发停止共享操作，停止/释放双失败仍保留实例追踪并允许显式重试。
- 本地无凭据 endpoint 可编译；远程凭据缺失或格式错误使用凭据类别失败。
- 已用真实 LiteLLM 1.95.0 验证 Azure OpenAI v1 的 `azure/<deployment>`、资源根 `api_base`、`api_version=v1` 和 Bearer API-key 路径；编译器已解除原有拒绝并规范化 `/openai/v1` endpoint。

### M3b 候选制品与下载审计

- 已依据 LiteLLM `v1.95.0` 官方 `uv.lock`，按 CPython 3.14.5、Windows x64 marker 和兼容标签离线解析官方 `litellm[proxy]` 闭包：共 108 个兼容 wheel，缺失数为 0，wheel 总大小为 127,698,463 字节（121.78 MiB）。
- CPython 运行时根制品已核对为 `python-3.14.5-embed-amd64.zip`，大小 12,048,447 字节，SHA-256 为 `ba6bd811c4eedb19195cf275770ef127e893d63701e24152606e2cb76f6d876a`；连同 108 个 wheel 的预计载荷总计 139,746,910 字节（133.27 MiB）。
- LiteLLM 根 wheel 为 `litellm-1.95.0-cp314-cp314-win_amd64.whl`，大小 24,920,863 字节，SHA-256 为 `c3684dcf16aefe98bd6f11586d60a9a92bb1bf7e85468a6a4ac28a65532fab3e`。
- 官方 `[proxy]` extra 无条件包含 `litellm-enterprise==0.1.52`；其 PyPI 元数据许可证为 `LicenseRef-Proprietary`。在取得可再分发依据或改为经过真实验证的最小 Windows proxy 依赖集前，不将该闭包选为项目锁定清单。
- 官方 v1.95.0 包目录没有 `litellm/__main__.py`，不能使用原先的 `python -m litellm`；官方控制台入口指向 `litellm:run_server`。启动规范已改为固定 Python 代码调用该入口，不包含用户输入或密钥。
- `proxy_server.py` 对 `litellm_enterprise` 的导入使用 `try/except ImportError`，缺失时将 enterprise 配置置空；这证明 enterprise 在该入口处是可选的，但不能代替完整依赖和真实启动验证。
- 已生成 `runtime-manifests/m3b-proxy-without-enterprise.candidate.json`：明确排除 enterprise，包含 107 个 wheel 和 Python embed 共 108 个候选载荷，清单 SHA-256 为 `0bb5e21d4b8b20e5d2f0cc6df4a74362ce3c3a595fa49bfb1ee3e92d6c94e361`。
- 候选清单中没有不适用 Windows 的 `uvloop`/`pyroscope-io`，所有 wheel URL 均来自 `files.pythonhosted.org`，107 个包名唯一且 SHA-256 格式有效。
- 许可证元数据未发现 proprietary、GPL、AGPL 或 SSPL 信号；64 个无 SPDX expression 的包均有 PyPI classifier/短许可证回退，另 3 个已用对应版本官方 LICENSE 补齐。下载后的 wheel 内 LICENSE/NOTICE 和捆绑原生库已经完成归档级审计。
- 经用户对精确目标授权，已向 `C:\claude-gateway\artifacts\m3b-runtime-download` 下载 107 个 wheel 和 1 个 Python embed，并加入哈希锁定的 `cl100k_base.tiktoken`；109 个文件共 141,287,210 字节，所有大小和 SHA-256 均复核通过，没有 `.partial` 或额外文件。
- 108 个归档均可读取，未发现路径穿越条目或 enterprise 代码；26 个归档包含原生二进制，所有 wheel 声明的 `License-File` 均存在。
- `tokenizers-0.23.1` wheel 是唯一没有内嵌 LICENSE/NOTICE 的归档；其 METADATA 声明 Apache Software License classifier，已核对对应官方 tag 的 Apache-2.0 LICENSE，最终包必须补带该许可证。
- `soundfile-0.12.1` wheel 内含 `libsndfile_64bit.dll` 和 LGPL-2.1 许可证文本。音频不在首版范围内，默认不得把该可选依赖带入最终文本运行时；若不能排除，必须重新评估 LGPL 履约方案。
- 下载验证收据为 `runtime-manifests/m3b-download-verification.json`，SHA-256 `e47f93a9b7c05a36cdd897b1b52eccf39c1df7ddd957418a05d5df2b3f8539ed`。
- 已从 tokenizers v0.23.1 官方 tag 下载 11,357 字节 Apache-2.0 LICENSE 到仓库 manifest 输入目录，SHA-256 为 `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`。
- 首次离线导入发现 LiteLLM 会加载 tiktoken 的 `cl100k_base` 数据；经单独授权核验并加入下载源，文件为 1,681,126 字节，SHA-256 为 `223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7`，因此 assembly 不再依赖旧 assembly 中的唯一副本。
- 已在 `artifacts/m3b-runtime-assembly` 解包 CPython 和 106 个 wheel，随后以真实启动和四 provider 回环协议烟测排除 19 个额外 wheel；加上预先排除的 `soundfile`，当前文本候选保留 87 个 wheel、排除 20 个。
- 已生成确定性的最终锁 `runtime-manifests/m3b-text-runtime.lock.json`，SHA-256 为 `45ed2669eb90cf6c4e8fdd4530ada0235e2eb9ccc3da391aae1b973597e4e1d8`；发布选择为 87 个 wheel、Python 和 BPE 共 89 个压缩输入、83,827,724 字节，完整审计源仍保留 109 个文件、141,287,210 字节。
- `scripts/new-m3b-runtime-lock.ps1` 会从不可变 candidate 和下载验证收据机械生成该锁，并复核 109 个源文件的大小与 SHA-256；重复生成哈希一致。
- 已仅从 109 个下载源执行 fresh rebuild；当前 assembly 为 10,699 个文件、206,297,020 字节。`litellm-enterprise` 和 libsndfile 均不在 assembly。
- 实际 LiteLLM 1.95.0 离线代理已验证 OpenAI-compatible、本地 endpoint、Anthropic 和 Azure OpenAI v1 映射，以及 Chat Completions、Responses、Anthropic Messages、SSE 和工具调用；上游为确定性回环假服务，没有访问真实模型服务。
- 发现 `-I` 会忽略 `PYTHONDONTWRITEBYTECODE` 环境变量；启动参数增加 `-B` 后清理了本次测试产生的 272 个 `__pycache__` 目录和 1,638 个 `.pyc`，复测未再生成。烟测产生的 3 个 runtime-state 临时文件已清理，状态目录为空。
- 已使用 assembly 内的临时硬链接镜像完成真实带空格路径烟测，没有复制运行时数据；测试目录已精确删除，残留为 0。
- 在 Codex 沙箱拒绝外网套接字、允许回环的条件下已多次冷启动通过；这不是独立 Windows 防火墙或 VM 断网验证，后者仍待安装级测试。
- 下载源为 109 个锁定文件且哈希复核通过；没有全局安装、包管理器缓存或 H 盘写入。

### M3c 产品进程工厂与 Job Object

- 已实现 `WindowsLiteLlmProcessFactory`，将现有无密钥配置计划写入每实例随机私有目录，创建 per-instance `runtime-state`，并通过 `IConfigurationFileSecurity` 应用目录和文件保护。
- 已实现 `WindowsSuspendedJobProcess`：使用 `CreateProcessW(CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT)`，只继承指向 `NUL` 的标准句柄，先加入 `KILL_ON_JOB_CLOSE` Job Object，再调用 `ResumeThread`。
- 上游密钥只进入单独构造的 Unicode 环境块；环境块在 `CreateProcessW` 返回后逐字节清零释放，命令行仍只包含固定入口、配置路径、回环地址和端口。
- 工厂使用随机内部回环端口和 `/health/liveliness` 探测；drain 保留进程供边缘层完成在途请求，stop 关闭整个 Job、等待退出并只删除工厂拥有的随机实例目录。
- 明确处理终止与释放双失败：即使显式 `TerminateJobObject` 失败仍关闭 Job handle 触发 kill-on-close；目录清理失败保持可重试状态，不把失败实例伪装为已停止。
- 新增实际父/子进程测试夹具，验证 Job 终止后父进程和后代均退出；新增工厂测试覆盖无密钥配置落盘、ACL 调用、最小环境、ready、取消、失败清理、重复释放和零实例残留。
- 已使用真实 M3b assembly 从含空格状态路径启动 LiteLLM：产品工厂完成 suspended create → Job assignment → resume → ready → drain → stop，测试根目录和私有 Python 进程残留均为 0；没有发起模型请求。

### M3d Runtime 正式组合与单实例

- 新增 `aigw-runtime.exe --serve` 正式入口，将配置存储、Windows Credential Manager、
  `LiteLlmBackendHost`、`WindowsLiteLlmProcessFactory` 和 Kestrel/YARP 边缘层组合为一个生命周期。
- 安装级客户端令牌 target 固定为 `LocalAIGateway/runtime/client-token`；Runtime 只读取，缺失或格式错误
  使用凭据类别失败，不把令牌写入配置、派生 YAML、参数或输出。
- 新增按当前用户 SID 隔离的全局 Windows Mutex 租约。第二实例在读取凭据或准备 LiteLLM 前即以
  `aigw_runtime_already_running` 失败，Program 映射到既定运行冲突退出码 `12`。
- `GatewayDaemonHost` 明确拥有边缘 Runtime、后端 Host 和 Mutex 租约；正常停止及启动失败均先回收
  Kestrel/后端 Job，再释放单实例租约，重复释放幂等。
- 真实 assembly 首次组合测试发现 LiteLLM 冷启动期间单次 readiness 探测过早失败；已增加默认
  60 秒、100 ms 间隔的有界探测。定向测试覆盖先失败后就绪和持续未就绪的超时清理。
- 真实 M3b assembly 已通过 Mutex → 配置/令牌 → suspended Job process → readiness → Edge `/ready`
  → stop 完整链路；没有模型请求，测试根、runtime-state、`.pyc`、`__pycache__` 和私有进程残留为 0。
- 新增 `scripts/test-m3d-runtime.ps1` 作为非静默验收入口：assembly 缺失、测试根与 assembly 重叠、
  测试根已存在、测试失败或任一进程/目录/缓存残留都会失败，避免环境门控测试在未提供真实运行时
  被误记为已验证。

### M3e Named Pipe 控制面与蓝绿切换

- 新增 v1 当前用户控制管道 `LocalAIGateway.Control.v1.<current-user-SID>`，使用
  `PipeOptions.CurrentUserOnly`，不增加 TCP 管理端口；帧为 4 字节 little-endian 长度前缀加 UTF-8
  JSON，最大 64 KiB、每连接一问一答。
- Core 协议严格拒绝畸形 JSON、重复/未知字段、超大/截断帧、未知版本和未知命令；Windows 客户端
  提供有界连接与 I/O 超时，Runtime 服务端对慢请求返回稳定 `aigw_control_*` 错误，并允许 reload
  期间并发查询 status。
- 控制命令只包含 `status`、`reload`、`stop`。status 不输出客户端/内部令牌、端口或进程参数；
  reload 只重新读取 `ConfigurationStore`；stop 先写成功响应，再通知正式入口进入既有优雅关闭路径。
- 每个请求使用不可变 route lease，同时绑定 revision、profile、model rewriter、内部令牌和后端实例；
  SSE 在流结束前持续持有。高 revision 候选 ready 后原子发布，新请求走新实例，旧实例等待租约归零后
  drain/stop；候选失败保留旧 route 并记录 pending revision 和稳定错误码。
- 相同 revision reload 幂等，旧 revision 明确拒绝，并发 reload 串行化；Runtime 关闭会等待 candidate/
  retiring/active route 清理完成，再由 Daemon 释放 Backend Host 和当前用户 Mutex。
- 控制服务最多保留 8 个并发连接槽；已完成连接和 retirement 任务会从跟踪表移除，非预期连接失败
  独立汇总并由关闭路径观察，避免关闭竞态、未观察异常和长期任务表增长。
- 新增 `scripts/test-m3e-runtime.ps1`，真实 M3b assembly 已完成 status → revision 2 reload → 第二个
  suspended Job 候选 ready → 原子切换 → Edge `/ready` → stop，并验证两个私有进程树、测试根、
  runtime-state、`.pyc` 和 `__pycache__` 残留均为 0；没有发起模型请求。

### M3f 完整发布包与隔离安装核心

- `scripts/package.ps1` 已把只读 M3b assembly 的私有 CPython/LiteLLM、最终锁、assembly receipt、runtime environment、第三方许可证和确定性组件清单纳入自包含 win-x64 ZIP；不包含运行态目录、字节码、下载源、wheel 归档或包管理器缓存。
- 新增严格 schema v1 `PACKAGE-MANIFEST.json`：规范序列化全部 11,066 个安装载荷条目，并按 Windows 路径语义拒绝逃逸、自引用、保留名、大小写冲突、额外文件/空目录和 reparse point。
- 新增 `WindowsPackageInstaller`：source 全量验证、同级随机 staging、逐文件复制与复核、目录原子发布、同包幂等、异包冲突和失败 staging 清理；卸载仅删除仍匹配 manifest 的自有文件，未知/修改文件保留并报告。
- 敏感扫描新增精确文件 SHA-256 例外，只覆盖两个已审阅上游依赖文件中的静态 private-key 标记；内容变化恢复失败，canary 永不豁免，独立回归为 4/4。
- `scripts/verify-m3f-package.ps1` 在一次性 acceptance 根内独立生成两份完整包、比较哈希、解压验 manifest/组件/许可证、执行无全局 .NET 的 EXE smoke、私有 Python import、隔离安装、真实 M3e 和卸载。成功后删除 acceptance，只保留最终 ZIP 和 `.sha256`。

### M4a Launcher 安全进程核心

- 新增独立 `LocalAIGateway.Launcher` / `aigw-launcher.exe` 和对应测试项目；当前没有引入新 NuGet 包。
- launcher 严格要求已存在的绝对客户端文件和工作目录，拒绝 executable reparse point、畸形环境变量名及
  base URL/token 同名覆盖；客户端参数只通过 `ProcessStartInfo.ArgumentList` 传递，不使用 shell。
- 编排层先验证请求并从固定 Credential Manager target 读取、校验 64 字符安装级令牌；无效请求或令牌
  在 daemon/客户端进程创建前 fail-closed。有效时幂等启动固定安装 daemon，仅在子进程启动环境中写入
  固定 `http://127.0.0.1:4000` 和本地令牌，等待并原样返回客户端退出码。
- 子进程保留调用方标准流，适合后续交互式 CLI；令牌不进入 launcher 命令行或输出，进程创建后从托管
  启动环境字典移除。M4a 不定义 Claude/Codex 环境变量名，不运行真实客户端，不读取或修改其配置。
- `scripts/package.ps1` 已纳入第三个自包含程序，`verify-m3f-package.ps1` 增加 launcher 文件与无全局 .NET
  烟测。一次性 `artifacts/m4a-package-check` 包含 11,071 个文件，manifest 声明 launcher，启动器参数
  拒绝烟测返回预期退出码 12；临时包、解压目录和父目录已全部删除。

### M4b `aigw run` 客户端适配器

- 新增 `aigw run claude|codex|--client`。客户端参数只接受 `--` 后的剩余 token 并逐项传给
  `ArgumentList`；CLI 不追加成功输出，原样返回客户端退出码。
- Claude 适配器依据当前官方契约使用 `ANTHROPIC_BASE_URL`、`ANTHROPIC_AUTH_TOKEN` 和固定
  `--model aigw/default`；Codex 适配器通过一次性 `--config` 构造 Responses provider，使用
  `http://127.0.0.1:4000/v1`、子进程局部 `AIGW_CODEX_API_KEY` 和 `aigw/codex/default`，不写 TOML。
- 已知适配器拒绝用户覆盖网关拥有的 model/provider 参数。PATH 解析只接受绝对目录中的真实 `.exe`，
  拒绝 reparse point 和 `.cmd`/`.bat` shell shim；通用客户端必须显式给出绝对路径及 base/token 环境变量名。
- M4b fixture 覆盖参数保真、冲突拒绝、环境契约、token-only Codex 启动、父进程环境不变、退出码透传和
  CLI 静默输出。未探测本机客户端版本，未运行真实 Claude/Codex，未读取或写入其配置。
- 一次性 `artifacts/m4b-package-check` 成功生成自包含包，11,070 个 manifest 载荷包含 CLI/Launcher；
  无全局 .NET PATH 下 `run codex --help` 返回 0，provider 覆盖烟测返回稳定退出码 12。ZIP SHA-256 为
  `02dc479c9c55111c20cbba3deb9182a27de768caaadf31c383c7ee092bf330e7`，验收后 ZIP、解压目录和父目录已删除。

### M4c fixture 配置集成预览

- 新增 `aigw integrate preview`，当前只接受显式 `--source` fixture（省略时表示新文件）、表示目标路径、
  客户端版本及所需 host/wrapper 参数；命令不自动读取目标、不写文件，并明确返回 `applyPerformed=false`。
- Claude VS Code 预览只管理 JSONC 根属性 `claudeCode.claudeProcessWrapper`；保留注释、换行和非托管字段。
  `aigw-launcher.exe` 已支持扩展传入“捆绑 Claude 可执行文件作为首参数”的 wrapper 调用形状，并继续固定
  `aigw/default` 与子进程局部 Anthropic base URL/token。
- Codex 预览只表示独立 `$CODEX_HOME/aigw.config.toml`，使用 Responses provider 和
  `AIGW_CODEX_API_KEY` 环境变量名；不修改默认 `config.toml`，文件中不包含令牌值。
- 当前 reviewed 版本门为 Claude Code 2.x + VS Code 1.94+，以及 Codex 0.134+ 且 major 仍为 0；畸形或
  未审阅 major、JSONC/TOML 所有权冲突、损坏/重复标记均 fail-closed 并返回退出码 14。
- diff 只包含网关托管块与前后 SHA-256，不回显 fixture 中的非托管配置值。即使 BEGIN/END 存在，标记内
  混入用户字段也拒绝替换；M4e 已补齐显式 target 的 status/unintegrate。

### M4d fixture 配置应用事务

- 新增 `aigw integrate apply`。命令必须提供 preview 的 `--expected-after-sha256`，并在
  `--expected-before-sha256` 与 `--expect-absent` 中恰选一种；确认值必须精确为 `--confirm APPLY`。
  错误或缺失确认在读取 target 前以 `aigw_integration_confirmation_required` 拒绝。
- apply 只从 target 重新读取严格 UTF-8 文本并重新运行 M4c 版本/所有权编译；before hash 不符、目标出现/
  消失或 after hash 不符均以 `aigw_integration_stale_preview` 拒绝，避免把过期预览用于不同内容。
- 目标父目录必须已存在，目标及现有祖先目录不得为 reparse point；apply 不创建目录。已有文件使用同目录
  write-through 临时文件和 `File.Replace` 原子替换，同时生成唯一 `.aigw-backup-<GUID>.bak`；新文件使用
  无覆盖 `File.Move`。UTF-8 BOM 在已有文件更新时保留。
- 取消只在变更前观察；进入原子替换后必须完成事务。替换/移动失败会保留原目标并删除临时文件；若原子
  backup 显示最后一刻并发变化，会把介入内容恢复到 target、删除本工具的 rejected 临时副本并返回 stale。
- apply 成功输出只包含 action、哈希、是否应用和备份路径，不回显 target 或 backup 内容。文件/权限失败
  使用退出码 15；版本、确认、所有权和 stale preview 使用退出码 14。
- M4d 自动化与包内 smoke 全部只写随机 `%TEMP%`/仓库 `artifacts` fixture；没有读取或修改真实客户端配置。

### M4e fixture 集成状态与撤销事务

- 新增 `aigw integrate status`，只读取显式绝对 target，不扫描默认配置目录、不探测客户端、不写状态注册表。
  状态为 `absent`、`not-integrated` 或 `owned`；owned 输出撤销 action、before/after SHA-256 和脱敏 diff，
  不回显非托管配置内容。损坏/重复标记和非托管同名字段仍以退出码 14 fail-closed。
- status 不要求当前客户端版本，因为它只识别既有 Local AI Gateway v1 所有权标记，使客户端升级后仍可撤销；
  preview/apply 的新增和更新仍保留 M4c reviewed version gate。
- 新增 `aigw integrate unintegrate`。更新必须绑定 status 的 before/after hash；纯受管 Codex 专用文件必须
  使用 `--expect-delete`；确认必须精确为 `--confirm UNINTEGRATE` 并在读取 target 前验证。
- Claude 撤销只移除严格受管 JSONC 块，保留非托管字段、注释、换行和 UTF-8 BOM。含外部注释的 Codex
  专用文件保留注释并原子更新；仅含受管块时将整个文件原子移动到唯一恢复备份，不遗留空文件。
- 更新沿用同目录 write-through 临时文件、`File.Replace` 和原子恢复备份；删除后校验备份 hash。stale target/
  撤销计划、replace 失败和删除最后一刻竞态均有测试；竞态在安全时自动恢复，临时文件必须清理。
- `integrate list` 明确不在 M4e 实现：当前无持久化登记，自动扫描会越过显式 target 和真实配置授权边界。
  M4e 自动化及实际构建 CLI smoke 只使用随机 `%TEMP%` fixture，未读取或修改真实客户端配置。

### M5a 用量回调与 SQLite 存储

- 编译器只启用内置 `aigw_usage_callback.usage_logger`，同时打开 LiteLLM message logging 和 API-key
  metadata 的关闭/脱敏开关；回调源码作为 .NET 程序集资源随包携带，不新增 NuGet、wheel、全局安装或缓存。
- 每个候选实例生成受当前用户 ACL 保护的 callback 和最小 alias 映射文件；它们随随机实例目录回收。
  唯一持久目标为 `%LOCALAPPDATA%\LocalAIGateway\usage\usage.db` 及 SQLite 正常的 `-wal/-shm` 文件。
- schema v1 只含 UTC 毫秒、profile/provider ID、公开 model alias、结果、真实 input/output/total Token 和
  受控错误码。失败且未报告 usage 时 Token 同时为 NULL，不伪造 0。回调不读取或持久化 prompt、response、
  工具参数、认证头、请求方标识、endpoint、上游模型名或金额。
- 使用私有 CPython 标准库 `sqlite3`，强制 WAL、STRICT table、250 ms busy timeout；每天至多一次清除早于
  当前本机 UTC 一年的事件。未来 schema、锁冲突、I/O、未知 alias 或畸形 usage 均 fail-open。
- 真实 LiteLLM 1.95.0 已加载该 callback，并用确定性回环假 OpenAI 上游实际记录 13/5/18 Token；响应、
  prompt、tool、authorization 和 amount canary 均未进入 DB/WAL/SHM。没有访问真实模型服务。

### M5b 只读用量聚合与 WPF Tray

- Core 新增 `IUsageSummaryReader` 及 totals/group/recent-error 脱敏模型；Windows 实现用已捆绑私有 Python
  `sqlite3` 读取固定 `usage/usage.db`，没有新增 NuGet、wheel、全局安装或包缓存。
- 查询脚本固定随自包含发布进入 `runtime-tools`，使用 `mode=ro`、`query_only` 和 250 ms busy timeout；只接受
  schema v1，不迁移、修复、checkpoint 或清理数据库。数据库不存在时返回零值且不启动 Python、不创建目录。
- .NET 读取器拒绝 reparse 目标、负值或超过 366 天的窗口；私有进程使用 `-B -I`、最小环境、5 秒超时和
  进程树回收。stdout 限 1 MiB，并严格校验 JSON、字段长度、窗口、计数和 group 总和一致性。
- 新增 `aigw usage today`，用当前用户时区的本地午夜换算 UTC 起点，返回 request/success/failure、三类
  Token、profile/provider/public alias 分组和最多 20 条受控错误元数据。命令不启动 daemon、不写数据库。
- 新增独立 WPF `aigw-tray.exe`，以当前用户 SID Mutex 保证单实例；托盘菜单和 dashboard 显示 daemon
  状态、Runtime active profile、配置选择、今日 request/success/failure 和三类 Token。
- Tray 提供 start、stop、restart、refresh 和 profile 切换。profile 先通过配置管理器原子保存；daemon
  运行时使用既有 `reload` 进入蓝绿候选切换，停止时不隐式启动或重启，只在下次 start 加载新配置。
- UI 只消费 `IUsageSummaryReader`，没有 SQLite API 或数据库写路径；usage 查询失败不遮蔽已成功读取的
  daemon/config 状态，取消回到 Idle，未知异常只显示脱敏稳定错误。
- 新增 coordinator、状态转换、配置/profile、异常、取消、单实例/进程生命周期和包布局测试；完整包把
  WindowsDesktop 自包含载荷隔离到 `tray/`，并从父包根复用受 manifest 约束的私有查询运行时。
- M6b 后完成 Tray dashboard 体验收尾：拆分 XAML/code-behind，内容区独立滚动且底部主操作始终可见，
  全窗统一使用系统内置 `Microsoft YaHei UI`，并以可键盘操作和自动化识别的自定义 Profile 选择器替代
  原生生硬下拉框；控制、查询、profile reload 语义与包依赖均未改变。

### M5c 普通与加密 secrets 备份

- 新增 `aigw backup create|inspect|restore`。普通包只含配置；`--include-secrets` 只读取配置中 provider 的
  规范 Credential Manager target，不导出或替换安装级 runtime token。
- 备份格式严格拒绝未知/重复字段、未来 schema、无效配置/target、超限输入和 reparse 路径；create 要求绝对
  新目标并采用受保护同目录临时文件、flush 和无覆盖原子移动，inspect 不修改本地状态。
- restore 绑定备份 SHA-256、当前配置 revision 和精确 `RESTORE`；provider credentials 在配置原子提交前
  写入，失败则逆序回滚。包中未列出的凭据保留，不执行隐式删除。
- 加密复用已锁定私有 Python `cryptography 48.0.1`，固定 Argon2id 64 MiB/3 iterations/4 lanes 和
  AES-256-GCM，不新增 NuGet、wheel、下载或缓存。口令只从隐藏输入/stdin 读取，进程最小环境、30 秒超时、
  取消/超时进程树回收，托管请求和解密明文 byte buffer 用后清零。

### M5d 离线升级

- 新增严格 canonical `PACKAGE-SIGNATURE.json`/`TRUSTED-UPDATE-KEYS.json`、Ed25519 域分隔验证和受限 SemVer
  单调性；正式流程只信任已安装 trust store，未签名 development 包必须显式授权。
- 新增 `aigw update inspect|apply` 和独立自包含 `aigw-updater.exe`。apply 绑定 manifest SHA-256、精确
  `UPDATE`，通过受保护的外置 worker 和原子 receipt 异步完成，CLI 不直接修改程序树。
- updater 逐文件 staging、side-load 检查 CLI/Runtime/Launcher/Tray/Updater/私有 Python，以同卷目录移动
  原子切换；运行中的 daemon 会停止并在成功后恢复。后置健康或 daemon 启动失败会恢复旧树和原运行状态。
- worker/cleanup 使用 Windows 显式 handle list、`NUL` 标准句柄和最小环境，避免继承 CLI 管道锁住活动安装
  树；只等待精确父 PID，只清理受状态根和 GUID 命名约束的 transaction/worker 路径。

### M5e 完整卸载

- `aigw uninstall` 现将程序、owned 登录任务、显式客户端集成、runtime token、provider credentials、配置、
  用量、日志和显式备份分为九类。交互模式逐类询问；非交互模式必须逐类 `keep|remove` 并精确确认
  `UNINSTALL`。
- 卸载不扫描真实客户端配置或备份目录。集成目标必须显式给出，且复用 ownership/hash/unintegrate 与恢复
  备份；备份必须显式给出并通过严格备份 schema/hash 识别。凭据只枚举 `LocalAIGateway/` target 名称，
  不读取 secret。
- 从已安装 CLI 选择程序删除时，由已安装 updater 复制到当前用户受保护 Temp GUID worker，等待 CLI/updater
  退出后再执行 manifest 保守程序删除和所选数据清理；固定 Local AppData 布局、最小环境、受限句柄、30 秒
  调度超时、进程树回收、SID 安装 Mutex 和原子 receipt 均已实现。
- 状态清理只处理固定配置文件、`usage`、`logs` 和程序删除所需 operational state，遍历前完整拒绝 reparse
  point；修改/未知程序文件保留并报告。worker/receipt 因 Windows 自删除限制保留为无 secrets 审计证据，
  只能在核对 receipt 和进程退出后按精确 GUID 路径清理。

### M6a Edge 单目标重试

- Edge 对响应开始前的 429、502、503、504，以及 YARP `Request`/`RequestTimedOut` 转发错误执行最多两次
  重试；400、401、403、500、客户端/请求体/响应体错误不重试。
- 无 `Retry-After` 时采用确定性的 100/200 ms 退避；有效 delta/date 精确等待。超过 60 秒时保留原响应，
  不在约定时间前重试，也不让单请求无限占用 Edge。
- 每个请求在同一个不可变 route lease 内完成全部尝试，回放的是现有严格 JSON 模型重写产生的可 seek
  内存流。每次尝试使用独立 transformer，前序响应状态/头不会泄漏到最终响应。
- 客户端取消会中止退避；SSE 或普通响应一旦开始，既有直接流式复制路径不重试、不追加网关错误正文。

### M6b per-target 熔断器

- 当前单目标配置以 active profile 内的 `providerId + public model alias` 作为 target 身份，每个不可变 route
  revision 独立维护 closed/open/half-open 状态；reload 发布的新 route 从 closed 开始，旧 route 随 lease 排空。
- 默认连续 5 个逻辑请求在 M6a 重试耗尽后仍以 429/502/503/504 或响应前 YARP `Request`/
  `RequestTimedOut` 结束时打开 30 秒；open 请求不访问后端，返回 503、`aigw_target_circuit_open` 和
  剩余 `Retry-After`。到期只放行一个 half-open 探针链，成功关闭，瞬态失败重新打开。
- 已完整收到的非瞬态 HTTP 状态会重置失败序列；取消、客户端、请求体和响应体错误既不计数也不清零，
  首字节后仍不重试或 fallback。并发旧请求的迟到结果不能关闭已经打开的 circuit。
- 控制协议升级到 v2，并把版本纳入当前用户 Pipe 名；严格状态快照包含 provider、公开 alias、state、连续
  失败数和 open 截止时间。`aigw status`/只读 `doctor`、Windows controller 和 Tray 复用同一快照，
  doctor 不访问上游，Tray 菜单汇总并在仪表盘逐目标显示。

### M6c ordered fallback

- schema v1 兼容增加模型 `fallbacks` 数组，旧单目标 JSON 无需迁移；现有 provider/upstream 保持主目标，
  每个 alias 最多 8 个 fallback，按数组顺序尝试且 provider 必须唯一。严格拒绝 NULL、悬空、重复和畸形目标。
- 新增 `aigw model fallback-add|fallback-remove`，继续通过配置管理器的锁、revision、完整校验与原子写入；
  被主目标或 fallback 引用的 provider 均不能删除。
- 主目标继续共享 profile backend，每个 fallback 使用保持同一公开 alias 的独立私有 backend。候选发布前
  全部准备并探活，失败逆序清理；reload 旧 route 的所有 backend 随 lease 排空、drain 和 stop。
- 每目标先执行完整 M6a 重试链，只有 429/502/503/504 或响应开始前 Request/RequestTimedOut 的逻辑终态
  才切到下一目标并计入该目标 M6b circuit。open/忙碌 half-open 自动跳过；非瞬态、取消、body 错误和
  首字节后断连均不 fallback，公开 alias 和上游私有名称隔离保持不变。

### M6d weighted round robin

- schema v1 兼容增加 `routingStrategy` 和每目标 `weight`；旧配置默认 `ordered-fallback`/权重 1。权重范围
  1..100，加权策略至少需要两个 provider 唯一的目标；CLI 新增 `model routing-set|weight-set`。
- 每个 route revision/公开 alias 使用串行化的 smooth weighted round robin。只有 circuit 当前可获得的目标参与；
  open 和忙碌 half-open 被跳过且不积累恢复后的权重债务，reload 发布新 route 时调度状态重置。
- 每个逻辑请求只选一个目标并在该目标内完成全部 M6a 重试与 M6b 记账；终态瞬时失败不会转发到另一目标。
  全部目标不可用时复用稳定 503 `aigw_target_circuit_open`。未新增依赖或控制协议字段。

### M6e layered request limits

- schema v1 兼容增加 profile/provider/model 可选 `limits`，支持并发、滚动 RPM 和滚动 TPM；边界严格校验，
  CLI 新增 `limits profile|provider|model set|clear`，继续复用配置锁、revision 和原子保存。
- profile/model 许可覆盖完整逻辑请求，provider 许可只覆盖实际目标尝试。并发跨重试、fallback 和流式响应；
  取消、异常与完成均释放。RPM 只在实际 provider admission 后提交，限流拒绝和 circuit 不可用不消耗 RPM。
- 所有适用层同时检查，任一层达到限制即返回 429。滚动 60 秒状态按逻辑 scope 身份保存在 coordinator，
  蓝绿 reload 不清空窗口；稳定错误分别为 `aigw_concurrency_limit_exceeded`、`aigw_rpm_limit_exceeded`、
  `aigw_tpm_limit_exceeded`，并返回正值 `Retry-After`。
- TPM 从实际复制的 JSON/SSE usage 流式提取，不缓冲正文、不扫描模型文本、不估算 Token。存在 TPM 的 OpenAI
  chat 流会强制请求 usage summary，同时保留公开 alias 和其他 stream options；单个已放行请求允许一次超额。

### 首版发布收口：安全日志生命周期

- Runtime 在取得当前用户单实例 Mutex 后，把固定 schema JSONL 写入状态根 `logs/gateway.log`。事件只覆盖
  daemon start/stop 和 configuration reload 的成功/失败，字段仅含 UTC 时间、固定 level/事件名与可选 revision；
  不存在任意消息、异常、请求/响应、配置值、模型、endpoint、Token 或密钥写入入口。
- 活动文件上限 10 MiB，写入前无覆盖轮转；轮转保留 30 天，全部受管日志总量上限 100 MiB。清理只识别
  严格 UTC 时间戳加序号命名的顶层 owned 文件，保留 lookalike 和未知文件，拒绝跟随目录或活动文件 reparse point。
- 日志目录和文件使用当前用户专属 ACL，每条事件 write-through flush；所有日志 I/O、ACL 和清理错误 fail-open，
  不得影响 daemon 或请求。未新增 NuGet、Python 包或控制协议字段。

### 首版发布收口：安装体验与成对自启

- 固定登录任务为 `\LocalAIGateway.Runtime` 和 `\LocalAIGateway.Tray`；前者运行安装根
  `aigw-runtime.exe --serve`，后者运行 `tray\aigw-tray.exe`。两者都是当前 SID、`LogonTrigger`、
  `InteractiveToken`、`LeastPrivilege`，同名不同定义 fail-closed，不覆盖、不删除。
- 交互式 `install` 会以 `[Y/n]` 询问成对自启且默认启用；`install --json` 必须显式给出
  `--autostart enable|disable`，缺失时在任何外部变更前返回 `aigw_install_autostart_choice_required`。
- 文件、runtime credential 和成对任务纳入同一 SID 安装锁事务。任务冲突在文件/凭据变更前拒绝；
  后段失败或取消只回滚本次新建的任务、凭据和程序文件，保留预存完整包、令牌和 owned 任务。
- Runtime-only legacy 状态显示为 incomplete，重复 enable 只补齐缺失的 Tray 任务；disable 和 uninstall
  只处理语义匹配的 owned 任务。

### 首版发布收口：当前用户 shell 集成

- 安装把程序根作为一个 owned 当前用户 PATH 条目加入 `HKCU\Environment\Path`，保留原值类型、原始文本和
  分隔符；卸载只移除自身追加片段并逐字节恢复既有值。
- Start Menu 只创建 `Local AI Gateway\Local AI Gateway.lnk`，目标为安装包内 Tray，工作目录为 `tray`；
  不创建 CLI 或 daemon 快捷方式。状态根 ownership receipt 记录两项资源及安装前目录存在性。
- 既有等价 PATH 条目、同名快捷方式、畸形/未知 receipt、reparse 路径均在变更前 fail-closed。创建、取消、
  后段失败和卸载覆盖组合回滚，并保留安装前存在的空目录。
- Runtime 计划任务 action 恢复为技术真源规定的 `aigw-runtime.exe --serve`；启动失败日志只增加有界稳定
  error code 与已加载 revision，不写异常文本或配置内容。配置读取直接区分真正缺失和拒绝访问。

### 当前工作站自用安装

- 已从 SHA-256 为 `91c41e959b8ed9451eb967476e30e0ae725913ccb31d7a5760848bbaf4ae03de`、绑定实现提交 `f1de4b0` 的完整 unsigned development ZIP 安装。
- 一次性/保留安装源位于 `H:\LocalAIGateway\install-source-f1de4b0`；产品仍按固定契约安装到 `%LOCALAPPDATA%\Programs\LocalAIGateway`，状态根为 `%LOCALAPPDATA%\LocalAIGateway`。
- 安装已创建并验证安装级 runtime credential、owned 当前用户 PATH 条目和 Tray Start Menu shortcut；Runtime 与 Tray 登录自启保持关闭，两个计划任务均不存在。
- 安装目录内 `aigw.exe --version`、`doctor --json`、`status --json` 和 `autostart status --json` 均通过。当前 Runtime 未运行、安装路径进程为 0；`doctor` 唯一 issue 为尚未创建配置的 `aigw_doctor_configuration_missing`，且 `modelProbePerformed=false`、`upstreamContacted=false`。
- 项目所有者已撤销“不访问 H 盘”的旧限制。今后大型下载、缓存、一次性发布和验收目录在安全且路径明确时优先放非系统盘；产品固定 Local AppData 路径和现有仓库/锁定制品不会自动迁移。

### CLI help 完整性

- 原顶层帮助的手写清单漏掉 `limits` 和 `update`；命令组帮助重复顶层清单，叶子帮助不列自身选项。
- 源码现从注册命令树列出顶层与当前层子命令；叶子列出选项及必填标记。JSON help 保留原顶层 `commands` 字段，并增加当前层 `subcommands`、`options`。

## 已验证

- CLI help 修复后 Release 构建 0 warning/0 error、自动化测试 587/587，敏感数据扫描 282 文件；仓库生成的 `aigw.exe` 顶层、嵌套层和叶子帮助 smoke 通过。
- 2026-09-28 建立 `AlterGo-xzy/local-ai-gateway` 私有仓库，首次仅推送 `codex/develop`。初次 Windows CI 发现 CRLF 测试假设和流式断连竞态；修复后 `b415eeb` 的 [GitHub Actions 运行](https://github.com/AlterGo-xzy/local-ai-gateway/actions/runs/36444486374) 通过：Release 构建 0 warning/0 error、588/588 测试、282 文件敏感扫描。对首次推送前 83 个本地提交的文本补丁做常见密钥格式扫描未命中，历史路径没有配置/密钥/usage DB 候选；这不是完整历史的形式化无密钥证明。

- 旧归档清单在归档阶段已完成 SHA-256 校验。
- 旧环境清理阶段已确认未修改 Codex 配置。
- 使用 .NET SDK `10.0.302` 完成解决方案 restore 和 Release build：0 warnings、0 errors。
- CLI 自动化测试 11/11 通过，覆盖版本、帮助、中英文、JSON、非法参数和内部错误退出码。
- 源码敏感数据扫描通过；当前扫描 24 个非生成文件。
- 两次独立 win-x64 自包含发布各扫描 212 个制品文件，均未发现常见密钥格式或随机 canary。
- 两份确定性 ZIP 的 SHA-256 完全一致：`938ed5e0dc8351bc84104588fe14bc67f7f19314870d9dab832dcdd28e655378`。
- ZIP 解压到随机临时目录后，`aigw.exe --version` 和 `aigw.exe --json --version` 烟测通过。
- 烟测时将 `DOTNET_ROOT` 指向不存在目录并设置 `DOTNET_MULTILEVEL_LOOKUP=0`；EXE 仍正常运行，且包内存在 `coreclr.dll` 和 `hostfxr.dll`。
- 包内已验证存在 unsigned development 标记和许可证文件，且不包含 `.ps1`、`.cmd` 或 `.bat` 运行脚本。
- 实际 CLI 进程的非法参数原生退出码已验证为 `2`。
- M1 Release build 使用 .NET SDK `10.0.302` 通过：0 warnings、0 errors。
- M1 自动化测试 63/63 通过：Core 37、Windows 5、CLI 21。
- 配置测试覆盖严格 schema、端点安全、引用/default 约束、跨进程锁超时、revision 并发、原子备份和无效写入不落盘。
- Windows 测试覆盖实际目录、配置、锁和备份文件的受保护 DACL；只保留当前用户 FullControl 显式规则。
- 凭据测试覆盖目标命名空间、空密钥和 2560 UTF-8 字节上限，未在自动化测试中写入真实外部凭据。
- 经用户确认，使用精确目标 `LocalAIGateway/m1-verification-20260824/credential-canary/api-key` 完成真实 Windows Credential Manager 写入、读取固定时间比对和删除；删除后复查目标不存在。
- 受限沙箱令牌调用 Credential Manager 返回 Windows 1312；使用当前用户非沙箱登录会话复测通过，说明实现依赖正常交互用户登录会话。
- CLI 测试覆盖完整增删改查、递归全局选项、稳定错误码、明文密钥参数拒绝和 canary 不进入输出/配置。
- 使用隔离 `%LOCALAPPDATA%` 运行真实 `aigw.exe`，完成 profile → provider → model → activate → validate 链路；revision 为 4，配置不含 `secret`/`apiKey` 字段，隔离目录已删除。
- 两份最终 M1 确定性 ZIP 的 SHA-256 完全一致：`fdd60c8d0260fc60f97952ef6e4ce5a858fd59b4fb828d999a97a086ba91679e`。
- 两次发布各扫描 212 个文件并通过敏感数据扫描；解压后的自包含 CLI 烟测通过。
- M2 Release 解决方案构建通过：0 warnings、0 errors；自动化测试 87/87 通过：Core 37、Windows 5、CLI 21、Runtime 24。
- Runtime 真实回环 socket 测试覆盖认证、公开路由、模型隔离与重写、头清理、三协议工具调用、SSE 首事件、上游 400/429/500/503、502/504、客户端取消、两类断连、ready、端口冲突和并发生命周期释放。
- 使用解压后的自包含 `aigw.exe` 和 `aigw-runtime.exe`、隔离 `%LOCALAPPDATA%`、不存在的 `DOTNET_ROOT` 及确定性 TCP 假后端完成独立进程烟测：health 200、chat 200、内部认证替换和 alias 重写通过；隔离目录和测试进程已清理。
- M2 源码敏感数据扫描通过，当前扫描 68 个非生成文件。
- 两份 M2 发布各扫描 363 个文件，解压扫描同样通过；两份确定性 ZIP 的 SHA-256 一致：`c6ad9e89fe13ca0a911d62bf14554bc260b546bb6d28e94c47c5d8b5854d5091`。
- ZIP 解压后 `aigw.exe --version`、CLI JSON version 和 `aigw-runtime.exe --version` 在禁用全局 .NET 的环境中通过，且制品不含 PowerShell、CMD 或 BAT 运行脚本。
- M3a Release 解决方案构建通过：0 warnings、0 errors；自动化测试 107/107 通过：Core 37、Windows 5、CLI 21、Runtime 25、LiteLlm 19。
- M3a 测试覆盖公开 alias 不泄漏内部/upstream 标识、确定性无密钥配置、远程/本地凭据规则、Credential Manager 读取错误分类、Azure 未验证拒绝、固定本地 cost map、shell-free 最小环境和进程生命周期并发/失败恢复。
- M3a 源码敏感数据扫描通过，扫描 80 个非生成文件。
- M3a 启动入口修正先由定向测试捕获 `-m litellm` 与官方包结构不一致，再改为固定 `litellm.run_server` 调用；修正后的 Release build 为 0 warnings、0 errors，自动化测试仍为 107/107，敏感信息扫描通过 81 个非生成文件。
- M3b 当前完整 Release build 为 0 warnings、0 errors；自动化测试 108/108 通过：Core 37、Windows 5、CLI 21、Runtime 25、LiteLlm 20；敏感信息扫描通过 90 个非生成文件。
- M3b assembly fresh audit：109/109 下载源大小和哈希通过、最终锁重复生成一致、导入烟测通过、四 provider 与五类协议回环烟测通过；重建后 assembly 为 10,699 个文件、206,297,020 字节，runtime-state 文件、`.pyc`、`__pycache__`、残留私有 Python 进程和带空格镜像残留均为 0。
- M3c Release build 为 0 warnings、0 errors；自动化测试 115/115 通过：Core 37、Windows 5、CLI 21、Runtime 25、LiteLlm 27；敏感信息扫描通过 98 个非生成文件。另以环境门控方式单独执行真实 assembly 工厂测试并通过。
- M3c 原生进程树测试验证 suspended Job 中的父进程和实际后代进程均在 Job 终止后退出；真实 assembly 工厂测试结束后项目临时根和私有 Python 进程残留均为 0。
- M3d Release build 为 0 warnings、0 errors；自动化测试 126/126 通过：Core 37、Windows 6、CLI 21、
  Runtime 35、LiteLlm 27；敏感信息扫描通过 105 个非生成文件。
- M3d 专用真实 assembly 验收通过：单实例租约、配置/客户端令牌、私有 Job 后端、有界 ready、
  Edge `/ready` 和 stop 完整闭环通过；测试后私有 Python 进程、测试根、runtime-state、`.pyc`、
  `__pycache__` 残留均为 0。没有发起模型请求。
- M3d 当前 .NET 自包含开发包重复发布验证通过：两份 ZIP 的 SHA-256 均为
  `a95249fa9bbaca9307936d9277d6789ea81be294fa49d23900dd678640d35fb5`，每份及解压目录各扫描
  365 个文件。该验证尚未把 M3b 私有 Python assembly 纳入 ZIP，因此不是安装级 `--serve` 验收。
- M3e Release 全解决方案自动化测试 173/173 通过：Core 61、Windows 10、CLI 21、Runtime 54、
  LiteLlm 27；源码敏感信息扫描通过 119 个非生成文件。真实 assembly 蓝绿验收 1/1 通过，私有进程和缓存残留为 0。
- M3f Release 全解决方案自动化测试 199/199 通过：Core 77、Windows 20、CLI 21、Runtime 54、LiteLlm 27；Release build 为 0 warnings、0 errors，源码敏感信息扫描通过 131 个非生成文件。
- M3f 两份独立完整 ZIP 的 SHA-256 均为 `b5c7d8a31bc036983d1cf309121b196aae599edda2b24b1de30aae481b94ad26`；每次完整包扫描 11,066 个载荷文件，最终 ZIP 为 134,469,563 字节，输出目录只保留 ZIP 和 `.sha256`。
- 完整包 manifest 11,066/11,066 条大小和 SHA-256 通过；CLI/Runtime 无全局 .NET smoke、CPython 3.14.5 + LiteLLM import、隔离安装 1/1、真实 M3e 1/1、隔离卸载 1/1 通过。验收后私有进程、acceptance root、runtime-state、`.pyc` 和 `__pycache__` 残留均为 0。
- M3g 已实现 256 位 CSPRNG runtime client token、固定当前用户路径、package + credential 事务、SID 级跨进程安装锁，以及顶层 `install|uninstall|start|stop|restart|status|doctor` 与 `autostart enable|disable|status` CLI。
- daemon 控制器只通过当前用户 Pipe 查询/停止；启动固定安装目录的 `aigw-runtime.exe --serve` 并等待 ready，提前退出/超时只清理本次启动进程树，清理失败聚合报告。
- 自卸载安全边界已锁定：安装根内运行的 CLI 在停止 daemon 或删除文件前拒绝卸载；首轮从原始解压包卸载，M5 再实现专用辅助进程。
- 无模型 `doctor` 已实现为只读存在性与 Pipe 状态诊断，明确返回 `modelProbePerformed=false`、`upstreamContacted=false`；实际 CLI 进程验证后真实程序目录和状态目录仍不存在。
- 当前完整 Release 自动化测试 336/336 通过：Core 90、Windows 53、CLI 49、Runtime 54、LiteLlm 27、Launcher 63；Release build 为 0 warnings、0 errors，源码敏感信息扫描通过 180 个非生成文件，扫描例外回归 4/4。
- 全量回归曾一次暴露既有 daemon 标准句柄测试 marker 的写入/读取共享竞态；夹具改为同目录临时文件关闭后原子发布，定向连续 5/5 和随后全量回归均通过。
- M4b 一次性自包含包的帮助与冲突拒绝烟测均通过，临时包目录残留为 0；现有桌面 M3g 包未被覆盖。
- M4c 一次性自包含包通过 sidecar SHA-256、Codex/Claude 两类 `integrate preview` 和目标未创建烟测；
  最终临时 ZIP SHA-256 为 `c576701d1242a120a0e97017ebada7f65bc125505d30303b64a935347c914c90`；
  `artifacts/m4c-package-check` 已完整删除，未覆盖桌面或既有 M3 产物。
- M4d 一次性自包含包完成 Codex 新建、Claude 新建/更新、原文备份、错误确认拒绝和零临时文件 smoke；
  临时 ZIP SHA-256 为 `04e82d0e8b856da62607fe4f38a20282c87be5d7bc38ee2c08e83feffbbcde42`，
  `artifacts/m4d-package-check` 与匹配 `%TEMP%` fixture 已完整删除。
- M4e 实际构建 CLI 完成 Codex owned-file 删除、Claude owned-block 更新、恢复备份、非托管值不输出和零临时
  文件 smoke，随机 `%TEMP%` 根已删除。一次性完整自包含包生成及 11,070 文件扫描通过，ZIP SHA-256 为
  `0badda89873982ddc1ade81dde4f85de0bcfb4ba3f4cddd65bf33f7857c838f3`；两个 `artifacts/m4e-package-*`
  临时根均已删除。
- 已实现固定 `\LocalAIGateway.Runtime` 当前用户登录任务：当前 SID、`LogonTrigger`、`InteractiveToken`、`LeastPrivilege`、固定安装 EXE `--serve`、无密码/令牌；同名不同定义 fail-closed，不覆盖、不删除。
- 自启 enable/disable 与 uninstall 共用 SID 级安装 Mutex；enable 先完整校验已安装 package，重复 enable/disable 幂等，卸载先删除 owned 任务再处理包和凭据，冲突任务在任何卸载变更前阻断并保留。
- 首次真实注册发现 Task Scheduler 将 trigger SID 规范化为账户名，并省略等于实际安全默认值的 XML 字段；原严格文本表达判定按设计 fail-closed，保留任务并阻止卸载。只读 COM 逐项确认身份、权限、trigger、action 和 settings 均符合预期后，判定改为接受这些明确等价的系统规范化形式，并增加回归测试。
- 修复版真实验收已通过：`autostart enable` 创建 owned 任务，重复 enable 幂等，系统 XML 语义回读通过，`schtasks /Run` 从固定 action 启动 daemon，重复 start 幂等，disable 和重复 disable 通过，最后卸载成功。
- 最终复查确认程序根、状态根、runtime credential、`\LocalAIGateway.Runtime`、staging、安装进程和 acceptance root 残留均为 0；验收未请求模型、未访问上游、未修改 PATH/Start Menu/客户端配置，也未写 H 盘。
- `scripts/test-m3g-installed-runtime.ps1 -TestAutostart` 已增加默认只读预检和显式 `-Execute` 门：执行时才会注册、重复注册、语义回读、由 Task Scheduler 手动运行 action、重复撤销，并在 finally 中停止 daemon、撤销 owned task、卸载和审计零残留；只读预检已通过。
- 真实 daemon 验收使用的上一版 M3g ZIP SHA-256 为 `7465b105e0c544ec43ec069e48a68048ef5f413bfc69c77e39f8892d4ae7a231`；该闭环未创建计划任务。
- 真实当前用户安装首次返回 `installed=true`、`runtimeCredentialCreated=true`；相同候选重复安装返回 `alreadyInstalled=true`、`runtimeCredentialCreated=false`，证明文件和既有令牌幂等保留。
- 从真实安装目录运行版本、只读 `doctor` 和 `status` 通过：manifest/runtime EXE 存在、runtime 未运行、配置缺失被明确报告、模型探测与上游访问均为 false；Credential Manager 只存在 target `LocalAIGateway/runtime/client-token` 的 Generic 当前用户条目。
- 从安装根外的原始解压包卸载返回 `removed=true`、`runtimeCredentialDeleted=true`。独立复查确认程序根、状态根、同级 staging、安装进程和 credential 均不存在；一次性候选 ZIP、sidecar、解压目录及整个 `m3g-real-install-acceptance` 根已删除。
- 最终垃圾审计发现 71 个历史 `LocalAIGateway-DaemonControl-<GUID>` 测试目录，共 36,412 字节、每个只含一个 `config.json`。根因是 xUnit 2.9.3 不调用测试类的 `IAsyncDisposable`；已改为框架识别的 `IDisposable`，定向测试 5/5 和当时全量测试通过后新增残留均为 0。
- 71 个历史目录逐个验证为 `%TEMP%` 直属、严格 GUID 命名、非 reparse point 且只含非 reparse 的 `config.json` 后已删除；最终复查为程序根/状态根/验收根不存在，staging 0、匹配 temp 0、安装/验收进程 0、runtime credential 不存在。
- 真实 Local AppData 跨进程配置验收发现 `File.Replace` 在完整当前用户 FullControl ACL 下仍返回 access denied；已增加仅对该精确失败、且源/目标仍存在时启用的双原子移动回退。真实路径复测 current revision 2、backup revision 1、临时文件 0。
- 首次安装后 daemon 验收发现后台 Runtime 继承调用方 stdout/stderr，导致捕获 `start --json` 时调用方等待到 daemon 退出；已改为 `CreateProcessW` + 受限句柄列表 + `NUL` 三标准句柄。原生夹具确认三个句柄文件类型均为字符设备而非管道。
- 最终真实闭环已通过：安装创建真实 runtime credential；本地无密钥 profile 启动后 active revision 4；重复 start 幂等；当前用户 Pipe 可用；无令牌 `/ready` 返回 401；`doctor` 保持 `modelProbePerformed=false`、`upstreamContacted=false`；stop 和外部包卸载后程序根、状态根、credential、staging、进程及 acceptance root 残留均为 0。
- 包含 Task Scheduler 规范化修复的新 M3g development ZIP 已两次独立重建且 SHA-256 一致，并保留在 `artifacts/m3g-package-output/LocalAIGateway-0.1.0-dev-win-x64-unsigned.zip`：`03a2c977d38ee868ee904018f479b4bd521fc1182d21239208dc15547689004a`。
- 新 M3g 输出 ZIP 为 134,504,162 字节，含 11,067 个文件和 11,066 个 manifest 载荷条目；正式输出目录只含 ZIP 与 `.sha256`，两次重建 candidate/repro 已清理。
- 最终 ZIP 与 sidecar 已复制到 `C:\Users\Admin\Desktop\LocalAIGateway-M3g`；桌面目录只含这两个文件，ZIP SHA-256 与仓库正式产物一致。

- M5a Release build 为 0 warnings、0 errors；全解决方案测试 337/337：Core 90、Windows 53、CLI 49、
  Runtime 54、LiteLlm 28、Launcher 63。源码敏感数据扫描 186 个非生成文件通过。
- M5a callback 专项验收通过 WAL、schema v1、一年保留、未来 schema 拒写、锁冲突 fail-open、字段白名单与
  canary 不落盘；真实 LiteLLM callback-load 和真实假上游 usage event 均通过。
- 环境门控的真实产品工厂 1/1 通过，证明程序集嵌入资源经受保护实例文件落盘后可由 suspended Job 中的
  私有 LiteLLM 加载，并在 stop 后删除实例。M5a 临时根和私有 Python 进程残留均为 0。
- M5a 完整包从 feature commit `07e8504` 独立重建两次且 SHA-256 一致：
  `8a9fd199e25e51790a6a216c9971119c4c583ca2df32ab6dbb04bc02cd25fde2`。ZIP 为 134,632,858 字节、
  11,071 个条目；11,070 个载荷文件通过敏感扫描，sidecar、callback 嵌入、Runtime commit marker 与
  `aigw-runtime.exe --version` smoke 均通过。`artifacts/m5a-package-check` 已彻底删除。
- M5e 实现提交 `1be6e11` 上 Release 全量 466/466：Core 118、Windows 106、CLI 74、Runtime 54、
  LiteLlm 28、Launcher 63、Tray 14、Updater 9；0 warning/0 error，源码敏感扫描 256 文件。
- `scripts/test-m5e-uninstall.ps1` 定向 46/46 通过，并从提交后源码构建五个自包含 EXE 和完整包，扫描
  11,751 文件；ZIP SHA-256 为 `3fc35ad19cdf656aa4d75b656de4c8e43cb5959c4543bea1f71650b3111a75de`。
  包内实际 `aigw.exe` 在隔离 Local AppData 中调度 worker，选中的程序/集成/配置/用量/日志/备份均删除，
  owned 集成恢复备份和原子成功 receipt 均验证；测试进程、发布根、worker/receipt fixture 残留为 0。
- M5e 收尾回归中，M5a callback、M5b query/Tray、M5c backup 和 M5d update 专项脚本全部通过；M5d 对当前
  11,751 文件包重新验证实际 Ed25519、原子切换、故障自动回滚及零测试根残留。
- M6a 实现提交 `1478979` 上 Release 全量 498/498：Core 118、Windows 106、CLI 74、Runtime 86、
  LiteLlm 28、Launcher 63、Tray 14、Updater 9；0 warning/0 error，最终源码敏感扫描 259 文件。
- `scripts/test-m6a-edge-retry.ps1` 通过 Runtime 86/86、无全局 .NET 的自包含 Runtime EXE smoke、当前
  feature commit ProductVersion 和零随机测试根/进程残留。提交后完整包 manifest 11,751/11,751，ZIP 共
  11,753 个文件，包内 Runtime marker 正确；三次重建 SHA-256 一致为
  `c4563804a61765548c786ea99d1a16b680a6d9689db702bc2060e21a4872bc92`，一次性包根均已清理。
- M6b 实现提交 `04f7ea8` 上 Release 全量 506/506：Core 119、Windows 106、CLI 75、Runtime 92、
  LiteLlm 28、Launcher 63、Tray 14、Updater 9；0 warning/0 error，源码敏感扫描 262 文件。
- `scripts/test-m6b-circuit-breaker.ps1` 通过 Core/Windows/CLI/Runtime/Tray 406 项测试、无全局 .NET 的
  Runtime/CLI/Tray 自包含 EXE smoke，以及两次完整包重建。两包均扫描 11,751 个 payload，manifest
  11,751/11,751 逐项大小和 SHA-256 通过，五个包内 EXE 均绑定 `04f7ea8`；ZIP SHA-256 一致为
  `5af692be1cdd07e199afce6b208716e5ad4a48feb480b2dc8d3c5614e9ba6c3f`，随机根和测试进程残留为 0。
- Tray dashboard polish 实现提交 `5afcbb3` 上 Release 全量 510/510：Core 119、Windows 106、CLI 75、
  Runtime 92、LiteLlm 28、Launcher 63、Tray 18、Updater 9；0 warning/0 error，源码敏感扫描 266 文件。
  M5b Tray 18/18、自包含 EXE smoke 通过；当前 M6b 完整包专项通过五组 410 项、Runtime/CLI/Tray smoke
  和两次 11,751 项 manifest 重建，ZIP SHA-256 均为
  `5a118040a2184b25c73c9aadb1e2b61bc8025ed1e470d029d6a237583f7cd03a`，随机根和测试进程残留为 0。
- M6c 实现提交 `4aff995` 上 Release 全量 518/518：Core 124、Windows 106、CLI 76、Runtime 95、
  LiteLlm 28、Launcher 63、Tray 18、Updater 9；0 warning/0 error，源码敏感扫描 268 文件。M6c 专项
  Core 3、CLI 1、Runtime 3 和无全局 .NET 的 Runtime/CLI 自包含 smoke 通过。当前最高完整包脚本通过
  五组 419 项、Runtime/CLI/Tray smoke 与两次 11,751 项 manifest 重建；ZIP SHA-256 均为
  `be7477d025ff9731061fa919df8f4daf974e994285b5888261cf34a643ba1be8`，随机根和测试进程残留为 0。
- M6d 实现提交 `bcb7236` 上 Release 全量 523/523：Core 126、Windows 106、CLI 76、Runtime 97、
  LiteLlm 28、Launcher 63、Tray 18、Updater 9；0 warning/0 error，源码敏感扫描 270 文件。M6d 专项
  Core 2、CLI 1、Runtime 6 和无全局 .NET 的 Runtime/CLI 自包含 smoke 通过。最高完整包脚本通过五组
  423 项、Runtime/CLI/Tray smoke 与两次 11,751 项 manifest 重建；ZIP SHA-256 均为
  `3bc84f529ec4c622887d71b4c242f99a37c690e69476756d782fd8d2b700f109`，随机根和测试进程残留为 0。
- M6e 实现提交 `2297ddd` 上 Release 全量 540/540：Core 128、Windows 106、CLI 77、Runtime 111、
  LiteLlm 28、Launcher 63、Tray 18、Updater 9；0 warning/0 error，源码敏感扫描 276 文件。M6e 专项
  Core 2、CLI 1、Runtime 14 和无全局 .NET 的 Runtime/CLI 自包含 smoke 通过。最高完整包脚本通过五组
  440 项、Runtime/CLI/Tray smoke 与两次 11,751 项 manifest 重建；ZIP SHA-256 均为
  `91f1452627657b1feb57af10d2afa6effaef2ae73504d7b3a2fd664a885adabf`，随机根和测试进程残留为 0。
- 日志实现提交 `aa80607` 上 Release 全量 547/547：Core 128、Windows 106、CLI 77、Runtime 118、
  LiteLlm 28、Launcher 63、Tray 18、Updater 9；0 warning/0 error，源码敏感扫描 279 文件。日志专项 12 项、
  真实私有 Runtime composition、无全局 .NET 的自包含 Runtime smoke 均通过。最高完整包脚本通过五组 447 项、
  Runtime/CLI/Tray smoke 与两次 11,751 项 manifest 重建；ZIP SHA-256 均为
  `861db3ac2a477df5020795e0e629d24ccfae79c9ede77f34fc7b59821f02d28e`，随机根和测试进程残留为 0。
- 安装体验实现提交 `fcac91b` 上 Release 全量 560/560：Core 128、Windows 114、CLI 82、
  Runtime 118、LiteLlm 28、Launcher 63、Tray 18、Updater 9；0 warning/0 error，源码敏感扫描 280 文件。
  安装体验专项 Core 7、Windows 36、CLI 14，共 57 项，并通过自包含 CLI help、非交互选择门和版本绑定 smoke。
- 最终完整包脚本通过五组 460 项、Runtime/CLI/Tray 自包含 EXE smoke 和两次 11,751 文件
  manifest 重建；两份 ZIP SHA-256 均为 `2f43c3ccac454fef00f59c4a51a8e51208583d8da1f655b34af591004706ae43`，
  随机包根和测试进程残留为 0。

## 当前缺口

- GitHub Actions 源码 CI 已在 Windows 2022 通过；它不生成包含私有 Python/LiteLLM assembly 的完整离线包，也不替代 clean-machine/air-gap 验收。
- 已完成本机自包含完整包、隔离安装及当前工作站永久自用安装；尚未在全新、OS 级断网、未安装 .NET/Python/PowerShell 的 Windows x64 普通用户环境执行真实安装验证。项目所有者已为当前自用阶段主动延期该门槛。
- M2 已形成本地里程碑提交 `095bac2`；当时尚未创建远程仓库，也未推送。
- M3a 已形成本地里程碑提交 `3050ac8`；其后发现并修正的 LiteLLM 启动入口已纳入累计检查点 `a802cc5`；当时尚未创建远程仓库，也未推送。
- 正式 Ed25519 发布私钥尚未配置，因此当前制品只能是 unsigned development 包。
- M2 `--m2-test-serve` 仍保留为开发验证入口；M3g 已完成令牌、路径、文件/凭据事务、安装锁、CLI、daemon、只读 `doctor` 和 Task Scheduler 真实闭环。2026-09-22 已通过注销/重新登录触发 Runtime+Tray 成对真实 logon event。
- M3b-M3f 已完成最终文本运行时锁、fresh rebuild、真实代理、进程树回收、Edge 组合、蓝绿切换、完整 ZIP 和隔离安装验证；M3g 真实当前用户安装、配置、daemon 启停、幂等和卸载已验证，但尚未完成独立 OS 级断网验证。
- Launcher、只读预览、显式确认 apply 及所有权感知 status/unintegrate 已在 M4a-M4e 实现；M5a 用量写入、
  M5b SQLite 只读聚合/Tray、M5c 备份、M5d updater 和 M5e 完整卸载均已实现并完成本机验证。
- Runtime+Tray 成对任务已通过仓库 fixture、事务回滚、自包含包、手动 Scheduler action 和真实 logon event
  验证。初次 Runtime 复测的 revision 0 已由同 SID/Session/`LOCALAPPDATA` 任务探针定位为 Codex 执行器外部
  文件视图隔离；由 Task Scheduler 上下文生成 revision 4 配置后，原始 direct Runtime action 启动成功并稳定
  观察 95 秒，注销/重新登录后 Runtime 与 Tray 在同一时刻触发，Runtime `daemon.started` revision 4，Tray
  为唯一 owned 安装路径进程。最终外部状态清理为 0，PATH 恢复为原始 ExpandString 807 字符。
- shell integration 实现提交 `f1de4b0` 上 Release 580/580：Core 130、Windows 131、CLI 82、Runtime 119、
  LiteLlm 28、Launcher 63、Tray 18、Updater 9；0 warning/0 error，源码敏感扫描 282 文件。M5a、M5b 和
  install-experience 专项通过。
- `f1de4b0` 绑定的完整 unsigned 包扫描 11,751 项，SHA-256 为
  `91c41e959b8ed9451eb967476e30e0ae725913ccb31d7a5760848bbaf4ae03de`；manifest 11,751/11,751，
  CLI/Runtime/Launcher/Updater/Tray 自包含 smoke 通过，一次性解压根已删除。

## M0 实施清单

- [x] 建立可测试的 `CliApplication.RunAsync(args, stdout, stderr)` 边界，`Program.Main` 保持为薄入口。
- [x] 实现 `--help`、`--version`、`--json`、`--lang`、`--no-color`、`--verbose` 的基础契约。
- [x] 固定英文 JSON 字段和机器错误结构；参数错误退出码为 `2`，未预期错误为 `70`。
- [x] 提供中英文人类可读输出的最小本地化机制。
- [x] 增加必要的 CLI 单元测试，不为普通脚手架增加仪式化测试。
- [x] 添加本地构建/发布脚本和最小 CI。
- [x] 生成 win-x64、自包含、无 trimming 的开发 ZIP。
- [x] 扫描源码、输出和制品，确认不包含常见密钥格式或 canary。
- [x] 经用户确认后形成 M0 本地里程碑提交。

## M0 验收条件

- 解决方案 restore、build 和测试成功。
- `aigw --help` 与 `aigw --version` 可运行。
- 中英文人类输出、JSON 输出和非法参数退出码有自动化证据。
- 从 ZIP 解压后的 `aigw.exe` 可在临时目录直接运行。
- 发布内容不依赖目标机已安装的 .NET 或 PowerShell。
- 发布 ZIP 内容和哈希可重复生成；开发包明确标记为 unsigned。
- 阶段结果经用户确认后再形成 M0 里程碑提交。

## 后续里程碑

- M1：配置、Profile、Provider、Model、凭据。
- M2：最小可用网关和确定性假上游（已实现、验证并提交）。
- M3a：LiteLLM 配置、启动规范和托管进程契约（已实现、验证并提交）。
- M3b：哈希锁定的私有 Python/LiteLLM 运行时、真实 provider 配置和离线烟测。
- M3c：挂起启动、Job Object 和产品私有进程工厂（已实现、验证并纳入 `a802cc5`）。
- M3d：Runtime 正式组合、当前用户 Mutex 单实例和有界 readiness（已实现、验证并纳入 `a802cc5`）。
- M3e：当前用户 ACL 的 Named Pipe 控制面和蓝绿候选切换（已实现、验证并纳入 `a802cc5`）。
- M3f：完整私有运行时发布包、严格 manifest 和隔离安装/保守卸载核心（已实现、验证并纳入 `a802cc5`）。
- M3g：令牌、路径、安装事务、跨进程安装锁、生命周期 CLI、daemon、只读 `doctor`、Task Scheduler 注册/回读/action 启动/撤销、幂等和零残留卸载已验证；真实重新登录事件尚未执行。
- M4a：客户端无关 launcher 安全核心与自包含 EXE（已实现、验证并纳入 `a802cc5`）。
- M4b：重新核对当前官方契约后实现 `aigw run claude|codex|--client` 适配器（已实现、验证并纳入 `a802cc5`；未修改真实客户端配置）。
- M4c：fixture 驱动的 `integrate preview`（已实现、验证并纳入 `a802cc5`；未读取或写入真实配置）。
- M4d：fixture 驱动、带并发哈希校验、备份、原子写入和显式确认门的 `integrate apply`（已实现、验证并纳入 `a802cc5`；未触碰真实配置）。
- M4e：fixture 所有权感知的 `integrate status|unintegrate` 已实现并验证；`list` 因无状态登记且不得自动扫描真实配置而明确不实现。真实外部配置仍需精确目标与授权。
- M5a：自有 LiteLLM callback、Token/元数据白名单、SQLite WAL、schema v1、一年保留和 fail-open 已实现并用真实私有 LiteLLM/假上游验证。
- M5b 查询核心：全量 Release 346/346，源码敏感扫描 194 文件；真实私有 Python/WAL 只读查询、未来 schema
  拒绝、100 ms 超时进程回收、隔离 LocalAppData 的实际 CLI 和 216 文件自包含发布 smoke 均通过，临时根为 0。
- M5b Tray：feature commit `df5905d63d5a6533ba7be2491cc40601920b9bb0` 上 Release 362/362，0 warning/
  0 error，源码敏感扫描 208 文件；Tray 定向 14/14、自包含 `aigw-tray.exe --version` 和包内禁用全局 .NET
  smoke 均通过。完整包 manifest 11,546/11,546，ZIP SHA-256 为
  `07814885268c5496bf0391d8e95011b35546448a4c38b635ad05840d7018b760`，一次性包根、Tray 测试根和私有
  Python 进程残留均为 0。
- M5c：feature commit `ec217cc7e0ee4a674c4a403ea3eeab443acd2fde` 上 Release 382/382：Core 99、Windows
  69、CLI 55、Runtime 54、LiteLlm 28、Launcher 63、Tray 14；源码敏感扫描 217 文件。专项 Core 9/9、
  Windows 7/7、CLI 4/4，真实 Argon2id/AES-GCM 往返/错误口令/超时/取消、隔离 LocalAppData CLI restore、
  当前用户 ACL 和零残留均通过。完整包 manifest 11,548/11,548，SHA-256 为
  `2bcdd367c1b0f41f534f60e3435eabbcb476458cc73352b1b2ae915b8beb6e79`，包内加密 smoke 通过且检查根已删除。
- M5d：实现提交 `0474d692e9abe6ebe72035671c206e202b39e2a8` 上 Release 423/423：Core 114、Windows
  85、CLI 59、Runtime 54、LiteLlm 28、Launcher 63、Tray 14、Updater 6；0 warning/0 error，源码敏感扫描
  239 文件。M5d 定向 Core 15/15、Windows 15/15、Updater 6/6、CLI 4/4 通过。
- M5d 提交后完整包扫描 11,747 文件，ZIP SHA-256 为
  `7ffbc03da83f2a1d4c44573f3f7395a7ae43b9d8d87c1e8415283e143ac49af3`；包内实际 Ed25519 verifier、
  self-contained updater、成功原子切换、后置健康故障自动回滚和 receipt/worker/事务/测试根零残留均通过。
- M5：Token 用量、WPF 托盘、备份、离线升级和九类完整卸载均已实现、验证并合入 `codex/develop`。
- M6：M6a 重试、M6b 熔断、M6c ordered fallback、M6d weighted round robin 和 M6e 可选分层并发/RPM/TPM
  已完成本机验证。原拟定 M6f 日/月 Token quota 与阈值告警已取消，不再属于项目路线图。
- M7：未来自研 backend host 研究。

## 当前问题和限制

- M6a 已通过 `32c084d`、M6b 已通过 `8b9a477`、M6c 已通过 `d9a2e3f`、M6d 已通过 `4b05bfe`、
  M6e 已通过 `8d133d0` 合入 `codex/develop`；五条来源 feature 分支均保留供审计。M6 到此完成。
  M5e 已通过 `92cb617` 合入 `codex/develop`，feature 分支保留。正式 Ed25519 发布私钥仍未配置，只有显式
  授权的 unsigned-development 流程。
- M5d 验收只使用仓库内随机临时根、隔离 LocalAppData 和现有私有 Python；未写真实 Credential Manager、
  Task Scheduler、客户端配置或 usage 数据库，也未访问模型、上游或 H 盘。一次性发布与更新根均已清理。
- M5e 测试使用隔离 Local AppData，未执行真实 Credential Manager、Task Scheduler 或真实客户端配置删除；
  这些真实外部目标仍需逐项明确授权。M6e 验收未访问模型或上游；已取消本地日/月 quota 与阈值告警。
- 首次 NuGet restore 可能需要构建环境联网。最终用户发布包仍必须完全离线。
- 正式 Ed25519 发布私钥尚未配置；在此之前只能生成 unsigned development 包。
- GitHub Actions 源码 CI 已执行并通过；全新离线 Windows 用户环境验证尚未执行，不能将源码 CI 结果表述为完整包或离线验收。
- CI 不生成完整自包含包：`scripts/package.ps1` 需要未入库的私有 Python/LiteLLM assembly；完整包和 air-gap 验收仍须单独进行。私有 Windows runner 会消耗 GitHub Actions 额度。
- 当前工作站自用安装仍是 `f1de4b0` 绑定的旧包，本轮没有覆盖安装根；2026-09-22 记录的 Profile 缺失只代表当时快照，当前状态尚未在本轮核验。

## 轻量工作规则

- 每次只推进一个里程碑。
- 以实现和验证为主，不维护每日工作日志、冗长追踪矩阵或逐小任务计划文档。
- 关键安全、配置、协议和进程生命周期逻辑必须测试；普通脚手架不强制测试先行。
- 阶段结束只更新：已完成、已验证、待完成、受阻和下一步。
- 未经明确要求，不使用子代理、不创建远程仓库、不推送。
- 删除、覆盖外部配置或其他不可逆操作前，必须列出精确目标并获得确认。
