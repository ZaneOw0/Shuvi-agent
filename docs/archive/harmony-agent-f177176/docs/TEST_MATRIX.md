> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/TEST_MATRIX.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# 验收矩阵

最后更新：2026-10-20。M07 Provider Connector、T30 MCP Facade 与 T36 Provider Planner → Facade → MCP 已完成各自记录的真实设备门；T40 已完成逐角色 Provider 规划的 fake 主机门；T41/T42 TestKit 0.6.0 已完成 schema 2 记录封存及真实执行请求/Token/金额准入门；M08 首个只读 Native Tool 已完成主机、构建与签名 API 26 设备运行门；M09-B/M05-A 已完成 T26 RDB 跨进程设备恢复；T43 已完成真实 12×2 双 arm Provider/system Bench（19/24 质量基线）；T51 已完成 MasRouter 环境输入合同的严格 JSON Schema 校验、离线 checker（13/13）与确定性报告，并于 2026-10-19 通过验收（提交 `1502f212e0c1fd75305476f5de046d1bae72aff5`，作为 T52 基线）；T52 已完成 adaptation handoff 合同、checker（29/29）与 research-only fixture。

| 验收项 | 主机侧证据 | 设备侧状态 |
|---|---|---|
| JSON-RPC 编解码、乱序响应、结构化错误 | ArkTS 单元测试已运行通过 | 不需要设备 |
| SSE 分块、多事件、注释、畸形数据 | ArkTS 单元测试与 Node Fixture 契约已运行通过 | 不需要设备 |
| 超时、取消、响应大小限制 | ArkTS 分类/取消/字节上限测试已运行通过 | 真实 HTTP 场景已编译进 ohosTest HAP，未运行 |
| 分页、重复游标、空目录缓存与显式刷新 | ArkTS 单元测试已运行通过 | 不需要设备 |
| 文本、图片、音频、资源链接、嵌入资源、结构化内容和未知块 | ArkTS 单元测试已运行通过 | 现代 Fixture 调用已准备，未运行 |
| 现代 `2026-07-28`、旧式 `2025-11-25`、auto 协商 | ArkTS 单元测试与 Node Fixture 契约已运行通过 | 现代真实网络测试已编译，未运行 |
| 401、403、5xx、网络和超时不误回退 | ArkTS 单元测试与 Node Fixture 契约已运行通过 | 对应 ohosTest 用例已编译，未运行 |
| 安全查询只在无 HTTP 响应时重试一次；工具调用不重试 | ArkTS 单元测试已运行通过 | 不需要设备 |
| 两个 Server 并发、同名工具引用与单 Server 故障隔离 | ArkTS 管理器测试与 Node Fixture 契约已运行通过 | 不需要设备 |
| 未注册策略或策略异常时拒绝，且不发送 `tools/call` | ArkTS 传输请求计数断言已运行通过 | Fixture 统计验证已编译，未运行 |
| 认证异常分类以及认证值不进入报告/统计 | ArkTS 与 Node Fixture 契约已运行通过 | 不需要设备 |
| Release HAR 不含 Node/stdio 运行时依赖 | Release 构建与 HAR 审计已运行通过 | 不需要设备 |
| 真实设备网络、断开连接、重连与资源释放 | 不可由主机运行替代 | 已编译进 ohosTest HAP，等待设备 |
| 应用后台/前台恢复 | 无主机等价验证 | AbilityDelegator 生命周期往返与恢复后查询已编译进 ohosTest HAP，未运行 |

主机侧最终结果：ArkTS `26/26`，Node Fixture `10/10`，验收阶段 `PASSED=7 FAILED=0 SKIPPED=1 EXIT=0`。

设备阶段被跳过的唯一原因是 HDC 未检测到设备或模拟器。HAP 构建成功不等于安装、签名或运行成功；连接设备后应使用：

```powershell
.\tools\test-mcp.ps1 -Device Required -Protocol Both -AdvertiseHost <设备可访问的本机地址>
```

脚本不会修改防火墙。运行前需要由操作者自行确认设备能访问该地址和临时端口，并提供可安装 HAP 所需的现有签名配置。

## Agent Runtime 主机侧验收

