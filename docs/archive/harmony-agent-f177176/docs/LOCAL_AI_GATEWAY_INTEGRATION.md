> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/LOCAL_AI_GATEWAY_INTEGRATION.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Local AI Gateway 集成说明

`@harmony_agent/agent-connectors` 0.6.0 提供 `LocalAIGatewayModelTransport` 和具体 production composition 工厂。transport 把 M07 `ModelTransportPort` 映射到 OpenAI-compatible `POST /v1/chat/completions`；工厂把 catalog、credential/timer runner、Generic Provider、Semantic Planner 与 MCP production runtime 组装起来。它不增加任务控制接口，外部调用方仍只能通过 `AgentRuntimeFacade` 控制 Agent。

## 已核对的网关契约

2026-10-12 对 `C:\claude-gateway` 的只读核对基于 `codex/develop`、commit `21017a1e91a1`。网关公开监听基址为 `http://127.0.0.1:4000`，模型入口包括 `/v1/chat/completions`、`/v1/responses` 和 `/v1/messages`，健康入口为 `/health` 与 `/ready`。本适配选择 `/v1/chat/completions`，默认公共 alias 为 `aigw/default`。

每次请求必须提供一个本地网关 token。本适配接受 `Authorization: Bearer ...` 或 `x-api-key` 中的一种，并拒绝空值、同时提供两种认证方式或附带其他 credential header。token 必须由 `ProviderCredentialPort` 在调用时解析；API 26 产品宿主可使用仓库提供的 `AssetStoreProviderCredentialPort`。token 不能写入源码、Profile、任务 DTO、日志、报告或快照。

## 宿主装配

宿主创建 transport profile、同一时点冻结的价格快照、Runtime config/ports，并注入 digest 与 credential port：

```ets
const gateway: LocalAIGatewayTransportProfile = new LocalAIGatewayTransportProfile();
gateway.modelVersion = activeGatewayProfileRevision;
gateway.maxInputTokens = 32768;
gateway.maxOutputTokens = 4096;
gateway.qualityTier = 1;
gateway.privacyClasses = [PrivacyClass.PUBLIC, PrivacyClass.PERSONAL];
gateway.available = readyAtSnapshotTime;

const config: LocalAIGatewayMcpRuntimeConfig = new LocalAIGatewayMcpRuntimeConfig();
config.runtimeConfig = runtimeConfig;
config.plannerConfig = plannerConfig;
config.transportProfile = gateway;
config.priceSnapshot = priceSnapshot;

const ports: LocalAIGatewayMcpRuntimePorts = new LocalAIGatewayMcpRuntimePorts();
ports.runtimePorts = runtimePorts;
ports.digest = digestPort;
ports.credentials = credentialPort;

const runtime: AgentRuntimeFacade = await createLocalAIGatewayMcpProductionAgentRuntime(
  config, ports, mcpAdapter, toolRegistry);
```

工厂会完成 `ProviderCatalog` 注册，默认构造 `ArkTsLocalAIGatewayHttpClient` 与 `SystemProviderTimer`；测试可通过 ports 注入替代实现。`priceSnapshot.providerId` 必须等于 `local-ai-gateway`，`capabilityId` 必须等于 `aigw/default`，version/region 必须匹配 gateway profile。价格应反映活动 Profile 实际路由的上游成本；不能用测试用零价格代替生产快照。

Runtime-facing 请求继续使用稳定的 `model.local.gateway`。`GenericModelProvider` 在 transport 边界把它转换为 Provider alias `aigw/default`，冻结 model version、region、price snapshot，并统一结算 usage/cost。JSON object schema 会映射为 `response_format.json_schema`；空 object schema 不发送 `response_format`。当前实现使用单次非流式响应，收到完整结果后向 observer 发送一个规范化 chunk。

## 网络和权限

`ArkTsLocalAIGatewayHttpClient` 使用 `@ohos.net.http`，最终产品宿主必须声明 `ohos.permission.INTERNET`。HAR 自身不能授予权限。

