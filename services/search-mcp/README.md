# Shuvi 联网搜索 MCP Server

> v0.1，本机服务端首轮验收已完成，范围见 spec 第 6 节。独立 Node.js 服务，不打包进鸿蒙 HAP。
> 2026-10-14：TypeScript 构建及 21 项本机测试通过；真实 Tavily 搜索、ArkTS 客户端、Runtime 和页面接入尚未验证。
> 2026-10-16：开发者确认双终端启动、MCP 握手和工具发现结果符合预期；该步骤未发送真实搜索。
> 同日后续：开发者提供一次真实 Tavily 搜索输出，返回 3 条标题、链接和摘要，并确认第一条来源核对完成。证据见 spec 第 6.3 节，Agent / UI / 设备仍未接入。

本服务通过官方 MCP SDK 提供一个 `web_search` 工具，将 Tavily Search API 返回的网页标题、链接和摘要转换为统一结果。正式行为约定见 [联网搜索 spec](../../specs/03-联网搜索.md)，跨模块契约仍待 Agent 同学确认。

## 1. 环境与目录

需要 Node.js 24.x；本轮实际验证版本为 24.14.1。依赖版本由 `package-lock.json` 固定，使用 npm，与根目录的 OHPM / Hvigor 工程独立。

| 文件 | 用途 |
|---|---|
| `src/search.ts` | 参数与供应商响应校验、Tavily 请求、超时取消和错误分类 |
| `src/server.ts` | MCP 工具注册、HTTP 入口、会话与并发限制 |
| `src/main.ts` | 读取本机环境配置并启动服务 |
| `src/discovery.ts` | 固定回环 8787 的连接检查入口，不读取凭据，拒绝搜索执行 |
| `src/smoke.ts` | 本机 MCP 验证客户端；默认只发现工具 |
| `test/` | 不访问 Tavily、不消耗搜索额度的确定性测试 |
| `.env.example` | 配置占位模板，包含空的凭据字段 |

运行依赖为 `@modelcontextprotocol/sdk`、`zod`；开发依赖为 `typescript`、`@types/node`。不新增鸿蒙依赖、权限或公共 Runtime 接口。

## 2. 第一步：只验证本机连接

在 PowerShell 中运行：

```powershell
cd E:\Shuvi-agent\services\search-mcp
node --version
npm.cmd ci --ignore-scripts
npm.cmd test
npm.cmd start
```

`ci` 根据锁文件安装依赖，`test` 先构建再运行测试，`start` 使用构建产物启动服务。Windows 使用 `npm.cmd`，无需更改 PowerShell 执行策略。本机已经安装并测试通过时，可以直接运行 `npm.cmd start`。

看到 `http://127.0.0.1:8787/mcp` 后，保持该终端运行，在第二个终端执行：

```powershell
cd E:\Shuvi-agent\services\search-mcp
npm.cmd run smoke
```

预期输出包含：

```text
可用工具: web_search
仅握手和工具发现通过，未发送搜索请求。
```

这一阶段不需要 `.env` 或 Tavily 凭据，不发送真实搜索。缺少凭据时，服务仍可启动并列出工具；如果调用搜索，会明确返回 `CONFIGURATION`。

当前验证脚本固定连接 8787 端口。服务支持通过 `PORT` 配置其他端口，但相应客户端地址需自行同步，首轮验收请使用默认端口。

### 2.1 设备连接验收专用模式

只验证连接时，建议用以下命令替代 `npm.cmd start`：

```powershell
npm.cmd run build
npm.cmd run start:discovery
```

此入口复用真实 MCP Server 的握手与工具目录，固定监听 `127.0.0.1:8787`，不加载 `.env`、不创建 Tavily 搜索适配器。即使进程环境含凭据，工具执行也只返回 `CONFIGURATION`；不会返回假搜索结果。另一个终端仍可运行 `npm.cmd run smoke` 做握手检查，不传 `--search`。普通模式与此模式不能同时占用 8787。

