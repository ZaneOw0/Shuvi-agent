# 06 Agent 模块接入

> 2026-10-20：阶段 A 构建及用户模拟器快速回归通过。阶段 B1 的应用内正常连接路径已获用户确认；异常、取消的设备验收仍待完成。已声明网络权限；生产宿主、真实搜索与模型回答尚未接入。
> 用户已批准六模块固定源码快照，以及 B1 网络权限、HDC 回环调试和 ArkTS 资料替代方案。实际搜索/模型调用与公共合同调整不包含在 B1 中。

## 1. 交付范围

Shuvi 基线 `dev/ux` / `bd7c76f`；Agent 固定提交 `a12b6a18cbbf1188a4708997f73cea3b55860fed`，当时位于上游 `codex/shuvi-search-error-projection` 分支，尚未合入其 `main`。

新增 `vendor/harmony_agent/`，包含六个模块的 156 个原始上游文件及来源清单、许可文本、集成说明。没有复制整个仓库、研究材料、测试宿主、证书、生成缓存或私有配置；没有修改上游业务源码。

| 模块 | 版本 | 工程用途 |
|---|---|---|
| agent_contracts | 0.3.0 | 公共数据合同 |
| agent_core | 0.2.0 | 工作流与预算内核 |
| agent_runtime | 0.16.0 | 编排和应用后端入口 |
| mcp_client | 0.2.0 | MCP 客户端 |
| agent_connectors | 0.12.0 | 搜索与模型连接适配 |
| agent_storage | 0.8.0 | 执行恢复和记忆存储适配 |

根 `build-profile.json5` 注册六个 HAR；`entry/oh-package.json5` 通过仓库内相对路径声明依赖，OHPM 生成 entry 及模块锁文件。根开发依赖和 SDK 版本未变。

`build-profile.json5` 这次变化是**模块注册**，`signingConfigs` 仍为空模板；不是本机签名污染。

阶段 A 完成时，页面仍调用 `MockAssistantService` / `MockSearchSession`，未创建 `AgentApplicationBackend` 实例、未声明网络权限、未调用网络。本阶段成功不表示真实能力已经接通。后续 B1 只新增连接检查，见第 5 节。

## 2. 本地核验与构建

在仓库根目录执行，不需要另一个 `Harmony_agent` 克隆：

```powershell
node scripts/verify-agent-vendor.cjs
ohpm install --all
```

`ohpm` 使用 DevEco 配套版本。核验脚本检查文件哈希、模块版本、许可声明、六模块内部依赖闭包、entry 依赖路径和工程模块注册；具体来源与升级约定见 [源码快照说明](../vendor/harmony_agent/README.md)。

使用 DevEco Studio 构建应用；命令行也可调用已安装的 Hvigor：

```powershell
# 先按本机安装位置设置 DEVECO_SDK_HOME / JAVA_HOME，再调用配套 hvigorw.bat。
hvigorw.bat assembleHap assembleHar --no-daemon
```

该命令同时验证应用 HAP 与六个 HAR。首次依赖安装会生成忽略的 `oh_modules/`，构建会生成忽略的 `build/`、`.hvigor/` 和模块 `BuildProfile.ets`。不要提交这些目录或文件。

## 3. 2026-10-20 验证记录

环境：Windows、Node.js 24.14.1、DevEco Studio 配套 Hvigor、HarmonyOS API 26 SDK。当前会话无独立 `arkts_check` / `build_project` 工具，使用实际编译结果验证。