默认地址仅允许 `http://127.0.0.1:<port>/v1` 或 `http://localhost:<port>/v1`，并校验端口范围。它适用于与网关处于同一网络命名空间的宿主。HarmonyOS 设备或模拟器中的 `127.0.0.1` 指向设备自身，不会自动到达 Windows 主机；设备验收必须另行建立并记录明确的端口转发或受控桥接，验证 `/ready`、认证调用、取消/timeout 和清理。

仓库已准备 `tools/gateway-device-bridge.mjs` 作为设备验收专用的短生命周期桥接层。它只监听 Windows `127.0.0.1`，只接受 `/ready` 与 `/v1/chat/completions`，设备侧使用固定的非秘密测试标记；桥接进程把该标记替换为 `aigw run` 注入的真实 runtime token，再转发到 loopback 网关。桥接不记录 credential、请求正文或响应正文，并限制请求/响应大小。Node 假上游测试 2/2 已通过，覆盖 token 替换、错误标记拒绝、远程上游拒绝和大小限制。该结果只证明桥接实现，不等于 HDC `rport`、HAP 构建/签名/安装、设备调用或真实 Provider 设备验收。

`test_host` 的 `LocalAIGatewayDevice` 包含两项无页面用例：HAR 加载，以及通过设备 `127.0.0.1`、HDC `rport` 和短生命周期桥接调用 `aigw/default`。后者只断言固定文本、finish reason 与 usage 完整性，失败时不把原始模型文本写入断言。API 26 的 `AbilityDelegatorArgs.parameters` 可能把 `aa test -s gatewayPort <port>` 暴露为字面键 `-s gatewayPort`；设备测试先读取规范键，再兼容该字面键。修复后 unsigned 主 HAP 为 8,900 bytes、SHA-256 `C164FBABD0A7CEEC77CD3971034A08E1240161E194C1CDED7C81C44F15FDB9D4`；ohosTest HAP 为 3,191,501 bytes、SHA-256 `24659AD4C308185FDAB2761D15CBFD8B6C1F4DA54DF88192EFCD7B4071A88E73`。

设备 orchestrator 在安装前检查同包名 bundle。默认模式遇到既有 `com.harmony.agent` 会失败；显式 `-PreserveExistingMain` 只允许既有 `test_host` 且不存在 `test_host_test` 的场景，只安装并最终按模块卸载测试 HAP，保留主模块。脚本还拒绝覆盖既有设备端口转发，并用完整 HDC task pair 移除本轮反向转发。签名、安装和运行仍需单独授权。

## 当前证据边界

T40 时 SDK 原生 Previewer/Hypium 运行 `agent_connectors` 55/55。T35 的 3 项覆盖具体 Provider 链经唯一 Facade 生成 typed workflow、解析一次 credential、发起一次 gateway HTTP、等待授权后完成一次 MCP Tool，以及恢复工厂和网络前 fail-closed；T37 证明显式 `CollaborationSelectorPort` 能贯穿具体网关 composition，且 Multi 激活预算不足时在 credential、HTTP 与 MCP 前拒绝；T39/T40 又把版本化 `CollaborationPlan` 接入具体 composition，并按计划为每个角色发起独立 Provider 请求、顺序修订 typed workflow。T40 的 Release HAR 为 61,831 bytes、SHA-256 `120A65A82BA87CB7A79C948C1963A2070CA2E678ABC8F54134156A94BA10A540`，包内版本 0.8.0、`debug=false`。这些主机门使用内存 credential/timer/HTTP/MCP fixture；T36 已另行取得 signed API 26 的真实 Windows 网关、上游 Provider、设备网络、唯一 Facade 和一次 MCP Tool 闭环证据。T40 没有真实 Provider 或设备证据；真实取消/timeout 与 S6 12×2 system Bench 当时仍未验证。

P0-C 增加 AssetStore credential resolver 后，当前 Connector 主机套件为 65/65；Release HAR 为 67,249 bytes、SHA-256 `176DE3443BB09836D6B6B2433237127599E17441CD11F7061A1D72622C5F9F5E`。这证明只读查询适配器的 API 26 类型和打包，不证明真实 Asset 写入、轮换、锁屏策略或签名设备查询。

