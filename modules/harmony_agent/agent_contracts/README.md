# @harmony_agent/agent-contracts

`@harmony_agent/agent-contracts` 是 harmony_agent Agent Runtime 的纯 ArkTS 契约 HAR。它只定义版本化数据边界、wire enum、JSON codec 和不涉及业务语义的 shape validation。

## Wire 规则

- `schemaVersion` 当前为 `1`，未知版本默认拒绝。
- 时间使用 ISO-8601 字符串；duration 使用 `*Ms`。
- 金额使用整数 `*Micros`，禁止浮点货币。
- token、次数和金额微单位必须是非负整数。
- 任意动态 payload 使用 `*Json` 字符串，并通过独立 schema/digest 绑定。
- ID、digest 和 version 使用字符串；调用方负责生成，不由本 HAR 猜测。
- 未知 JSON 字段对旧 reader 保持兼容；缺失必填字段由 `ContractValidator` 拒绝。

## 范围边界

此 HAR 不包含：

- Workflow DAG 语义和循环检测；
- Router 算法和评分；
- Tool 授权决策；
- 网络、存储、ArkUI、Ability 或系统 Kit；
- Provider secret 或论文训练代码。

这些职责分别属于后续 M01、M02 和其他开发模块。