| 模块 | 结果 | 已证明 | 未证明 |
|---|---:|---|---|
| `agent_contracts` | 14/14 | DTO、codec、shape validation | 跨版本生产兼容性 |
| `agent_core` | 21/21 | DAG、Scheduler、Recovery、Budget；完整预算总账原子 hydration | 真实 Planner/Provider/Tool 与设备运行 |
| `agent_runtime` | 68/68 | Policy、Headless Fake、M03 编排、M04 Registry/Router、M09-B Production Facade；异步 Planner/Promise durable gate、同实例 FIFO、启动恢复、authority hydration、event replay、active operation 对账转换、Role Registry 驱动的版本化角色计划/恢复与模式标签式 Multi fail-closed | T40 已在 connector 层实现按计划逐角色 Provider 规划与结果修订；真实 Provider 质量和设备运行未覆盖；T26 已证明签名设备进程退出/重启恢复，T39 本身未运行设备 |
| `agent_storage` | 57/57 | M05-A/M05-B durable recovery；checkpoint/authority、operation/budget、lease/fencing、恢复 checkpoint 单 CAS 发布、Planner 记忆投影与加密双库配置；0.8.0 RDB composition 已通过签名 API 26 跨进程恢复验收 | T26 seed 就绪/PID、force-stop、recover 1/1、Adapter 零重放及卸载核对已通过；新配置的设备文件加密和 `rekeyEx` 尚未证明 |
| `agent_connectors` | 65/65 + bridge 3/3 + signed Provider device 2/2 + signed Planner/Facade/MCP device 1/1 + unsigned MCP device 1/1 | M06/M07、M09-B Facade、T33 Planner、T34/T35 composition、T37/T39 协作接线、T40 逐角色 Provider 规划与 P0-C AssetStore credential resolver；signed `LocalAIGatewayDevice` 2/2、signed `LocalAIGatewayFacadeDevice` 1/1、unsigned `McpFacadeDevice` 1/1 | 产品宿主 Asset 写入/轮换、真实取消/timeout、发布签名下的 MCP 门及第三方远端 MCP 兼容性未覆盖 |
| `native_tools` | 12/12 | API 26 battery descriptor、capability probe、M02 grant 复核、参数/identity fail-closed、后台限制、取消、异常、结果归一化和 M03 dispatch 接线 | 签名 `BatteryStatusDevice` 1/1，完成安装、真实系统读取、卸载与 bundle 不存在核对；需要权限的 Kit 尚未选定 |
| `agent_testkit` | 29/29 | 十二类确定性故障决策、十个共用 fixtures、benchmark pinning、公平 arm 校验、十二种 pilot task、32/128/512 工具规模校验、schema 2 逐 Agent 证据与完整封存；0.6.0 执行前检要求活动 Profile/revision、上游模型/价格、显式授权和 39 请求/4096-8192 Token/US$0.43134 封顶 | recorder/validator/preflight 不执行 workload；revision 13 已有 active/complete Profile，但 Runtime 未启动且本轮批量执行未授权，真实 Provider/system Bench、真实性能与设备行为尚未执行 |

M03 用例覆盖提交去重与冻结时间语义、validated workflow dispatch、澄清与授权分离、内部 grant 后才允许工具 dispatch、暂停/恢复、未知副作用对账、取消后延迟对账、迟到 completion 拒绝、单调 sequence/version，以及 partial replan 保护成功和未知结果。该结果来自 `agent_runtime@default test` 的主机侧 Hypium 运行；HAR 构建不等于 HAP、安装或设备验收。

M04 用例覆盖 Registry 顺序/复制隔离/同版本冲突、模型与工具 hard eligibility 先于 learned policy、learned 关闭和低置信度回退、确定性 tie-break、无 embedding 工具路由、累计工具成本、description/retrieval version 分离、Context token 预算、未验证依赖排除、single-first 与独立能力 multi 门。该结果同样只来自主机侧 Hypium；未加载真实 checkpoint 或 embedding。

M09-B 新增 8 项用例覆盖：状态 snapshot 的顺序持久化、dispatch 前持久化准备、持久化拒绝时不调用 Adapter、Policy Gateway 后才进行 Tool dispatch、同步 Adapter completion 延迟到 dispatch 登记完成、task/step/dispatch/invocation 回调绑定、控制命令重放、澄清、未知结果对账、事件回放、订阅释放与 shutdown。结果来自主机侧 Hypium 和 Release HAR 构建；fixture persistence/adapter 不等于异步 durable RDB、真实 Provider/Tool、跨进程恢复、签名 HAP、安装或设备运行。

0.5.1 在同一 52 项套件中增加断言：非 NONE 幂等模式缺少 key 时 dispatch 前拒绝；Tool 写前上下文包含 dispatch/operation/budget/provider 绑定；`beforeDispatch` 只取得不含任务正文、参数 JSON 或授权凭证的上下文副本；持久化实现与 Adapter 修改各自副本都不会污染 Runtime 保留的请求。同步 `ProductionRuntimePersistencePort` 与 Promise/CAS `DurableExecutionRecoveryStore` 的宿主 bridge 仍未实现，映射与时序见 `docs/AGENT_RUNTIME_STORAGE_INTEGRATION.md`。

