> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/BACKEND_GAP_AUDIT.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Harmony Agent 后端缺口审计

更新时间：2026-10-19

本审计以当前源码和本轮实际测试为准。历史文档中的通过记录只作为范围说明，不替代本轮测试。

## 1. 当前可确认的后端能力

| 模块 | 当前状态 | 证据 | 主要缺口 | 优先级 | 处理方式 |
|---|---|---|---|---|---|
| `agent_contracts` | 已实现 | 版本化 Task、Workflow、Policy、Tool、Artifact 与恢复契约 | 发布前仍需全仓回归 | P2 | 集成验收 |
| `agent_core` | 已实现 | DAG、调度、预算、operation journal 与恢复决策 | 发布前仍需全仓回归 | P2 | 集成验收 |
| `agent_runtime` | 已实现核心链路与宿主中立组合合同 | 唯一 `AgentRuntimeFacade`、可中断异步 Planner、授权、checkpoint、恢复、Artifact Registry/Release Runner、`createSingleAgentHostRuntime`；本轮 Runtime 134/134 | 具体 Ability composition root 和生产 policy loader 仍需产品宿主实现 | P0 | 主仓库合同与 fixture 已完成；宿主接线 |
| `agent_connectors` | 已实现主仓库生产适配层 | Local AI Gateway、Provider Planner、MCP adapter、production factory 与只读 AssetStore credential resolver；本轮 Connectors 65/65 | 产品宿主 Asset 预置/轮换及第三方远端 MCP 未验收 | P0 | 外部宿主集成与受控验收 |
| `agent_storage` | 已实现存储核心、Planner 接线与加密配置 | execution recovery、RDB composition、长期记忆 CRUD/检索/迁移、`RuntimeMemoryContextAdapter`、`createEncryptedRdbStoreConfigs` 与预算/隐私/配置测试 | 宿主实际打开加密库、`rekeyEx` 轮换和设备证据未完成 | P0 | 主仓库配置已完成；继续做宿主设备验收 |
| `native_tools` | 部分实现 | permission-free battery read tool 与设备证据 | 尚无由产品 spec 批准的写操作工具 | P1 | 按用户闭环逐项增加，不批量扩权 |
| `mcp_client` | 已实现协议客户端 | JSON-RPC、SSE、分页、超时、取消、多 Server 隔离 | 第三方 server 的协议/auth/断网兼容性未验证 | P1 | 外部兼容性批次 |
| `agent_testkit` / `test_host` | 已实现基础设施 | deterministic fault、benchmark、无页面设备宿主；Runtime 已有组合生命周期主机用例 | 最终真实资源组合尚无签名设备验收 | P0 | 产品宿主接线后增加签名设备用例 |
| `offline/` learned routing | 已冻结研究输入 | MTRouter、MasRouter、HYSET 来源与合同 | 不属于第一版单 Agent 后端交付 | 暂缓 | 保留代码，不继续训练或接入 |

## 2. 最高优先级缺口

### P0-A：单 Agent 产品级组合入口（主仓库合同已完成）

`agent_runtime` 已提供 host-neutral `createSingleAgentHostRuntime`：按 credential store → execution storage → memory storage → MCP client 的固定依赖顺序打开资源，任一步失败都逆序回滚；创建成功后只返回一个 `AgentRuntimeFacade`，关闭时先停止 Facade，再逆序释放资源。配置版本、缺失端口、重复资源身份和非法关闭模式均 fail-closed。主仓库合同与 6 项组合级 fixture 已完成；具体 Ability composition root、RDB/系统密钥/网络对象和签名设备验收仍由产品宿主完成。

### P0-B：长期记忆进入任务流程（主仓库接线已完成）

