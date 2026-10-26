> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_PLANNER_CANCELLATION.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Planner 与 Provider 取消传播

更新时间：2026-10-19

## 1. 问题

生产 Facade 使用 FIFO 串行化任务状态、持久化和控制命令。旧实现中的 `cancelTask` 会排在尚未完成的 Planner Promise 后面，同时 `ProviderSemanticPlanner` 为每次调用创建外部无法访问的取消源。结果是用户已经请求取消，模型网络调用仍可能继续耗时和计费。

## 2. 合同

production composition 2.7 要求所有 `SemanticPlannerPort` 实现提供：

```text
interrupt(taskId: string): boolean
```

该方法只能通知在途计算停止，不能创建、取消或改变任务状态。任务状态、事件、checkpoint 和命令去重仍由 `AgentRuntimeFacade` 的原 FIFO 负责。

## 3. 时序

1. Planner 调用开始，Runtime 把当前 task 标记为 planning active。
2. `ProviderSemanticPlanner` 为该调用登记 taskId 与独立 `ProviderCancellationSource`。
3. 用户调用 `cancelTask`，Facade 在进入 FIFO 前校验命令，并调用 Coordinator 的计算中断入口。
4. Coordinator 同时中断协作准备与 Semantic Planner；Provider signal 触发 HTTP/transport 释放。
5. Planner Promise 结束后，Runtime 忽略迟到规划结果，不调用 Tool Adapter。
6. 原 cancel 命令进入 FIFO，任务状态、事件和 checkpoint 正常落为 `CANCELLED`。
7. Provider Promise 的 finally 移除 taskId 与 cancellation source 绑定。

shutdown 使用相同中断路径，先释放仍在规划的计算，再进入 FIFO 完成 Runtime 生命周期关闭。

## 4. 失败与隔离

- 错误 taskId 返回 false，不取消其他任务的 Provider 请求；
- 非取消导致的 Planner Promise 拒绝仍按 `plannerInvocationFailed` 闭合；
- 取消导致的拒绝不会被记录成模型失败，也不会暴露底层异常文本；
- Collaboration Planner 委托同一个底层 Provider Planner，因此多角色规划的当前请求同样可取消，后续角色不会继续调用。

## 5. 已验证范围

2026-10-19：Runtime Hypium 134/134，Connectors 60/60。Runtime 与 Connector Release HAR、无签名 test_host HAP 均构建成功。

本轮未签名、未安装或运行设备，也没有发送真实 Provider 请求。真实 HTTP abort、网关取消和计费停止仍需在受控外部环境中单独验收。