0.6.0 在同一套件中继续验证 `RuntimeTaskRecoveryCheckpoint` 1.0：等待授权状态保留 workflow/scheduler/policy request/event sequence；pending dispatch/operation 与 active invocation 在任何 Adapter 调用前先保存；完成后清除在途字段；返回对象与生产 persistence fixture 均按副本隔离。`saveCheckpoint`/`loadCheckpoint` 已替换摘要级保存端口，但检查点校验、Policy/Budget durable hydration、协调器重建和跨进程运行尚未实现。

0.6.1 在同一 52 项套件中加入 `RuntimeCheckpointValidator` 断言：Runtime 生成的等待授权与在途 checkpoint 必须通过版本、公共契约、身份绑定、事件序列、workflow/scheduler 和 pending state 校验；伪造 snapshot taskId 的对象必须失败。生产 Facade 在保存前和 `loadCheckpoint` 回读后执行校验，并对请求 taskId 重新绑定；无效持久化数据以 `PERSISTENCE_FAILURE` fail-closed。该结果仍是主机 gate，不等于协调器重建、异步 durable bridge 或跨进程恢复。

0.7.0 的 53 项套件继续验证 checkpoint 1.1 和协调器重建：原始 submission 保证重启后的 requestId 精确去重；1.0 格式拒绝；等待授权状态在新协调器中恢复但保持 authority lock；在途无副作用步骤不调用 Adapter 并回到待重试状态；在途副作用步骤进入等待对账；旧 completion、授权、推进、控制和 FAILED replan 在 durable Policy/Budget hydration 前统一返回 `RECOVERY_AUTHORITY_REQUIRED`；重复 Policy request 冲突在提交 Session/预算状态前拒绝，随后使用干净检查点仍可恢复。该门没有把恢复接入生产 Facade 或 Promise/CAS RDB，仍不等于跨进程验收。

0.8.0 的 54 项 runtime 套件新增 authority hydration 场景：错 checkpoint snapshot version 与错 operation-policy 绑定都拒绝并保持锁；完整 budget scopes/reservations、等待中的 version 1 policy request 或在途 version 3 decision/grant/operation 全部匹配后才解锁；恢复的带副作用任务只接受对账，期间 Adapter 调用数保持 0。T19 由 storage 39 项中的 M05-A 26 项验证 schema 1.2 opaque checkpoint、任务枚举和 checkpoint/authority 单 CAS。T20 将 runtime 增至 55 项：Facade、persistence port 与 completion sink 均 Promise 化，dispatch 的最终 checkpoint 与 authority 共用异步 `beforeDispatch` 提交门；人为挂起该 Promise 时 Adapter 保持 0 调用，释放后才 dispatch。T21 将 runtime 增至 57 项：第二个重叠提交在前一个 durable gate 完成前保持未完成且 Adapter 为 0 调用；前一个命令契约拒绝后，后续有效提交仍能执行。

T22–T24 将 runtime 增至 59 项、storage 增至 45 项，完成生产 persistence bridge、durable authority 回读、任务枚举、启动恢复、event/policy replay，以及无在途 operation 的 backend reopen → recovered Facade → 继续授权链路。T25 将 runtime 增至 60/60、storage 增至 47/47：活动调用在启动时转入 `WAITING_RECONCILIATION`，bridge 在一次 backend CAS 中接管 fencing、把 operation/budget 归一化为 `UNKNOWN_OUTCOME`、释放恢复 lease 并保存下一版本 checkpoint；CAS 冲突和绑定不一致均 fail-closed，Adapter 调用保持为 0。T26 新增 `createRdbRecoveredAgentRuntime` 与 seed/recover 两阶段 fixture；签名 API 26 设备验收确认 seed 就绪时 PID 存活、force-stop 后 PID 消失、新进程 recover 1/1、Adapter 零重放、UNKNOWN operation/budget、lease 释放以及最终卸载清理，T26 已关闭。

T32 将 runtime 增至 63/63：`SemanticPlannerPort` 的 plan/resume/replan 统一 Promise 化；测试人为挂起 plan 时 Facade 提交保持未完成且 Adapter 调用为 0，释放后才推进；plan、clarification resume 与 replan 的 Promise 拒绝都以稳定失败码闭合，公共 snapshot/event 不包含底层异常文本。该证据来自无签名主机 Previewer/Hypium 与 Release HAR，不等于真实语义 Planner、Provider 请求、HAP 或设备运行。

T33 将 connector 增至 44/44：`ProviderSemanticPlanner` 实现异步 `SemanticPlannerPort`，以冻结的 Provider/model/version/region/price 生成结构化请求，在调用前执行 privacy、输入/输出 token、金额与 prompt 大小预检；模型输出必须解析为互斥的 ready/clarification/rejected 状态，typed workflow 还需通过字段、拓扑、DAG、副作用/幂等与 Tool capability 校验。Runtime 时钟和 ID port 决定 workflow/clarification 身份，trace 不含 prompt/output 正文。无签名隔离 Release HAR 为 99,486 bytes、SHA-256 `6330B38ADC471A67697BFF2643BB3829A8C5CE6E06682E4DFBAC876236D1CCB9`。本门使用 fake Provider，未运行真实 Provider、HAP 或设备，也未完成生产 composition 和 S6 system run。

