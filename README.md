# Shuvi（休比）

> 当前阶段：真实能力整合与验收。状态截至 2026-10-27：`main` 已合入检索优先 RAG 与验收修复（PR #20），debug 首页已接入 Runtime 助手对话、授权搜索与知识库 RAG；`feat/calendar-real` 在此基础上接通助手聊天 → Runtime 日程草稿 → 用户确认 → 原生日历工具（合入 main 前本机 171 项宿主测试与 HAP 构建通过，正常创建获模拟器人工反馈，返回修改待模拟器验收；合入后的复验见 spec 01）。知识库 RAG 已在模拟器上用真实 Provider 跑通（未完整落盘设备日志，不计正式验收）。签名安装、完整 CI 与 OpenHarmony 真机验收尚未完成。

> 本轮新增：[应用内悬浮助手入口](specs/02-应用内悬浮助手入口.md) v0.3 已实现拖动与左右吸边，本轮模拟器验收范围见第 6.7 节；v0.2 的历史反馈见第 6.6 节。可从其他页面返回当前对话，在「我的」关闭入口。位置与开关仅本次运行有效，重启恢复开启并回到右下角；未覆盖窗口场景、无障碍朗读与真机待验证。

> 知识库已接入统一资料导入、正文/OCR、本机标签与语义检索；当前产品链路固定先做本机正文/标签匹配和问题向量 KNN，再把最多 5 条片段交给 DeepSeek 生成带引用回答。助手聊天（含日程草稿）与 RAG 共用一次输入的 DeepSeek Key，但使用彼此独立的会话、规划器与执行库；现有知识库开关直接切换 RAG。边界见 [交接契约](docs/integration/知识库回答UI交接契约.md)。

## 项目简介

独立 [联网搜索 MCP Server](services/search-mcp/README.md) 提供 Tavily `web_search` 工具。debug 首页已实现关键词 → 授权 → Runtime/MCP 搜索 → 来源保存 → 独立模型任务回答，用户确认模拟器主要流程符合预期；设备证据待归档。当前最多允许一次未核账派发，重启不解除限制，账单导入与额度释放尚未实现，详见 [03 联网搜索](specs/03-联网搜索.md)。

日程和搜索 Mock 继续作为独立演示模式保留，不调用真实供应商。真实模式不会失败后自动回退成 Mock；普通对话、真实搜索与演示的范围分别记录，不能混用验收证据。

Agent 八模块已迁至 `modules/harmony_agent/`，来源固定为 `f177176`，后续适配登记在 `LOCAL_CHANGES.json`；六个 HAR 供产品引用，另两个用于独立测试宿主。应用服务已装配生产 Runtime，当前开放 debug 对话、确认后创建日程和显式关键词搜索；自主多 Agent 协作尚未完成产品验收。连接检查仍只做 MCP 握手与工具发现。统一进度与证据见 [08 项目进度与验收](docs/08-项目进度与验收.md)。

休比（Shuvi）是面向开源鸿蒙社区竞赛开发的智能个人助理，使用 ArkTS / ArkUI 开发。产品目标、需求层级与架构建议见 [00 项目总览](docs/00-项目总览.md)。

## 功能特性

功能范围与优先级由团队维护，见 [00 项目总览](docs/00-项目总览.md) 第 2 节。需求未冻结，具体行为、平台约束与验收标准在对应功能 spec 中逐步明确。

## 项目结构

| 路径 | 说明 |
|---|---|
| `entry/` | 应用入口 HAP：页面、日程/搜索演示、Runtime 对话与搜索应用服务、独立知识库及宿主逻辑测试 |
| `AppScope/` | 应用级配置（`app.json5`：bundleName、版本、图标与名称） |
| `services/search-mcp/` | 独立 Node.js 搜索 MCP Server，不进入 HAP；单独安装、构建与测试 |
| `services/local-ai-gateway/` | 独立 Windows/.NET 模型网关，固定源码已导入，自包含自动测试 588/588 通过；不进入 HAP，远端 CI 与完整运行包验收待完成 |
| `modules/harmony_agent/` | 八个 Agent HAR 源码模块及测试；原六模块供产品依赖，另外两个仅接入测试工程 |
| `tests/agent-host/` | 独立 Agent 测试工程，复用八模块；本机 Hypium 380/380 通过，设备测试待执行 |
| `tools/agent/fixture/` | 固定样例 MCP 测试服务，不是生产搜索服务 |
| `scripts/` | 本地一键启动脚本：设备/模拟器 → 签名 → 构建 → 安装运行 |
| `specs/` | 按用户闭环划分的功能契约，三条开发线的唯一对齐点 |
| `docs/` | 项目文档，见下方文档索引 |

早期建议的 `assistant_core` 与 `platform_adapter` 职责现由六个 Agent 模块及 entry 中的应用服务承接，未建立这两个同名目录。建议职责与实际模块的对应见 [00 项目总览](docs/00-项目总览.md) 第 3 节。

## 快速开始

日程 Mock 的历史范围与真实能力分别见 [01 创建日程并提醒](specs/01-创建日程并提醒.md)。工作台保留手动填写、模型草稿、多条记录与原操作核查；迁移、第二条创建及开启系统日历通知后的提醒送达已获用户人工反馈。新增助手真实模式可从聊天安排日程：模型提议草稿，用户确认后 Runtime 调用 `shuvi.calendar.create` 原生工具，复用工作台的日历、稳定操作 ID 与防重复账本。同一助手会话内不重复输入 Key。聊天接入的自动化证据与待验收范围见 spec 第 7.12 节，旧设备反馈不代替新入口验收。真实对话/搜索会按授权访问外部服务并持久化执行记录；知识库保存本机资料。新构建的未签名 HAP 仍需通过已有本机签名运行配置安装。