2026-10-13 的只读查询确认已安装 `aigw.exe`，配置中已有一个完整且已选中的 Profile，并提供默认 alias `aigw/default`。

2026-10-17 的 T42 初次查询由普通沙箱进程执行，读到隔离的 revision 0/空 Profile 列表；该结果不代表 Windows 当前用户的网关配置。随后在实际当前用户上下文以同一安装版 CLI 做只读复核：`config validate --json` 返回 `valid=true`、revision 13；`profile list/show --json` 显示 `deepseek` 为 active/complete；Provider `official` 指向 `https://api.deepseek.com`；默认 alias `aigw/default` 映射上游模型 `deepseek-flash`；`config.json` SHA-256 为 `3E3FE8EE7F9E170C809E263B3191A28426C8DC9E41538AA27B820D5442DA9E95`。`status --json` 仍为 `running=false`，因此配置已就绪但 Runtime 当前未启动。复核没有读取 Credential Manager、配置密文或上游凭据，也没有启动 Runtime 或发送 Provider 请求。T42 已完成执行准入合同与费用封顶；实际执行前仍需取得最多 39 次请求、US$0.43134 最坏费用的明确批量授权，并在执行窗口启动 Runtime。

仓库提供 `tools/test-local-ai-gateway.ps1` 作为受控真实 smoke probe。它只能由 `aigw run --client ...` 注入 loopback base URL 和当前用户 runtime token；脚本拒绝工作区外输出，不打印或持久化 token，也不保存原始 Provider 响应或错误 message，只记录 `/ready`、chat HTTP 状态、固定回复是否匹配、finish reason、token usage，以及失败时可选的 `error.code`/`error.type`。运行该 probe 会启动已安装网关并发起一次真实上游模型请求，必须单独授权；完成后的进程停止也必须包含在同一授权范围内。

三次真实 smoke 已于 2026-10-13 逐次授权执行。三次 `/ready` 均返回 200，说明已安装 Runtime、受管 token 注入、本地认证及活动配置加载成功。原上游模型 `deepseek-v4-flash` 的两次 `POST /v1/chat/completions` 均返回 404，第二次脱敏诊断只提取到 Provider `error.code="404"`，`error.type` 缺失。随后在无密钥 revision 6 备份保护下临时改用 `deepseek-flash`；该请求返回 403，`error.code="403"`、`error.type` 缺失，说明 Provider 对新模型名的处理不同，但当前账号权限或 Provider 策略仍拒绝完成。三次都没有保存错误 message 或原始响应。网关 usage 累计记录 3 次失败，输入、输出和总 token 均为 0。三次 finally stop 均成功，最终复核 `running=false` 且端口 4000 无监听。

无凭据的独立路由检查中，配置上游的 `/v1/models` 与 `/v1/chat/completions` 均返回 401，证明域名和 API 路径存在。网关源码核对确认请求进入 public endpoint 后先校验 alias，再由生成的 LiteLLM 配置把 `aigw/default` 映射到 Provider 专用上游模型；public alias 不会原样发送给上游。现有脱敏证据把故障范围收敛到 Token Hub 的模型目录、账号权限或 Provider 策略。真实 Provider 门仍未关闭；下一步需要配置所有者确认该账号实际可用的模型 ID，任何再次计费请求都应单独授权。

候选模型验证失败后的自动回滚暴露了已安装网关的配置写入问题：第一次 `model update` 成功生成 revision 7 与 `config.json.bak`，此后的三次官方 CLI 回滚均返回 `aigw_config_io`。文件独占句柄检查排除了残留进程锁；只读源码检查显示 `ConfigurationStore` 使用 `File.Replace`，仅在 `UnauthorizedAccessException` 时进入备用原子移动路径，本机 EFS 配置文件触发的 `IOException` 不会回退。最终以已验证 SHA-256 的网关自动备份交换恢复 revision 6/`deepseek-v4-flash`，revision 7/`deepseek-flash` 同时保留为自动备份和工作区证据。该恢复没有读取凭据或再次访问 Provider。修复网关保存逻辑前，不应依赖连续 `model update` 自动回滚。