T36 已以 signed 主/ohosTest HAP 在 API 26 运行 `LocalAIGatewayFacadeDevice` 1/1：真实上游 Provider 返回一个合法 Tool workflow，唯一 `AgentRuntimeFacade` 先进入 `WAITING_AUTHORIZATION`，显式测试授权后经真实 MCP HTTP fixture 执行一次 `echo` 并完成。桥接只记录 1 次上游 200 和脱敏结构/usage 摘要，不记录 credential、请求或响应正文。finally 已卸载 `com.harmony.agent`、移除两个反向映射并停止 bridge、fixture 与网关；按名称及全量 bundle 清单和 HDC 映射复核均通过。证据位于 `artifacts/t36-local-ai-gateway-facade-device/20261015-231255-8192-token-signed-build/` 与 `20261015-231641-device/`。该单任务证据不替代生产 credential store、真实取消/timeout 或 S6 12×2 Bench。

T37 将 connector 主机套件增至 52/52、runtime 增至 64/64。显式 Multi `CollaborationSelectorPort` 可穿过具体 Provider/MCP composition；缺失时仍使用 Strong Single。`maxAgentActivations=1` 的 Multi 请求会在 planner、credential、Provider 网络和 MCP 前失败，并产生 validator-valid 的终态恢复检查点。Release HAR 为 58,288 bytes、SHA-256 `BAFCEE611C9349B570E30B6FF57BA365AA59E77953B57D15BF5EDEC26F5F7073`。本门没有真实 Provider、HAP、签名或设备证据，不关闭 S6。

T39 将 runtime 增至 68/68，connector 保持 52/52。Runtime 0.14.0/composition 2.5 新增 schema 1.0 `CollaborationPlan` 和严格 validator；计划携带 task/mode、完整 Role Registry/decision SHA-256 摘要与互异 role identity，并作为 Planner 请求及 checkpoint 1.1 的深拷贝状态参与恢复。确定性 Collaboration Router 使用宿主 digest port 从 active Role Registry 选择并固化角色；旧 Single checkpoint 继续兼容，模式标签式 Multi、角色重复、非法摘要或预算越界会在 Planner/credential/network/MCP 前失败。Release Runtime HAR 为 100,808 bytes、SHA-256 `678998BFCC96C6FDA7E8109DF3C4B246C9B74ED717FF898AAA3C5D38A4C8CC1E`；包内版本 0.14.0、`debug=false`、compatible SDK 26。该门没有真实 Provider、HAP 或设备证据，不关闭 S6。

T50/M13-A 是纯离线 MasRouter 来源与复现准入门：Node checker 确定性校验官方 commit/tree、archive/license/paper 与 15 个关键文件摘要，分离论文和源码协议，并固定 `CollaborationPlanSelectorPort`、Role Registry、Single fallback、Multi 预算预留及唯一 `AgentRuntimeFacade` 边界。按精简测试策略只保留四个高价值用例，结果为 4/4；没有运行 ArkTS/Hypium、HAR/HAP、设备、训练、Provider 或 benchmark。上游依赖清单/checkpoint 缺失、入口大小写和价格元数据冲突保持显式 fail-closed。

T51/M13-B 是纯离线环境、数据与价格输入合同门：四份 JSON Schema 和六份输入文档覆盖 34 个依赖候选、五个数据集、论文/源码模型池及 Claude 价格冲突；`check-masrouter-inputs.mjs` 以本地严格 JSON Schema 校验四份输入文档，未知顶层/嵌套字段、类型错误和必填缺失均 fail-closed，并确定性生成报告 `sha256:0f4367d6de077b0a6df712ff41d1e45af3681e7338f13cbe9973e8ee73440fa3`；`test-masrouter-inputs.mjs` 以 13/13 覆盖 Schema 违规、未解析依赖冒充 locked、数据集缺 digest、模型池合并、模型 revision 漂移、价格冲突被静默解决、执行声明漂移和必需问题缺失。测试与临时目录均限制在 `D:\Harmony_agent` 内。没有下载数据集、安装依赖、读取凭据、调用 Provider、训练、运行 benchmark、ArkTS/Hypium、HAR/HAP 或设备；所有版本、digest、revision 和官方价格仍为 unresolved。