| 检查 | 结果 |
|---|---|
| `node scripts/verify-agent-vendor.cjs` | 156 个文件与 6 个本地模块核验通过；构建后再次核验通过 |
| 配套 `ohpm.bat install --all` | 退出码 0；依赖安装及锁文件生成完成 |
| 配套 `hvigorw.bat assembleHap assembleHar --no-daemon` | 退出码 0，`BUILD SUCCESSFUL`；207 个任务，204 个执行、3 个最新；entry CompileArkTS 和六个 HAR 编译均完成 |
| `node entry/src/test/run-host-tests.cjs` | 20/20 通过（日程 13 + 搜索 7） |
| `node entry/src/test/run-floating-placement-tests.cjs` | 9/9 通过 |
| Code Linter | 工程报告和 vendor 定向报告均为 `[]`，退出码 0；但不能记为完整通过，详见下文 |
| 签名 / 安装 / 模拟器 / 真机 | 自动化未执行签名和安装；用户按本次重新运行后的检查步骤反馈模拟器启动、搜索样例与日程样例符合预期；真机未验证 |
| Agent 上游单元测试 / 真实网络 | 本轮未执行；未导入测试宿主或上游测试目录，不引用上游历史通过数作为本次结果 |

构建警告：既有 `TextAreaController` 设备能力提示、缺少签名配置提示，以及 HAR 打包时的本地依赖提示。当前按源码相对依赖集成，生成的 HAR 不是已完成依赖重写的独立发布包。

Linter 内部日志仍出现无效的 `@security/no-unsafe-*` 规则、`MockAssistantService.ets` / `Index.ets` 的 `getDeclaringMethod` 异常，以及本机 `.local` 阅读副本图标目录访问提示。全工程分析日志只列出 17 个文件；定向 vendor 检查未产生新的模块分析证据，不能声称新模块已被 Linter 完整覆盖。未修改规则或增加忽略项绕过检查。后续应由工具链维护方排查。

本机证据：`.local/agent-integration-stage-a/` 内的 `ohpm.log`、`build.log`、`host.log`、`floating.log`、`lint.log` / `lint.json`、`vendor-lint.log` / `vendor-lint.json`、`lint-internal-errors.log` 和 `artifacts.json`。证据目录被 Git 忽略，以下摘要可随提交交付。

HAP SHA-256：`3E560A0626370991CDAFC5B259211C307EA3DB7C7D2CC6AE082F90029D322DD9`。

## 4. 下一阶段准入

2026-10-20，用户在阶段 A 构建完成后，按重新运行应用、检查首页启动、搜索样例和日程样例的步骤反馈“结果符合预期，继续推进”。据此记录这三项模拟器快速回归通过；设备型号、系统版本和安装包哈希未提供，不补写为实测信息。该反馈不代表真实网络、Runtime 或真机已通过。

阶段 B1 已按本机方案实施，范围和验证边界见第 5 节。

进入宿主/真实搜索接入前，需确认：

1. Agent 生产组合所需的存储、凭据、摘要计算、ID、恢复与模型 Gateway 的实际装配方式；不得以空实现冒充生产资源。
2. B1 的网络权限与 HDC 回环调试已获批准；后续真实供应商调用的开发环境和费用边界仍需确定。
3. 搜索结果、授权参数、错误与任务状态的映射；真实来源不能与固定答案混用。
4. 回答正文/引用、只重试回答和澄清响应的合同。现有应用后端有相关事件入口，但不等于所有页面交互已具备可直接调用的方法。

本阶段没有修改 Git 分支、提交或推送；后续由用户审核代码与文档后安排。

## 5. 阶段 B1：连接检查（2026-10-20）

### 用户流程与页面

调试构建在「我的」页面顶部展示「搜索服务连接 · 调试」。手动点击「检查连接」，显示检查中状态；工具发现完成后显示「已连接搜索服务，发现 web_search。检查已结束。」和实际协商的协议版本。点击「停止检查」、离开该页面或 Ability 进入后台时中止检查。

连接失败或超时显示可理解的提示和错误码，允许手动重试。重复点击不重复创建连接；清理完成前不显示成功，不允许开始下一次检查。清理阶段不并发执行第二次断开。

入口和服务层均使用 Hvigor 生成的 `BuildProfile.DEBUG`；release 禁止创建 MCP manager。没有开机自动连接或自动重试。搜索开关、日程和搜索样例继续属于 Mock。

### 实现与边界