2026-10-13 16:00 的更新后只读核对确认：安装版本为 unsigned development `0.1.1-dev+b7fbc52`，活动配置已变为 revision 11，完整 Profile `deepseek` 通过 OpenAI-compatible Provider `https://api.deepseek.com` 把 `aigw/default` 映射到 `deepseek-flash`。Runtime 当时正在运行，doctor healthy、target circuit closed、连续失败为 0；该检查明确标记 `modelProbePerformed=false`、`upstreamContacted=false`，因此只是新配置预检。安装提交相对先前核对的源码只改动 `README.md` 和 `scripts/package.ps1`，没有改变 Runtime 或 `ConfigurationStore`，上段 `IOException` 回退缺口仍然存在。

同日 22:45 经单次明确授权执行更新后真实 smoke。执行前真实配置为 revision 12，Profile `deepseek` 完整且活动，`aigw/default` 仍映射到官方 Provider 的 `deepseek-flash`。探针取得 `/ready` 200 与 `/v1/chat/completions` 200；usage 前后差值为 1 次成功、42 input tokens、24 output tokens、66 total tokens，证明受管 runtime token、本地认证、alias 路由和官方 DeepSeek 请求链路已实际工作。模型输出在 `max_tokens=24` 处以 `finish_reason=length` 结束，固定文本未完全匹配，因此严格内容断言保持失败，未自动重试。证据不含 credential、原始响应或错误正文；网关在 finally 中停止，postcheck 确认恢复到执行前的 `running=false`。该结果仍不证明 HarmonyOS 设备 loopback、设备网络、真实取消/timeout 资源释放或 S6 benchmark。

为避免下一次获准验证重复命中同一截断条件，probe 的 `MaxOutputTokens` 已改为显式范围校验参数，默认值为 128，并写入脱敏摘要。该修改本身不启动网关、不访问 Provider，也不改变已记录的 24-token 结果；后续真实请求仍需单独授权。

同日 23:22 的严格主机复验以 `max_tokens=128` 取得固定内容完全匹配、`finish_reason=stop`，只产生 1 次成功请求；usage 差值为 42 input、33 output、75 total tokens。证据位于 `artifacts/t28-local-ai-gateway-connector/20261012-215538/strict-content-20261013-232245/`。

同日 23:33 的 API 26 设备验收使用已安装的 `test_host` 主模块与 unsigned `test_host_test`，`LocalAIGatewayDevice` 实际报告 2/2，通过一次上游 200 Provider 调用并保留原主包。修复后源码对应的 signed 主 HAP 与 ohosTest HAP 随后重新构建并分别通过 `verify-app`、`verify-profile` 和包名匹配：主包 47,064 bytes、SHA-256 `E17AE5BAE6737527CD68782C64FDE5E910380144231FD74F30BC879243A0BB0B`；测试包 3,242,252 bytes、SHA-256 `E6334FB36E6B88221E9774419ACB5EAF4466A202F192DC1FD3467BB1ED23B269`。2026-10-14 经明确授权卸载签名身份不同的旧主包后，两个 signed HAP 均报告安装成功，`LocalAIGatewayDevice` 再次实际报告 `Tests run: 2, Failure: 0, Error: 0, Pass: 2`；桥接只收到 1 次 chat，上游状态 200，网关 usage 增加 1 次成功、42 input、34 output、76 total tokens。finally 已卸载验收 bundle、移除反向转发、停止桥接和网关，按名称与全量清单均确认 `com.harmony.agent` 不存在。signed 设备门已关闭。证据位于 `artifacts/t28-local-ai-gateway-device/20261014-130121-signed-device-acceptance/`、`artifacts/t28-local-ai-gateway-device/20261014-130151/` 和 `artifacts/t28-local-ai-gateway-device/20261013-233440-signed-build-current-source/`。