T52/M13-C 是纯离线 adaptation handoff 结构准入门：`check-masrouter-handoff.mjs` 校验 `HANDOFF.json`、`SHA256SUMS`、逐文件摘要、路径穿越/符号链接、未列文件、Role/Model Registry 边界、single/multi 有序分配、advisory-only 模型、feature envelope、source digest、任务控制字段和同步网络声明；`test-masrouter-handoff.mjs` 以 29/29 覆盖 4 个正向（adaptation、single、official reproduction）和 25 个负向场景。`fixtures/research-only-handoff/` 是 synthetic fixture，不是 checkpoint、论文复现或可部署策略。发布边界继续复用 M11 ArtifactManifest/Registry/release runner；没有安装依赖、下载数据/模型、读取凭据、调用 Provider、训练、运行 benchmark、ArkTS/Hypium、HAR/HAP 或设备。

T40 将 connector 增至 55/55。`CollaborativeProviderSemanticPlanner` 对计划内每个角色发起独立 Provider 请求，首角色生成 workflow，后续角色走已有 replan validator 修订前序 typed workflow；trace 记录唯一 activation/request、role identity、decision digest 与 usage。计划外角色、无计划 Multi，以及按激活数累计后的 token/cost/Agent 预算越界均在 credential/network 前 fail-closed。具体 Local AI Gateway composition 的两角色用例实际观察到 2 次 credential 解析与 2 次 HTTP 请求，并在第二角色完成后进入同一 Facade 的授权等待。Release HAR 为 61,831 bytes、SHA-256 `120A65A82BA87CB7A79C948C1963A2070CA2E678ABC8F54134156A94BA10A540`，包内版本 0.8.0、`debug=false`、compatible SDK 26。该门只使用 fake Provider/HTTP/MCP fixture，没有 HAP、签名、设备或真实 Provider 证据，不关闭 S6。

T41 将 TestKit 增至 26/26。`SystemBenchmarkRunRecorder` 不持有 Runtime、Provider、Tool、授权或任务控制 port，只接收独立 harness 已产生的脱敏记录；未知 case、重复 case/arm、跨 execution、重复 task 和 schema 2 单记录失败均在追加前拒绝。完整 24 条记录通过既有 validator 后才返回防御性封存副本。无签名隔离脚本可重复完成测试与 Release HAR 构建，不修改根签名配置。Release HAR 为 33,038 bytes、SHA-256 `EB01D259349A40BCC94823DCEB44E817F3294ECA186792337207387A83B713FB`，包内版本 0.5.0、`debug=false`、compatible SDK 26。本门没有真实 Provider 请求或运行 12×2 workload，不关闭 S6。

T42 将 TestKit 增至 29/29，并新增无任务控制权的 `SystemBenchmarkExecutionPreflightValidator`。它把 24 条记录、最多一轮澄清、Strong Single 13 次/Multi 26 次/总计 39 次 Provider 请求、每请求 4096 input/8192 output tokens，以及 DeepSeek Flash 官方峰时缓存未命中价格下 431,340 USD micros（US$0.43134）的最坏费用绑定成 fail-closed envelope；活动网关 Profile/revision/digest、公开 alias、上游模型版本、价格 digest 或显式批量授权缺失/漂移时均不准入。候选 Node envelope 检查通过；Release HAR 为 38,322 bytes、SHA-256 `B760ADF2FA71DF73055EA0DC6E3E11AA12C5B6EA19BC7EAB13CD3D6C023A0D09`，版本 0.6.0、`debug=false`、compatible SDK 26。2026-10-17 在实际当前用户上下文只读复核到有效 revision 13、active/complete 的 `deepseek` Profile、`official` → `https://api.deepseek.com`、`aigw/default` → `deepseek-flash`，配置 SHA-256 为 `3E3FE8EE7F9E170C809E263B3191A28426C8DC9E41538AA27B820D5442DA9E95`；Runtime 当前停止。普通沙箱进程读到的 revision 0/空列表属于隔离视图。本门没有启动网关、读取凭据或发送 Provider 请求；本轮批量执行尚未授权，S6 仍开放。

M05-A 主机用例覆盖 task CAS/copy、opaque Runtime checkpoint 与任务枚举、checkpoint/authority 单 CAS 发布、operation/reservation/完整 budget scope 图原子 prepare、version 3 Policy/Grant 绑定、全部 reservation 与 scope 防御性读取、稳定 ID 冲突、lease/fencing、三类崩溃语义、UNKNOWN 对账、实际预算/receipt 和 scope 聚合结算、trace retention、schema/migration/corruption，以及 durable CAS 失败不发布、两个 session 单胜者和 reopen 前未知状态固化。

M05-B 当前 13 项主机用例覆盖：类型化记录的 digest 与显式版本、复制隔离、确定性分块/词法索引与 owner 隔离、敏感记忆和原始个人轨迹默认不检索、批量导入原子拒绝、导出默认仅 `SHAREABLE` 且标题/正文/标签脱敏、更新与删除级联失效、stale artifact 拒绝，以及 durable CAS 失败不发布、并发 session 单胜者、重开恢复并重建索引、损坏 fail-closed 和显式 schema migration。`RdbMemorySnapshotBackend` 已通过 API 26 类型检查；当前命名签名包的设备验收已证明 close/reopen、索引重建、真实 RDB 损坏注入和 stale session CAS 竞争，宿主加密配置仍未证明。