| 文件 | 责任 |
|---|---|
| `services/McpProbeSession.ets` | 单次操作状态、15 秒检查期限、取消、观察者解绑和迟到结果隔离；只有连接/发现/清理端口，没有工具执行端口 |
| `services/McpConnectionCheckService.ets` | 使用公开 `McpClientManager`，固定回环地址、Legacy 协商、5 秒单请求超时；错误码转为固定提示，不显示远端原文 |
| `services/McpProbeContract.ets` | 对反序列化后的工具输入 schema 做运行时校验；不以类型声明替代校验 |
| `components/McpConnectionCheck.ets` | 检查入口、状态和停止操作；通过服务获取结果，不直接访问 manager |
| `EntryAbility.ets` | 后台取消、销毁时解绑与清理 |

检查唯一工具的名称、Server ID、能力类型、输出 schema 对象及输入字段/边界；这不是输出结果校验或搜索执行验收。调用序列为注册 → initialize → tools/list → 本地释放并尝试 DELETE，不调用 `tools/call`，未装配 Runtime 或授权策略。

取消时先断开当前请求，操作结束后再次清理，覆盖握手迟到创建会话的情况。检查期限不包含最后的清理等待；DELETE 最多继续等待单请求超时。上游客户端会吞掉 DELETE 失败，所以「检查已结束」只代表本地操作结束，不保证服务端已立即删除会话；服务端还有空闲回收机制。进程被杀死时不保证执行销毁回调，不持久化或自动续跑检查。

### 权限与官方依据

entry 仅新增 `ohos.permission.INTERNET`。该权限为 normal / system_grant，起始 API 9；本机 API 26 的 `permissions.d.ts` 也声明支持。由系统授权，不弹出危险权限申请框；这不替代后续 Runtime 的用户搜索授权。