普通对话的启用和限制见 [09 Runtime 普通对话](specs/09-Runtime普通对话接入.md)。当前模型路径为设备直连 DeepSeek，不必运行 Windows 网关；真实搜索仍需电脑上的 Node 服务与调试转发，尚非正式部署方案。

前置：DevEco Studio 与命令行 `devecocli`；首次使用需 `devecocli auth login`。

```bash
scripts/dev-run.sh                 # 自动选设备/模拟器，签名、构建、安装运行
scripts/dev-run.sh --force-sign    # 强制重新生成本机签名材料
scripts\dev-run.cmd                # Windows 入口，转发到 dev-run.sh
```

签名材料生成在本机 `~/.ohos/config/`，不写入仓库；不要提交 `build-profile.json5` 中的 `signingConfigs` / `signingConfig` 改动。

## 架构设计

架构建议、模块边界与依赖约定见 [00 项目总览](docs/00-项目总览.md) 第 3 节；工程配置、SDK 与工具版本见 [02 平台基线](docs/02-平台基线.md)。

## 智能体编排

已引入 Runtime 并接入普通对话和授权搜索。当前使用确定性单轮/单工具计划；搜索与随后回答是两个 Runtime 任务，不是跨任务自动恢复事务。多 Agent 协作、模型自主分解复杂任务尚无产品闭环验收。架构与执行边界见 [Agent 运行时架构](docs/architecture/Agent运行时架构.md)。

## RAG 知识库

已实现 TXT/MD、PDF、独立图片、DOCX 的统一处理及本机正文/OCR、标签与语义检索，包含来源预览和中断恢复；已有部分真实服务的模拟器验收记录。云解析、图片理解与嵌入按各自授权配置运行，不能称所有处理均离线。debug 首页已接入检索优先 RAG：点击知识库后检查当前 Embedding Provider 和向量空间，发送时执行问题向量化与本机 KNN，再由独立 PERSONAL DeepSeek 会话整理引用；普通 PUBLIC 对话不承载知识库片段。2026-10-27 已在模拟器上用真实 SiliconFlow / DeepSeek 跑通 RAG（spec 09 §8.4，日志未完整落盘、部分项仅用户确认）；PPTX/XLSX、跨设备同步、断网重试的设备验证与真机验收未完成。详见 [02 个人知识库问答](specs/02-个人知识库问答.md) 与 [09 Runtime 普通对话接入](specs/09-Runtime普通对话接入.md)。

## 文档索引

| 文档 | 内容 |
|---|---|
| [00 项目总览](docs/00-项目总览.md) | 产品目标、需求范围、架构建议、Agent 与执行原则、质量目标 |
| [01 协作与工程约定](docs/01-协作与工程约定.md) | 分工与分支、Git 与提交规范、ArkTS 边界、测试与发布 |
| [02 平台基线](docs/02-平台基线.md) | 工程配置、SDK 与工具版本、验证状态、待确认项 |
| [03 鸿蒙核心概念速览](docs/03-鸿蒙核心概念速览.md) | HAP、HAR、HSP、Stage 模型等概念与仓库现状对照 |
| [04 图标素材库](docs/04-图标素材库.md) | 23 个图标的用途、ArkUI 复用方式与维护规则；[本地预览页](docs/assets/icons/index.html) |
| [05 品牌配色与 Logo](docs/05-品牌配色与Logo.md) | 角色形象、莓紫与奶油白配色、应用图标配置；[本地预览页](docs/assets/brand/index.html) |
| [06 Agent 模块接入](docs/06-Agent模块接入.md) | 六模块固定源码快照、依赖配置、构建证据与后续接入边界 |
| [07 仓库整合与文档迁移方案](docs/07-仓库整合与文档迁移方案.md) | 来源版本、授权记录、迁移范围与执行进度 |
| [08 项目进度与验收](docs/08-项目进度与验收.md) | 当前整合成果、本机验证、设备与产品接入待办 |
| [文档导航](docs/README.md) | 当前文档、子项目架构与部署入口；历史说明的适用边界 |

## 构建与签名

- 构建：`devecocli build`，或使用 DevEco Studio
- 签名：本机自动生成，材料保存在 `~/.ohos/config/`，不入库
- 运行：`devecocli run`，或使用 `scripts/dev-run.sh`
- 构建、模拟器与真机结果分别记录、不互相替代，见 [02 平台基线](docs/02-平台基线.md) 第 4 节
- CI 门禁：来源核验、Node 搜索测试、鸿蒙检查与构建、Agent 宿主/Hypium、Windows 网关测试；runner 前提及尚未完成的远端验证见 [持续集成](docs/deployment/持续集成.md)

## 贡献指南

协作规则、分支与提交格式、PR 与评审要求见 [01 协作与工程约定](docs/01-协作与工程约定.md)。

## License

本项目采用 MIT 许可，见 [LICENSE](LICENSE)。
`modules/harmony_agent/` 的上游模块声明使用 Apache-2.0，许可说明与标准文本保留在该目录。
`services/local-ai-gateway/` 保留其原 LICENSE 和第三方声明，不适用根目录 MIT；用户已确认取得本次整合与发布范围的书面授权，记录见该子项目 `UPSTREAM.json`。