`agent_runtime` 已声明 `PlanningMemoryContextPort`，`agent_storage` 已用 `RuntimeMemoryContextAdapter` 把可重建索引投影为 owner 绑定、默认排除敏感和原始轨迹、受条目/字符预算约束的 Planner 上下文。Provider Planner 对结果二次校验，并把实际字符数计入输入与费用预检；删除后的索引不可召回。主仓库还提供固定 `encrypt: true`、`persist: true` 的双库配置，但真实进程重开、设备文件加密与 `rekeyEx` 轮换验收仍属于 P0-C。

### P0-C：生产安全外部边界

以下能力需要真实宿主或外部服务，主仓库不能伪造完成：

- 产品宿主写入/轮换 Asset、锁屏可访问策略和签名设备查询证据；最小作用域查询与错误脱敏已由主仓库适配器完成；
- 产品宿主实际打开加密执行/记忆库，以及 `rekeyEx` 轮换、失败恢复和设备证据；
- 第三方远端 MCP 的协议、认证和断网行为；
- 生产 artifact 公钥、撤销与轮换；
- 签名 HAP 和真实设备上的最终组合验收。

## 3. 本轮处理

T63 已补充 storage-neutral 资源型 policy loader：baseline、shadow、canary、active 的 timeout/cancel 会触发底层 `cancel()` 与 `close()`，迟到结果不能改变已完成选择。主仓库 fixture 门完成，生产 process/worker/IPC/network 实现仍属于宿主边界。

P0-B 已补充 storage-neutral 长期记忆上下文合同、Storage 适配器与 Provider Planner 接线。主机测试覆盖 owner/隐私/预算/删除/失败前置拒绝，三个受影响 HAR 已完成 Release 构建。

P0-A 已补充单 Agent 宿主生命周期组合合同。主机测试覆盖固定打开顺序、失败资源回滚、Runtime factory 失败回滚、关闭异常仍释放全部资源、非法配置前置拒绝与幂等关闭；Runtime 133/133，Release HAR 构建通过。

P0-D 已补齐 Runtime → Semantic Planner → Provider 的 task-bound 取消传播。取消和 shutdown 可在 Facade FIFO 外先释放在途 Provider 请求，但任务状态与 checkpoint 仍只在原 FIFO 中改变；错误 taskId 不影响其他请求，调用结束后取消注册会移除。Runtime 134/134、Connectors 60/60，两个 Release HAR 与无签名 test_host HAP 构建通过。

P0-C 的主仓库 RDB 配置门已补齐：`createEncryptedRdbStoreConfigs` 固定加密和持久化，拒绝不安全或重复文件名，不接收 raw key。Storage 57/57，Release HAR 构建通过。实际 `getRdbStore`、文件加密、重开和 `rekeyEx` 轮换仍需产品宿主与签名设备。

P0-C 的主仓库 credential 查询门已补齐：`AssetStoreProviderCredentialPort` 使用显式 provider/scope allowlist，从 API 26 AssetStore 单条查询 secret，只生成 Bearer 或 `x-api-key`，未知 scope 在系统调用前拒绝，字节使用后清零且错误脱敏。Connectors 65/65，Release HAR 构建通过。真实 Asset 写入、轮换、锁屏策略和签名设备查询仍由产品宿主完成。

## 4. 下一批建议

主仓库内部 P0 接线已覆盖宿主生命周期、长期记忆规划上下文、Planner 取消传播、加密 RDB 配置和 AssetStore credential 查询。2026-10-19 已完成全模块回归与交付审计：八个在线模块主机测试合计 365/365，八个 Release HAR 均构建通过，精确证据见 `artifacts/backend-final-regression/20261019/`。

当前剩余项全部位于 P0-C 外部生产边界：产品宿主预置/轮换 Asset、打开加密 RDB 与 `rekeyEx` 轮换、第三方远端 MCP、生产 artifact 公钥和签名设备组合。这些工作需要真实产品 HAP、系统能力、外部服务或生产密钥，不能由主仓库 fixture 代替。取得这些输入后，下一批应只做产品宿主接线和签名设备端到端验收，不再扩展高级路由或多 Agent 算法。
