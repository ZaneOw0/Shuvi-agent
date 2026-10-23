# Shuvi 与 Agent：B2 接入交接

更新日期：2026-10-21。当前 Agent 固定提交：`a12b6a18cbbf1188a4708997f73cea3b55860fed`。

## 我们已经完成

- Shuvi 已导入六个固定版本 HAR 源码模块并通过构建，原 Mock 回归通过。
- 调试版已具备真实 ArkTS MCP Client 连接检查；用户确认应用内发现 `web_search` 和协议显示符合预期。
- 应用连接的搜索服务为仅发现模式，禁止工具执行；还没有通过手机 Runtime 执行搜索或生成回答。电脑端网关的真实 DeepSeek 最小请求已于 2026-10-21 通过，详见下文。
- B1 的停止/离开、无服务及恢复路径已有宿主逻辑测试，设备验收待补；正常连接通过不等于全部联调通过。

## 请 Agent 同学补充

1. **提供 `createShuviApplicationBackend(config, ports)` 的最小完整生产宿主示例。**
   请标出 credential、execution storage、memory storage、恢复源、ID、摘要、MCP adapter/registry 的创建方式和资源归属。哪些由平台同学提供、哪些由 UX 完成，需要明确。
2. **对齐 Local AI Gateway 的模型配置。**
   已确认仓库与 Agent 引用版本一致，并在本机克隆、编译和组装运行时，详见下节。请确认非敏感的模型供应商、基址、模型别名和版本、额度/上下文限制、价格快照及预算建议。网关凭据由开发者在本机安全配置，不发给 AI，也不写进仓库。
3. **确认准确授权信息的获取方式。**
   当前前端授权 DTO 不包含待外发参数摘要。Planner 可能改写关键词，因此不能把用户原输入直接标成实际搜索词。请给出已有读取路径或提出公共合同变更。
4. **确认首轮交互范围。**
   首轮以授权后真实来源到达页面为目标。澄清回应、回答正文/引用、仅重试回答还需说明稳定入口；若暂不支持，请明确限制，UX 将禁用对应真实操作。

## Local AI Gateway 仓库核对（2026-10-20）