M05-B 的 `MemoryDeviceRecovery` 当前命名签名主 HAP 与 ohosTest HAP 已在 API 26 实际运行 3/3，通过签名验证、安装、RDB close/reopen/索引重建、stale session CAS 单胜者、损坏 fail-closed 和最终卸载检查。证据位于 `artifacts/t08-signed-device-acceptance/20261002-195000/`。

T28 Local AI Gateway 的主机协议 fixture 5/5、合并 connector 套件 33/33 与 Release HAR 已通过。前三次旧配置 Windows smoke 的 404/404/403 和 EFS `aigw_config_io` 继续作为历史诊断；网关更新并切换官方 DeepSeek 后，严格主机复验取得固定内容完全匹配、`finish_reason=stop`，只产生 1 次成功请求，usage 增加 42 input、33 output、75 total tokens。API 26 参数键兼容修复后，unsigned 保留主包模式的 `LocalAIGatewayDevice` 已通过 2/2。2026-10-14 经明确授权卸载签名身份不同的旧主包后，已离线验签的 signed 主/ohosTest HAP 均安装成功，`LocalAIGatewayDevice` 再次报告 `Tests run: 2, Failure: 0, Error: 0, Pass: 2`；桥接只收到 1 次 chat，上游 200，usage 增加 42 input、34 output、76 total tokens。finally 已卸载 bundle、移除转发并停止桥接和网关，包名查询与全量清单均确认不存在。signed 设备门已关闭。网关配置写入的 `IOException` 回退缺口仍未修复；真实取消/timeout、生产 credential store、S2 与 S6 仍待后续。

T29 新增 5 项 MCP Production Facade composition 主机用例，合并 connector 套件增至 38/38。覆盖 catalog 先绑定、固定 Strong Single、Facade 提交与授权、一次 MCP 调用、异步 completion、恢复型 Facade，以及空 catalog、部分 Server 失败和非空 Registry 的暴露前 fail-closed。Release HAR 为 44,144 bytes、SHA-256 `A23F3E200F7ED11F8E1F6AE3CA235484927E3965D59D7AACD70DAEC61A05B701`。本轮没有签名、安装、设备运行或真实 MCP 网络，因此 S2 仍需真实只读 MCP Server 任务闭环。

P0-A 将 Runtime 主机套件增至 133/133。新增 6 项 `SingleAgentHostRuntime` 用例覆盖 credential → execution storage → memory storage → MCP 的固定打开顺序、Runtime shutdown 后逆序关闭、失败资源与已打开资源的逆序回滚、Runtime factory 失败回滚、关闭异常仍尝试释放所有资源、配置版本/缺失端口/重复资源身份前置拒绝，以及 shutdown 幂等。Release HAR 为 240,587 bytes、SHA-256 `F55724AD0AA37D21B19BE21930BC91F69BA425AAEBCCE8D35BD1A739BFED56D5`。本门只验证 host-neutral 生命周期合同，未构建 HAP、未签名、未运行设备，也不证明具体 Ability、RDB、系统密钥、生产凭据或第三方 MCP 网络对象已经接入。

P0-D 将 Runtime 主机套件增至 134/134、Connector 套件增至 60/60。Runtime 用例挂起 Planner 后调用 `cancelTask`，验证中断先到达 Planner、Adapter 调用保持 0，随后队列内任务状态落为 `CANCELLED`；Connector 用例验证错误 taskId 不触发取消、正确 taskId 触发 `ProviderCancellationSignalPort`、Promise 结束后注册移除。Release Runtime HAR 为 242,331 bytes、SHA-256 `3B4071D26A30F26404238876286BEFC7F67497B333DA0B0E59C033AD62ACD6C6`；Connector HAR 为 115,076 bytes、SHA-256 `031A330D377878A6B6A7425158931088AA4C08A9C4EDBCC063A861F999596741`。无签名 test_host HAP 构建通过。本门没有签名、安装、设备运行或真实 Provider 请求。

T30 `McpFacadeDevice` 已编译进当前源码的 unsigned ohosTest HAP，并在 API 26 实际运行 1/1。它使用生产 Facade composition、显式授权与真实 `McpClientManager` HTTP transport 调用本轮独占 fixture `echo`，通过 `fixture://stats` 断言 Tool 调用恰好增加 1；设备报告 `Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0`、result code 0。主/ohosTest HAP 均安装成功，finally 移除 HDC 转发、停止 fixture 并卸载 bundle；脚本与独立复核均确认包不存在且映射为空。T30/S2 的受控只读 MCP Facade 设备闭环已关闭。该证据仍是 unsigned 测试包及确定性本机 fixture，不覆盖发布签名、生产 Planner/credential store 或第三方远端 MCP。证据位于 `artifacts/t30-s2-mcp-facade-device/20261014-132524/`。