Shuvi 调试版通过 HDC 回环转发访问此服务，步骤与权限说明见 [Agent 接入记录](../../docs/06-Agent模块接入.md#5-阶段-b1连接检查2026-10-20)。检查完成后，用 `Ctrl+C` 关闭自己在终端启动的服务。

## 3. 第二步：开发者手动启用真实搜索

先完成上述连接验证，再在本机创建配置。以下命令仅在文件不存在时复制模板：

```powershell
if (!(Test-Path -LiteralPath .env)) { Copy-Item -LiteralPath .env.example -Destination .env }
```

用本地编辑器打开 `.env`，自行填写 Tavily API Key。不要把密钥、配置全文或带密钥的截图发送给 AI 或写入提交。该文件已被本目录 `.gitignore` 排除；AI 不读取真实配置。环境变量优先于 `.env` 中的同名配置。

在服务终端按 `Ctrl+C` 停止，再运行 `npm.cmd start`。在第二个终端执行：

```powershell
npm.cmd run smoke -- --search
```

这会调用一次 `web_search`，查询固定公开关键词「HarmonyOS ArkUI 官方开发文档」，最多返回 3 条结果，可能消耗 Tavily 额度。没有自动重试。成功后人工核对标题、链接、摘要是否一致；空结果只说明调用完成，不能作为来源展示通过的证据。

启动日志不记录凭据、关键词或响应体。验证客户端会显示这条固定公开查询的结果，便于人工验收。失败时退出码为 1，不记为通过。

## 4. 运行边界

- 只监听 `127.0.0.1`，仅供同一台电脑上的原生 MCP 客户端使用。手机中的 `127.0.0.1` 指向手机，不能据此连接电脑。
- `/mcp` 使用 Streamable HTTP、JSON 响应及会话 ID；支持 POST 和 DELETE，不提供 GET SSE 流。
- 拒绝非本机 Host 和带 Origin 的浏览器请求；本地其他进程仍可能访问，因此它不是多用户认证服务。
- 空闲会话在超过 120 秒后由每 30 秒一次的扫描清理，过期需重新握手。最多 16 个会话、4 个同时执行的搜索。
- 每次搜索上游超时 15 秒，覆盖响应体读取；MCP 取消通知及服务正常关闭会中止仍在进行的上游请求。取消不保证退还供应商额度。
- 不保存搜索历史或任务，不自动恢复中断任务；正常退出使用 `Ctrl+C`。
- 公网或局域网部署、认证、配额管理和设备访问需后续单独设计。不要只修改监听地址便用于远程访问。

## 5. 验证与集成状态

`npm.cmd test` 覆盖本机 MCP 协议调用、输入与响应校验、鉴权/限流/配额错误映射、超时和取消；上游搜索由测试替身提供，本机 HTTP 用于验证响应读取阶段的中断。通过不等于真实联网搜索通过。

根目录现有 CI 检查鸿蒙工程，尚不运行本目录测试。当前 PR 需另附本目录构建和测试记录；在将服务作为团队持续交付内容前，与平台负责人确认 Node.js CI 作业。

对接 Agent 时交付 spec、工具 schema 和验证记录。先确认客户端协议、会话、结果解析、允许列表及授权，再接入 Runtime；不绕过已有工具策略。当前页面和日程 Mock 不会调用这个服务。

交接给 Agent 负责人的最小信息：

| 项目 | 内容 |
|---|---|
| 工具 | `web_search`，参数为 `query` 与可选 `maxResults`，详见 spec 第 4 节 |
| 传输 | Streamable HTTP，当前仅本机 `http://127.0.0.1:8787/mcp`，不作为手机可访问地址 |
| 结果 | `structuredContent` 与等价 JSON 文本；成功返回来源数组，失败标记 `isError` |
| 验证证据 | 21 项确定性测试、一次 Tavily 真实调用、开发者核对第一条来源 |
| 待双方确认 | 工具允许列表与授权、schema 解析、协议协商、会话和取消行为；实际 ArkTS 客户端版本 |
| 后续集成 | 先确定设备访问与认证方案，再接 Runtime 和页面；本服务端不管理 RAG 或模型回答生成 |

## 6. 官方依据

- [MCP TypeScript SDK](https://ts.sdk.modelcontextprotocol.io/server)
- [MCP Streamable HTTP 传输规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [Tavily Search API](https://docs.tavily.com/documentation/api-reference/endpoint/search)
- [Tavily 额度说明](https://docs.tavily.com/documentation/api-credits)