仓库：[AlterGo-xzy/local-ai-gateway](https://github.com/AlterGo-xzy/local-ai-gateway)。默认分支 `codex/develop`，本轮读取提交 `21017a1e91a1067119f4772762295c3e343cef40`，与 Agent 集成说明引用的网关提交一致。

- **定位**：Windows 上独立运行的 .NET 网关，包含私有 Python / LiteLLM 运行时。它为 Agent 提供模型 HTTP 接口，不是手机 HAR，也不是 Shuvi 的联网搜索 MCP 服务。
- **接口**：默认仅监听回环地址，端口 `4000`；包含 `/health`、`/ready`、`/v1/models`、`/v1/chat/completions`、`/v1/responses`、`/v1/messages`。Agent 默认基址 `http://127.0.0.1:4000/v1` 与其路径匹配；路径匹配不代表端到端验证完成。
- **认证与配置**：网关认证中间件也覆盖健康检查。客户端使用网关本地令牌；上游模型供应商凭据由网关管理，二者与 Tavily 搜索凭据分开。模型别名通过活动 Profile 映射到供应商模型，不能假定示例别名已配置。
- **交付限制**：本轮查询 GitHub Releases 为空。README 明确完整包还需要组装被忽略的私有运行时，源码 CI 不生成完整 ZIP；文档中的 `artifacts/` 安装包及本机安装路径属于作者环境，不能当作本机可用文件。
- **设备访问**：手机上的 `127.0.0.1` 不指向电脑。已有 `8787` 搜索服务转发不覆盖网关 `4000`；后续需单独核对调试转发及实际可达性。
- **分发边界**：当前 LICENSE 为保留所有权利，未授予复制、修改或分发许可。若需把网关随参赛交付物分发，应先与作者确认许可；当前不将其源码或运行包纳入 Shuvi。

证据：[README](https://github.com/AlterGo-xzy/local-ai-gateway/blob/21017a1e91a1067119f4772762295c3e343cef40/README.md)、[接口白名单](https://github.com/AlterGo-xzy/local-ai-gateway/blob/21017a1e91a1067119f4772762295c3e343cef40/src/LocalAIGateway.Runtime/PublicEndpointPolicy.cs)、[默认监听配置](https://github.com/AlterGo-xzy/local-ai-gateway/blob/21017a1e91a1067119f4772762295c3e343cef40/src/LocalAIGateway.Runtime/GatewayRuntimeOptions.cs)、[认证实现](https://github.com/AlterGo-xzy/local-ai-gateway/blob/21017a1e91a1067119f4772762295c3e343cef40/src/LocalAIGateway.Runtime/GatewayAuthentication.cs)、[LICENSE](https://github.com/AlterGo-xzy/local-ai-gateway/blob/21017a1e91a1067119f4772762295c3e343cef40/LICENSE)。

首次仓库核对时仅阅读远程文档和源码；后续本机准备及真实调用进展分别记录如下。

### 后续本机准备（同日）

用户随后授权克隆到 E 盘并开展工作，已克隆到 `E:\local-ai-gateway`，固定提交未变化。在该仓库 `artifacts/` 中准备 .NET SDK 10.0.302 / PowerShell 7.6.7，校验全部 109 个运行时下载输入，组装 CPython 3.14.5 / LiteLLM 1.95.0。

Release 编译通过；自包含模式测试 588/588 通过；运行时导入、假上游协议 smoke 和 M3e 实际组合验收通过。M3e 验证就绪、配置重载和停止，结束后无私有测试进程及运行状态残留。默认测试的隔离子进程不能找到便携 .NET 10，使用自包含构建解决，未放宽断言。另在网关仓库补充 `.gitattributes`，避免 Windows CRLF 转换破坏哈希清单；尚未提交。

这些结果不代表真实供应商调用或手机联调完成。后续只读检查发现本机已有 `f1de4b0` 安装，`doctor` 本地诊断通过但服务未运行，故未重复安装或升级。用户选择 DeepSeek 后，已新增独立 `shuvi-deepseek` Profile，使用 `openai-compatible`、`https://api.deepseek.com`、上游模型 `deepseek-flash`，对 Agent 暴露别名 `aigw/default`。尚未切换活动 Profile、读取或写入凭据、启动正式服务或调用模型。API Key 等待用户在本机隐藏输入，手机链路仍未配置。

网关安装程序的产品路径固定为当前用户 Local AppData，并非 E 盘源码目录。本机证据和复现步骤见 `E:\local-ai-gateway\artifacts\LOCAL_SETUP.md`。模型 ID 依据 [DeepSeek 官方文档](https://api-docs.deepseek.com/zh-cn/)（2026-10-20）核对；供应商模型别名可能随其升级，尚未将价格与能力声明写入 Agent 生产配置。

### 真实模型验证（2026-10-21）

用户已通过隐藏输入保存供应商密钥；当前活动 Profile 为 `shuvi-deepseek`，配置修订号为 8。保留已安装的 `f1de4b0` 版本，未用新构建包覆盖。此前“等待保存、尚未激活”的记录为历史状态。

- 电脑端 `/ready` 和 `/v1/models` 检查通过；`aigw/default` 映射到 `deepseek-flash`。
- 北京时间 14:53:29，`POST /v1/chat/completions` 返回 HTTP 200、预期文本 `OK` 和结束原因 `stop`；成功响应报告输入 15、输出 1，共 16 tokens。这不是全部尝试的账单统计。
- 本轮探针共提交 4 次模型 HTTP 请求：前两次 HTTP 400，第三次 HTTP 500，最后一次成功。成功请求使用 `extra_body: { thinking: { type: 'disabled' } }`，`max_tokens=64`、非流式、无工具调用。顶层 `thinking` 遇到不支持参数错误；增加 `allowed_openai_params` 的尝试仍失败，未确认该 HTTP 500 的最终根因。
- 密钥未进入脚本、命令参数或输出。官方 `aigw-launcher.exe` 将客户端令牌注入 Node 子进程环境；探针仅输出脱敏结果及数字用量。
- `aigw start` / `aigw run` 本轮出现内部错误，尚未修复。直接隐藏启动已安装的 `aigw-runtime.exe --serve` 后，独立 launcher 调用成功。服务暂留供后续联调；不能据此标记 CLI 启动路径通过。

探针和结果位于本机 `.local/agent-integration-stage-b2/`：`gateway-smoke.cjs`、`gateway-smoke-result.json` 及带时间戳的结果文件。当前成功参数参考 [DeepSeek 思考模式文档](https://api-docs.deepseek.com/guides/thinking_mode/)。

**与手机接入的差异**：固定版本 `LocalAIGatewayTransport.ets` 构造 `model/messages/max_tokens/temperature`，结构化请求还包含 `response_format`，但没有 `thinking` 或 `extra_body`。本次 Node 文本探针不等价于该 ArkTS 请求；仍需对齐思考模式及结构化输出配置，再验证真实 Planner 请求。手机到 4000 端口、设备凭据配置和生产宿主装配均未完成。本次没有修改 vendor、ArkTS 或公共契约，也未重跑应用构建。

## 接入原则

- 页面只通过应用服务使用后端，不直接操作 MCP manager 或模型。
- 不采用测试里的字符串摘要和默认允许策略来绕过真实 Runtime 授权。
- 不用空存储资源冒充初始化成功，不凭默认 4000 端口假定网关已运行。
- 不修改当前 vendor 快照解决公共合同问题；上游修复后核对固定版本再升级。
- 不把真实来源和 Mock 回答混在同一条真实任务中。

可直接发给 Agent 同学：

> Shuvi 已完成六个 Agent 模块的编译接入，应用内 MCP 握手和发现 web_search 的正常路径也已通过。电脑上已通过 Local AI Gateway 调用 DeepSeek，最小文本请求返回 HTTP 200；使用 aigw/default → deepseek-flash，并通过 extra_body 关闭思考模式。手机 Transport 尚无对应参数，结构化 Planner 请求还需一起验证；CLI 普通启动路径也有内部错误待查。请提供 createShuviApplicationBackend 的完整生产宿主装配示例，明确设备凭据与存储的实现归属，并对齐模型能力、价格快照和实际搜索参数的授权展示。不要发送密钥；下一目标是用户确认后，真实来源回到页面。

详细证据见 [Agent 模块接入](docs/06-Agent模块接入.md)。本文仅为待对齐清单，未声称上述前置条件已满足。
