> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_ARTIFACT_POLICY_LOADER_INTEGRATION.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Agent Artifact Policy Loader 接入说明

状态：T63 主仓库 fixture 门已通过；生产实现仍由宿主提供。

## 1. 目标

`ArtifactPolicyReleaseRunner` 已负责 baseline、shadow、canary、active 的选择、超时与取消。T63 增加资源型 loader 边界，使具体进程、worker、IPC 或网络策略在这些控制信号到达时能够停止底层工作并释放资源。

主仓库不加载生产模型、不保存密钥，也不决定宿主使用进程、worker、IPC 还是网络服务。

## 2. 公共接口

`ArtifactPolicyResourceOperationPort` 表示一次资源型策略调用：

- `result()`：返回策略决策 Promise；
- `cancel()`：中断底层计算、请求或 IPC；
- `close()`：释放订阅、句柄、连接和 worker；
- `cancel()` 与 `close()` 必须幂等。

宿主分别实现：

- `ArtifactBaselinePolicyLoaderPort`；
- `ArtifactReleasedPolicyLoaderPort`。

随后用 `ManagedArtifactBaselinePolicy` 和 `ManagedArtifactReleasedPolicy` 接入现有 `ArtifactPolicyReleaseRunner`。

## 3. 生命周期

1. adapter 先复制 request 和 artifact，loader 不会取得 Runtime 的可变状态。
2. loader 同步创建 operation。若创建失败，loader 必须自行清理创建到一半的资源。
3. adapter 在调用 `result()` 前订阅本次 attempt 的取消信号。
4. 正常完成时调用一次 `close()`，不调用 `cancel()`。
5. timeout、外部取消、底层失败时调用 `cancel()` 和 `close()`。
6. attempt 已结束后到达的迟到 Promise 结果被忽略，不能重新发布决策。
7. `close()` 或取消订阅失败时 adapter fail-closed，不接受该次决策。

## 4. 安全边界

- 凭据由宿主 credential store 在底层实现中按最小作用域解析，不进入 request、artifact、事件或测试报告。
- loader 只能消费已经通过 Artifact Registry 准入的 artifact 副本；manifest 自报字段不能替代验签与撤销检查。
- timeout/cancel 表示停止等待，同时要求底层释放资源；只忽略 Promise 而不停止底层工作不符合接口合同。
- 主仓库 fixture 只证明控制流，不证明生产 worker、IPC、网络服务、密钥信任或模型生命周期已经接入。

## 5. 当前验证

`ManagedArtifactPolicyLoader.test.ets` 使用四类可控 fixture：

- baseline → process timeout；
- shadow → worker timeout；
- canary → IPC cancellation；
- active → network timeout 和迟到结果隔离。

另有成功路径验证 baseline 与 active 均只关闭、不取消资源。本轮 Runtime Hypium 为 127/127，Release HAR 构建通过。
