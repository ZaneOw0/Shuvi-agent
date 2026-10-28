# Shuvi 文档导航

> 状态：已实现待验收（整合中的索引）。
> 更新日期：2026-10-26。当前摘要以 `feat/agent-grounded-qa` 的检索优先 RAG 接线为准；历史文档不替代当前完成度。

## 项目规则和当前能力

debug Runtime 单轮对话与授权搜索已接入页面；现有知识库开关已接入检索优先 RAG，复用普通对话的一次 DeepSeek Key，并在 Embedding Provider/向量空间就绪后执行本机混合检索与 PERSONAL 回答。日程仍为 Mock。当前设备直连 DeepSeek，搜索仍依赖电脑 Node 服务。先读 [项目进度](08-项目进度与验收.md) 和 [Agent 架构](architecture/Agent运行时架构.md)，再按功能 spec 核对限制与证据。

| 文档 | 用途 |
|---|---|
| [00 项目总览](00-项目总览.md) | 产品目标、功能范围和整体架构 |
| [01 协作与工程约定](01-协作与工程约定.md) | 团队协作、开发流程、文档与验收规则的权威入口 |
| [02 平台基线](02-平台基线.md) | 当前 HarmonyOS SDK、工具链和待确认的 OpenHarmony 环境 |
| [03 鸿蒙核心概念速览](03-鸿蒙核心概念速览.md) | 工程与运行概念 |
| [04 图标素材库](04-图标素材库.md) | 图标和组件使用 |
| [05 品牌配色与 Logo](05-品牌配色与Logo.md) | 品牌和视觉规范 |
| [06 Agent 模块接入](06-Agent模块接入.md) | 六模块迁移、连接探针、本轮构建与历史验证记录 |
| [07 仓库整合与文档迁移方案](07-仓库整合与文档迁移方案.md) | 来源 SHA、迁移映射、授权、已完成与待完成事项 |
| [08 项目进度与验收](08-项目进度与验收.md) | 当前整合状态、验证证据和剩余工作 |
| [功能契约目录](../specs/README.md) | 用户闭环和跨模块功能约定 |
| [后台本地文档工具](integration/agent/后台本地文档工具.md) | main 5aed870 后台文件工具适配、产品装配与用户模拟器测试入口 |

## 独立服务

- [搜索 MCP 服务](../services/search-mcp/README.md)：Node 搜索服务及复现方法。
- [Windows 模型网关](../services/local-ai-gateway/README.md)：独立网关源码与构建入口。
- [网关架构](architecture/Windows模型网关设计.md)：模块、认证和部署边界。
- [网关部署与验证](deployment/Windows模型网关.md)：主仓库路径下的构建测试及尚未完成项。

## 应用内 Agent 模块

- [Agent 模块说明](../modules/harmony_agent/README.md)：八模块代码位置、来源版本、产品与测试用途、核验及维护边界。
- [Agent 架构](architecture/Agent运行时架构.md)、[模块与职责](architecture/Agent模块与职责.md)：当前架构与上游 M/T 编号映射。
- [接入与边界](integration/agent/接入与边界.md)：宿主、模型、MCP、搜索、存储、凭据与本地工具。
- [搜索账单与结果持久化](integration/agent/搜索账单与结果持久化.md)：成功结果先保存、实际账单独立核对、迁移和恢复边界。
- [ADR-016](architecture/decisions/ADR-016-协作策略准备的整合边界.md)：协作策略异步准备的整合边界。
- [ADR-017](architecture/decisions/ADR-017-原图视觉问答费用边界.md)：原图视觉问答的未核账/请求上限边界。
- [原图视觉问答设备验收清单](verification/原图视觉问答设备验收清单.md)：待授权执行的图片/停止/取消/请求上限设备清单。
- [原图视觉问答真实 API 测试](verification/原图视觉问答真实API测试.md)：由用户在本机隐藏输入 Key 的一次真实供应商请求；不替代设备验收。
- [六模块迁移验证记录](06-Agent模块接入.md#7-六模块目录迁移与版本更新2026-10-23)：历史 HAP / HAR 构建、本机逻辑回归和用户模拟器检查。
- [独立测试宿主](../tests/agent-host/README.md)：构建、单元测试与设备测试前提。
- [测试宿主迁移验证](verification/agent/测试宿主迁移.md)：本轮八模块 380 项 Hypium 测试与设备测试包构建证据。

## 历史记录和证据

统一入口见 [历史归档](archive/README.md)。Agent 固定版本的 29 份文档已归档；网关五份历史说明继续保留在子项目内。原文不覆盖主仓库规则与当前状态。

[持续集成说明](deployment/持续集成.md) 列出 runner 前提与检查范围；[Agent 工具迁移清单](../tools/agent/迁移清单.md) 区分已迁移、替代和待处理工具。

[整合 CI 门禁复核](verification/agent/整合CI门禁复核.md) 记录当前 lint 失败证据、已修复的判定逻辑及平台交接事项。

源码导入、编译、自动测试、模拟器、真机与真实模型调用分别记录。原作者机器路径和未导入的报告仅表示历史出处，不表示当前设备已验收。
