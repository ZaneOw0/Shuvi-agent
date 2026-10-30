# Shuvi 文档导航

本目录维护当前项目说明。功能行为放在 `specs/`；诊断、验收与固定上游归档分别维护，避免把某次验证结果写成所有版本的完成状态。

## 规则与项目状态

| 入口 | 用途 |
|---|---|
| [00 项目总览](00-项目总览.md) | 产品目标、需求优先级与当前架构 |
| [01 协作与工程约定](01-协作与工程约定.md) | 分工、分支、开发、验收与发布规则 |
| [02 平台基线](02-平台基线.md) | 工程 SDK、工具链与目标设备边界 |
| [03 鸿蒙概念](03-鸿蒙核心概念速览.md) | HAP、HAR、Stage 与配置术语 |
| [04 图标](04-图标素材库.md)、[05 品牌](05-品牌配色与Logo.md) | 资源、配色和组件使用 |
| [06 Agent 接入](06-Agent模块接入.md) | 当前宿主与模块装配 |
| [07 整合与来源维护](07-仓库整合与文档迁移方案.md) | 子项目职责、来源与维护规则 |
| [08 进度与验收](08-项目进度与验收.md) | 已实现范围、证据入口与待验收项 |
| [功能契约](../specs/README.md) | 按用户闭环查找行为与验收标准 |

## 架构与接口

- [Agent 运行时](architecture/Agent运行时架构.md)、[模块职责](architecture/Agent模块与职责.md)、[知识库 L0/L1/L2](architecture/知识库L0-L1-L2链路架构.md)
- [Windows 网关设计](architecture/Windows模型网关设计.md)
- [Agent 接入边界](integration/agent/接入与边界.md)、[后台文档工具](integration/agent/后台本地文档工具.md)、[搜索账单契约](integration/agent/搜索账单与结果持久化.md)
- [知识库 UI 契约](integration/知识库回答UI交接契约.md)、[独立原图问答 UI 契约](integration/原图视觉问答UI交接契约.md)
- [ADR-016 协作策略](architecture/decisions/ADR-016-协作策略准备的整合边界.md)、[ADR-017 图片费用](architecture/decisions/ADR-017-原图视觉问答费用边界.md)

## 操作与记录

- [启动和日志](../scripts/README.md)、[CI](deployment/持续集成.md)、[网关部署](deployment/Windows模型网关.md)
- [诊断目录](diagnostics/README.md)：问题复现、原因与排查记录。
- [验收目录](verification/README.md)：具体版本、设备、命令和结果。
- [历史归档](archive/README.md)：固定上游原文，保留来源与哈希，不作为当前操作授权。

新增文档按用途归类；当前说明直接描述现有行为，不追加按日期排列的开发流水账。版本与时间用于证据定位时写入诊断或验收记录。