T31 将 TestKit 升级为 0.3.0，新增真实 System Bench 证据合同并把主机套件增至 20/20。验证器要求固定完整 Git source SHA、runtime/composition/harness、SDK/OS/device、真实单调时钟、Provider/model/region/价格，严格覆盖十二种 case × Strong Single/Multi 两个 arm，并为每个样本记录 Facade、Provider usage、延迟、token、Agent 激活数和五类脱敏 digest。无签名隔离工程 Release HAR 为 27,670 bytes、SHA-256 `D4C84E50A0105CFF58EBF01A642E1C06B862A2B3C729F43736420A095E234947`。本门没有运行真实 Provider/system workload、构建 HAP或操作设备，因此 S6 仍未关闭。证据位于 `artifacts/t31-s6-system-bench-evidence-gate/20261014-202326/`。

M08 首个工具是 permission-free 的只读 battery status：主机 contract test 12/12；Release HAR 和 API 26 主/ohosTest HAP 构建通过。签名包已在 API 26 模拟器完成验证与安装，真实 `SystemNativeCapabilityProbe` 与 `SystemBatteryStatusPort` 的 `BatteryStatusDevice` 运行 1/1 通过，随后卸载并确认 bundle 不存在。该证据关闭首个 battery slice 的设备门，但不满足未来 permission-required Native Kit 的拒绝/允许完成标准，也不证明写能力。

设备侧 `StorageDeviceRecovery` 的 7 项测试覆盖：HAR 加载；PREPARED/budget close-reopen；调用中退出；已收到结果但提交前退出；已提交 receipt/实际预算；两个 stale session 竞争 lease/CAS；摘要损坏 fail-closed。2026-10-01 在 API 26 模拟器 `127.0.0.1:5555` 上实际报告 `Tests run: 7, Failure: 0, Error: 0, Pass: 7`。签名主 HAP 与 ohosTest HAP 均安装成功，测试 bundle 随后卸载并验证不存在；证据目录为 `artifacts/t07-device-acceptance/20261001-211416/`。因此 T07/M05-A 已通过本地实现与设备验收门，但尚不等于生产 Facade、具体写 adapter 或发布交接已经完成。

T52 审核修复增加非法/非对象/错误版本/未知字段 feature schema、超限 manifest、超限 checksum、含元数据的聚合超限与完整字节统计验证。精确字节 fixture 使用 .gitattributes 禁用文本转换。详见 `artifacts/t52-review-fix/20261019/`；未运行 ArkTS/HAR/HAP 或设备测试。

2026-10-19 T53（M13-D）本地实现与主机门完成，待人工审核：按已批准 ADR-016 接入可选异步准备端口及 M11 release runner，默认关闭 learned；候选校验、Single 回退、总时限/取消、迟到隔离、完整激活占用及一次重判上限已实现。composition 升至 2.6、checkpoint 升至 1.2，旧 Single 仅 baseline 恢复，旧 MULTI 和准备中恢复按约定拒绝。Runtime Hypium 122/122（新增 26 项）、connectors 55/55、storage 50/50，三个 Release HAR 均构建通过。证据：`artifacts/t53-collaboration-policy/20261019/`；接入与限制见 [T53 接入与验收](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/docs/architecture/T53-%E5%8D%8F%E4%BD%9C%E7%AD%96%E7%95%A5%E6%8E%A5%E5%85%A5%E4%B8%8E%E9%AA%8C%E6%94%B6.md)。仅 fake 控制流，无真实 loader/模型/网络/训练/签名/设备，T54 继续暂停，S9 未关闭。

2026-10-19 T63（M11-F）新增 5 项 `T63ManagedArtifactPolicyLoader` 主机用例，Runtime 总计 127/127。baseline/process timeout、shadow/worker timeout、canary/IPC cancel、active/network timeout 与迟到结果隔离均验证底层 `cancel()`/`close()`；成功 baseline/active 验证只关闭资源。Release HAR 构建通过，大小 133,715 bytes，SHA-256 `24C02644318BFC3CC76AB3A0353D9918575942A9F0CACCF432866AD29375BDD8`。本门没有 HAP、签名、设备、真实 worker/IPC/网络、生产密钥或模型调用，只关闭主仓库 fixture 门。