- [OpenHarmony 官方权限说明](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/AccessToken/permissions-for-all.md#ohospermissioninternet)。
- [HarmonyOS 权限列表](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/permissions-for-all)。
- 构建模式依据本机 Hvigor 实际生成的 `entry/build/default/generated/profile/default/BuildProfile.ets`，包含 `DEBUG` 和 `BUILD_MODE_NAME`，且本轮真实 CompileArkTS 已验证导入方式。

本次未找到可用的 `devecocli` 文档命令或独立 `arkts_check` / `build_project` 工具，以官方文档、安装 SDK 与实际编译验证。用户已明确允许用项目第 7 节约束与官方 ArkTS 资料替代缺失的 `arkts-grammar-standards`，参考 Agent 仓库 `openharmony-development` skill；没有引入 `any`、`unknown`、类型断言或动态字段访问。

### 服务与设备复现

服务端新增独立 `start:discovery` 命令：复用真实 MCP 握手与目录实现，但不加载 `.env`、不创建 Tavily 适配器；工具执行明确拒绝，避免本次调试误发真实搜索。

```powershell
# 在仓库根目录；服务保持运行，下面设备操作用另一个终端。
npm.cmd --prefix services/search-mcp run build
npm.cmd --prefix services/search-mcp run start:discovery

# hdc 若不在 PATH，请使用本机 SDK 的 toolchains/hdc.exe。
hdc list targets
hdc -t <设备标识> fport ls
# 仅在确认没有占用/已有转发时执行，不覆盖其他任务。
hdc -t <设备标识> rport tcp:8787 tcp:8787
```

HDC 帮助确认 `fport ls` 同时列出正反向转发；并不存在 `rport ls` 子命令。当前会话已为模拟器 `127.0.0.1:5555` 建立本轮反向转发，电脑 8787 已启动仅发现服务；不要重复启动占用同一端口。该服务和转发暂留供用户验收，进程号保存在本机证据目录 `discovery.pid`，日志为 `discovery.log`。后续只清理本轮创建的资源，不终止其他进程。

### 验证记录

| 检查 | 本轮结果 |
|---|---|
| HAP 构建 | `assembleHap --no-daemon`，退出码 0，81 个任务（35 执行、46 最新），CompileArkTS 实际执行；未签名、未安装 |
| 连接逻辑 | `node entry/src/test/run-mcp-probe-tests.cjs`：13/13，通过 schema 拒绝、失败重试、取消、迟到隔离、超时、释放失败、重复点击及 release 禁用检查；使用注入替身，不代表设备网络 |
| 现有逻辑回归 | 原日程/搜索 20/20、悬浮位置 9/9 通过 |
| Node 服务 | `npm.cmd --prefix services/search-mcp test`：构建及原有 21/21 测试通过 |
| 本机握手 | 仅发现服务启动成功；`npm.cmd --prefix services/search-mcp run smoke` 发现 `web_search`，未传 `--search` |
| 静态检查 | 定向 Code Linter 退出码 0，报告 `[]`；内部仍有无效安全规则错误，不记为完整通过 |
| 上游一致性 | 156 个文件和 6 模块核验通过，vendor 未修改 |
| 应用内模拟器 / 真机 | 用户按重新运行 →「我的」→「检查连接」步骤反馈符合预期，正常路径通过；异常与取消设备路径、真机仍待验证 |

本机证据位于 `.local/agent-integration-stage-b1/`。当前未签名 HAP SHA-256：
`DE5BC7843D20761DAA5A72468191BCB778F6541E8B5D44B11B9C74C956DD6AAB`。

2026-10-20，用户按重新运行新版本 →「我的」→「检查连接」，核对发现 `web_search` 和协议版本的步骤反馈“结果符合预期，继续推进”。据此记录应用内正常连接路径通过；用户未提供具体协议值、机型/系统版本或安装包哈希，不补写这些字段。该结果与 Node 本机 smoke 分开记录。

待验收：停止/离开页面后的状态，以及无服务时的失败与恢复。B1 没有搜索结果、模型回答、Runtime 用户授权或真实计费证据。

## 6. B2 宿主装配前置核对

下一段目标是由 Ability 持有唯一的 `AgentApplicationBackend`，把用户问题交给 Runtime，并把授权与结果事件回传页面。手机宿主尚未实施，也未切换仅发现服务为真实搜索模式。2026-10-21 已完成电脑端网关的真实模型最小请求，证据见本节末尾；不代表手机链路通过。

已基于固定源码核对，当前组合入口 `createShuviApplicationBackend` 不是无需配置即可使用的实例。它内部调用带恢复能力的 Local AI Gateway 生产组合，不能用空资源、零价格或测试授权策略补齐必填项。

| 待交付/确认项 | 需要什么 | 源码证据与接入责任 |
|---|---|---|
| 模型网关 | 可访问基址、模型别名/版本、上下文上限、就绪状态；凭据由用户在本机安全配置 | `LocalAIGatewayTransportProfile` 默认 `available=false`、版本为空；默认 4000 只是配置值，不是本机网关已运行的证据 |
| 宿主最小示例 | 调用 `createShuviApplicationBackend` 的完整生产装配，标明哪些资源由 Agent、平台或 UX 实现 | `ShuviApplicationBackendPorts` 要求 host、runtime ports 及 MCP manager/registry/adapter；测试宿主不能直接替代 |
| 存储与凭据 | credential resource、execution storage、memory storage 的 open/close，恢复源、密钥来源与错误处理 | `SingleAgentHostRuntime` 按顺序打开资源，失败回滚；需要真实资源实现，不能写空 `open()` |
| ID、摘要、预算和策略 | 实际 ID 与摘要实现、policyVersion、grantTtlMs、任务预算、匹配模型版本的价格快照 | `ProductionRuntimeTypes.ets`、`ProviderPriceSnapshot`；测试值不是生产成本依据 |
| 授权内容 | 用户确认前如何取得实际待外发关键词，而不只是原始输入 | `AgentFrontendAuthorizationPrompt` 有工具、Provider、风险、费用和有效期，但没有待执行参数摘要 |
| 澄清及结果边界 | 澄清回应入口；真实搜索结果 schema；后续回答/引用及仅重试回答合同 | 应用后端有澄清通知，但未公开对应的回应方法；不能绕过通知或重新提交任务冒充仅重试回答 |

Agent 上游 `docs/LOCAL_AI_GATEWAY_INTEGRATION.md` 记录的是另一台开发环境的网关与历史验收，不能当作本机网关已配置的证据。`ShuviWebSearchDevice.test.ets` 中的 `DeviceDigest` 是字符串拼接，`DeviceAllowSearchPolicy` 是测试专用允许策略；二者不得复制进 Shuvi 生产装配。

2026-10-20，已读取用户提供的 [Local AI Gateway 仓库](https://github.com/AlterGo-xzy/local-ai-gateway)，默认分支 `codex/develop` 的提交 `21017a1e91a1067119f4772762295c3e343cef40` 与 Agent 集成说明引用版本一致。源码确认其为独立 Windows 模型网关，默认回环端口 `4000` 与 Agent 默认配置路径匹配。本轮查询无 GitHub Release；完整包所需私有运行时不由源码 CI 直接交付。本机安装、模型配置、手机到网关的连接及真实调用均未验证。现有 `8787` 转发仅用于搜索 MCP，不能作为网关可达证据。详细源码链接和交付要求见根目录交接文件。

同日，经用户授权已克隆至 `E:\local-ai-gateway` 并完成本机构建准备：Release 编译、自包含测试 588/588、私有运行时导入、假上游协议 smoke、M3e 网关组合验收通过。随后发现本机已有 `f1de4b0` 安装，诊断通过但未运行；保留该安装，按用户选择新增独立 DeepSeek Profile，尚未填入凭据或激活。真实供应商调用和手机模型链路仍未完成，不将本机测试等同于 B2 验收。证据位于该网关仓库 `artifacts/LOCAL_SETUP.md`。

### 2026-10-21：电脑端真实模型验证

用户已保存 DeepSeek 密钥，活动 Profile 为 `shuvi-deepseek`（修订号 8）。使用已安装的 `f1de4b0` Runtime；未升级安装。电脑回环地址 `http://127.0.0.1:4000` 的就绪检查及模型列表通过，别名 `aigw/default` 可用。

北京时间 14:53:29，Node 探针经官方 launcher 注入客户端令牌，调用 Chat Completions 返回 HTTP 200、预期 `OK`、结束原因 `stop`；该成功响应报告 15 输入 + 1 输出 = 16 tokens。成功前有两次 HTTP 400 和一次 HTTP 500，不省略失败记录，也不把成功用量当作全轮费用。最终请求将 `thinking: { type: 'disabled' }` 放入 `extra_body`，非流式、输出上限 64 tokens、无工具调用。原始密钥、客户端令牌和远端错误正文均不记录。

当前限制：普通 CLI `start/run` 返回内部错误，直接隐藏启动 `aigw-runtime.exe --serve` 并使用独立 launcher 后可调用，CLI 问题未修复。沙箱与真实用户环境的配置视图不同，不能依据沙箱内“配置不存在”重复初始化用户配置。

本机证据：`.local/agent-integration-stage-b2/gateway-smoke.cjs`、`gateway-smoke-result.json` 和逐次脱敏结果。固定版本 ArkTS Transport 尚无 `extra_body/thinking` 字段，且 Planner 请求包含结构化输出要求，因此不能用该 Node 文本探针替代 Agent 适配验收。设备 4000 端口、设备凭据、生产宿主资源及真实搜索仍待接入。本轮仅增加本地探针与更新记录，没有修改 ArkTS 或重跑应用构建。

请 Agent 同学提供完整宿主示例，并对齐思考模式、结构化输出、模型能力与价格快照；凭据不要放进文档、消息或代码。确认后再实现宿主资源与页面服务并验证手机真实请求。给 Agent 的简短交接文字见仓库根目录 `SHUVI_AGENT_B2_HANDOFF.md`。
