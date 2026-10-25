# Agent 模块与职责

> 状态：已实现待验收（八模块已迁入并完成本机测试；产品接入另行验收）。
> 更新日期：2026-10-23。版本以各模块 `oh-package.json5` 为准。

## 1. 构建模块

以下目录均位于 [modules/harmony_agent](../../modules/harmony_agent/README.md)。前六项注册到产品工程；后两项只注册到独立测试宿主，没有新增产品能力或权限。

| 模块 | 版本 | 负责什么 | 本机 Hypium 用例数 |
|---|---|---|---:|
| agent_contracts | 0.3.0 | 任务、预算、工具、授权、事件和恢复的公共契约 | 21 |
| agent_core | 0.2.0 | 工作流校验、确定性执行规则及策略/预算基础 | 21 |
| agent_runtime | 0.16.0 | Facade、编排、规划、恢复、应用投影与宿主生命周期 | 134 |
| mcp_client | 0.2.0 | ArkTS 协议、HTTP 传输、服务管理与目录发现 | 28 |
| agent_connectors | 0.13.0 | MCP/模型适配、网关传输、搜索组合与凭据适配 | 78 |
| agent_storage | 0.9.0 | 执行恢复、记忆、RDB、加密配置与换钥封装 | 57 |
| native_tools | 0.1.1 | 当前只读电池工具；不是完整日历/提醒适配层 | 12 |
| agent_testkit | 0.6.0 | 确定性测试、故障注入与评测辅助 | 29 |

本轮合计 380 项通过，证据见 [宿主迁移记录](../verification/agent/测试宿主迁移.md)。有测试不代表每项平台能力都在真实设备验收。

## 2. 设计编号与目录映射

上游 M 编号表示职责，T 编号表示实施任务，都不是必须一一对应的构建目录。保留原编号以便与 Agent 同学沟通。

| 设计编号 | 主落点与含义 |
|---|---|
| M00 | agent_contracts：Schema 与公共契约 |
| M01、M02 | agent_core + agent_runtime：工作流、预算、策略、授权 |
| M03、M04 | agent_runtime：编排、Registry、确定性路由 |
| M05-A、M05-B | agent_storage：执行恢复；长期记忆与派生索引 |
| M06、M07 | agent_connectors：MCP；模型与 Remote API |
| M08 | native_tools：本地平台工具 |
| M09-A、M09-B | 公共 SDK/headless fake；生产 Runtime Facade |
| M10 | agent_testkit、测试源集及上游离线 Bench |
| M11 | 产物注册、校验、策略发布链；离线部分尚未迁移 |
| M12、M13 | MTRouter 模型选择；MasRouter 协作选择 |
| M14、M15 | HYSET 工具集合；AFlow 离线优化 |

T52/T53 的历史设计、修复和验证记录见 [上游模块原文](../archive/harmony-agent-f177176/docs/architecture/HARMONY_AGENT_DEVELOPMENT_MODULES.md) 及 [T53 原文](../archive/harmony-agent-f177176/docs/architecture/T53-协作策略接入与验收.md)。本轮只验证导入版本，不重新宣称所有历史任务或研究里程碑已在 Shuvi 完成。

## 3. 团队交接

| 主责 | 当前应交付内容 |
|---|---|
| UX | 应用服务接入、授权内容展示、请求/取消/失败状态、真实来源展示 |
| Agent | 生产装配示例、公共 DTO 缺口、模型能力和价格配置、任务状态语义 |
| 平台 | 目标 OpenHarmony 基线、网络/凭据/RDB 生命周期、设备验证、runner 工具链 |
| RAG | 检索端口、文档标识/来源、索引与删除语义；与记忆和执行存储分清数据归属 |

这是接入责任划分，不新增人员任命或改变 [协作约定](../01-协作与工程约定.md)。需要共同确定的契约仍写入相应 spec。