2026-10-19 T56（M14-A）离线来源门：`check-hyset-repro.mjs --write/--check` 两次得到同一报告 SHA-256 `9a5fb008201cc129ebf8f2ff72d56fc7b57eb94b7cd149c15cc4b6624635f9f3`；`test-hyset-preflight.mjs` 11/11 通过，覆盖 commit、归档、论文版本、关键文件、checkpoint 声明、external 存储方式、架构边界、论文目标、零执行声明和未知字段漂移。检查只读取已固定 lock/spec，不访问网络，不安装依赖，不下载 checkpoint/encoder/原始数据，不读取凭据，不运行 Python、模型、训练、benchmark、ArkTS、HAR/HAP 或设备测试。

2026-10-19 P0-B（M05-C）长期记忆规划接线：Runtime 127/127、Storage 54/54、Connectors 59/59，失败和错误均为 0；三个 Release HAR 构建通过。新增 Storage 4 项覆盖 owner 隔离、敏感/原始轨迹排除、条目与字符预算、删除后不可召回和非法请求拒绝；新增 Connector 4 项覆盖 prompt 注入、trace 不含正文、port 异常/owner 错绑网络前拒绝、输入预算计费和配置成对约束。HAR：Runtime 134,743 bytes / `C628FD17DC02A2B1FA222833480068BE5A1D9C084EFF052D50996496205B8EAD`；Storage 74,087 bytes / `2856099DD9289BD373681290C8B5D1AFDD1324051429B4E4C13EEE9EDB414855`；Connectors 63,792 bytes / `354B5F352C42F2C5CA1AC007A199BEBBFB334B1BF3AA868A2657C10D1E4FD2D7`。本门未运行 HAP、签名、设备或真实 Provider，且不证明宿主 RDB 加密与密钥轮换。

2026-10-19 单 Agent 后端全量回归：Contracts 21/21、Core 21/21、Runtime 134/134、Storage 57/57、Connectors 65/65、MCP Client 26/26、Native Tools 12/12、TestKit 29/29，合计 365/365，Failure 0、Error 0。八个模块的 Release HAR 均构建成功；大小、SHA-256 和原始 `test_result.txt` 见 `artifacts/backend-final-regression/20261019/`。构建仅验证 HAR 编译与打包；没有读取凭据、调用真实 Provider、签名、安装或运行设备，也不能替代产品宿主 Asset 预置/轮换、加密 RDB 的设备文件/`rekeyEx` 轮换、第三方 MCP 与最终组合验收。

P0-C 加密 RDB 配置新增 3 项 Storage 用例：验证 execution/memory 配置固定 `encrypt: true`、`persist: true`，文件名隔离与路径拒绝，以及两个返回配置对象相互独立；Storage 总计 57/57。更新后的 Release HAR 为 75,957 bytes、SHA-256 `9C74AEFA0B2030B62E4471475EB88A76CA107CEE51FB723AA0908E0795A32872`。该证据没有调用 `getRdbStore`，不证明设备上的数据库文件已经加密或轮换成功。

P0-C AssetStore credential resolver 新增 5 项 Connector 用例：验证 Bearer 与 `x-api-key`、精确 provider/scope、未知 scope 系统调用前拒绝、重复绑定/alias 拒绝、畸形 secret、字节清零与错误脱敏；Connectors 总计 65/65。更新后的 Release HAR 为 67,249 bytes、SHA-256 `176DE3443BB09836D6B6B2433237127599E17441CD11F7061A1D72622C5F9F5E`。该证据没有写入或读取真实 Asset，不证明签名设备上的预置、轮换或锁屏策略。

2026-10-20 Shuvi 搜索 MCP 结构化工具错误投影新增 2 项 Connector 用例，覆盖约定的 11 个错误码到稳定状态/分类/错误码/本地消息的映射，以及缺失结构、数组、未知错误码、错误版本、空 requestId 和空 message 的 fail-closed；服务端原始 message 不进入结果，失败不产生 `resultJson`。Connectors 总计 67/67，Failure 0、Error 0；Release HAR 为 68,329 bytes、SHA-256 `563D1A63C4EC3F1F9FF78A6EB8F46C40B85C27133BADF9B5F46C22E234211C27`。HTML coverage 报告生成器有 worktree 路径拼接警告，但原始 `test_result.txt` 和 coverage 日志完整记录执行与通过结果。本门只验证主仓库 adapter/fixture，不证明真实 Shuvi 搜索服务协议、网络、HAP/设备、来源/请求关联或引用回答闭环。

2026-10-20 Shuvi 搜索 MCP 客户端接入新增固定 Legacy Profile/只读 allowlist、输入与成功结果严格校验、凭据桥、显式只读会话过期重握手和按 dispatch 的单次 HTTP 取消。实测 MCP Client 28/28、Connectors 72/72、Runtime 134/134、Storage 57/57、Native Tools 12/12，Failure 0、Error 0；test_host unsigned HAP 构建通过。当前 HDC 目标为空，因此未安装、未运行设备套件、未建立 HDC reverse，也未再次请求 Tavily；这仍不是第三方服务设备验收完成证据。
