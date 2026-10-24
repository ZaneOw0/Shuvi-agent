# @harmony_agent/agent-testkit

`@harmony_agent/agent-testkit` 0.6.0 是 M10 的纯 ArkTS 测试支持 HAR。它让各模块在没有产品页面或产品 Entry HAP 的情况下使用同一套确定性故障、集成场景和 benchmark 统计契约。

## 当前交付

- `DeterministicFaultInjector`：按 target、phase 和 occurrence 精确返回故障决策，覆盖网络断开、timeout、429/5xx、认证失败、权限拒绝、schema drift、重复响应、应用重启、预算耗尽、低质量输出和不可逆调用未知结果。
- `IntegrationFixtureCatalog`：固化架构文档中的 10 个共用集成场景及最低不变量。
- `BenchmarkManifestValidator`：要求固定 model、provider、region、价格快照、contract schema、dataset、router policy 和日期。
- `BenchmarkEvaluator`：拒绝未知 arm、非法计量和重复样本，并导出质量、token、成本、p50/p95、工具、Agent、恢复和 Router 指标。
- `HarmonyAgentBenchPilotCatalog`：固化十二种 pilot task 和 32/128/512 三档 Tool Registry fixture，并对缺失、重复或越界数据 fail-closed。
- `SystemBenchmarkRunValidator`：真实 System Bench 的 schema 2 证据门，要求 12×2 case/arm 完整覆盖、真实 Provider/model/价格身份、单调系统时钟、完整 Git SHA、环境摘要，以及每个样本对应的 Facade、snapshot/event、Provider usage、结果和质量证据摘要。
- `SystemBenchmarkRunRecorder`：追加并防御性复制独立 harness 已产生的脱敏记录；未知 case、重复 case/arm、跨 execution、重复 task 或 schema 2 单记录失败会在进入集合前拒绝，只有完整 12×2 run 通过 validator 后才返回封存副本。
- `SystemBenchmarkExecutionPreflightValidator`：在真实 workload 前绑定公开 Provider/上游模型/价格身份、活动网关 Profile/revision/digest、显式批量授权、12×2 记录数、最多一轮澄清、每请求 Token 上限、Provider 请求上限和金额上限；只返回准入结果，不启动网关或提交任务。
- Multi arm 必须为每次 Agent 激活记录唯一 activation/role 身份、正数 Provider 请求数、互不重复的请求与轨迹摘要；汇总请求数必须等于逐 Agent 总和。Strong Single 必须只有一条 Agent 证据。
- 每个样本还必须固定 Role Registry 与 Collaboration decision 摘要，并覆盖该 benchmark case 声明的全部 expected evidence kind。旧的 System Benchmark schema 1 明确拒绝。
- Strong Single Agent 与 Multi Agent 比较必须使用相同 permission policy 和 context policy。

`offline/harmony_agent_bench` 保存冻结的数据集、零成本 fixture 价格快照、双 arm manifest、真实执行候选价格/费用封顶和无第三方依赖的 Node 检查器。运行 `node offline/harmony_agent_bench/run-fixture-baseline.mjs --check` 可核对 fixture 报告未漂移；运行 `node offline/harmony_agent_bench/check-system-execution-envelope.mjs --check` 可核对候选执行封顶。后者不会启动执行或代表已获授权。

## 集成边界

TestKit 不提交、控制或恢复任务，不签发授权，也不调用 Tool、Provider、Storage 或系统 Kit。宿主仍必须只通过 `AgentRuntimeFacade` 控制任务。Adapter 测试代码读取 `FaultDecision` 后，在自身边界注入对应故障；TestKit 不把 fake 行为伪装成生产能力。

当前报告是确定性 fixture baseline，使用虚拟零时钟且明确标记 `performanceComparable=false`。它不代表 harmony_agent Bench Pilot 已完成真实 model/provider 或系统链路对比，也不提供产品 UI、产品 HAP、设备能力或签名验收。

`SystemBenchmarkRunValidator`、`SystemBenchmarkRunRecorder` 与执行前检均不提交或控制任务。真实 harness 必须继续通过唯一的 `AgentRuntimeFacade` 运行任务。T40 已具备按计划产生独立角色/Provider 轨迹的编排前提；0.6.0 又补齐 39 次请求、每请求 4096/8192 Token 和峰时缓存未命中 US$0.43134 的 fail-closed 封顶。当前 revision 13 配置已有 active/complete 的 `deepseek` Profile，但 Runtime 未启动，也没有本轮批量执行授权或真实 12×2 workload，不能据此关闭 S6。

## 验证

根签名工程不注册 TestKit 模块。使用无签名隔离脚本复验，输出只写入 `artifacts/`，不安装依赖，也不改根 `build-profile.json5`：

```powershell
.\tools\test-agent-testkit.ps1 -BuildRelease
```
