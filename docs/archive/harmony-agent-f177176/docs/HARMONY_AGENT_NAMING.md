> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/HARMONY_AGENT_NAMING.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# harmony_agent 命名与验收边界

2026-10-02 按项目所有者要求统一命名，沿用原工程、模块划分和唯一任务控制入口 `AgentRuntimeFacade`。

## 当前名称

- 项目、应用显示名称及 vendor：`harmony_agent`。
- 测试宿主 bundleName：`com.harmony.agent`。本地 SDK 要求至少三个以点分隔的段，显示名称与 bundleName 分别配置。
- HAR 命名空间：`@harmony_agent/agent-contracts`、`@harmony_agent/agent-core`、`@harmony_agent/agent-runtime`、`@harmony_agent/agent-storage`、`@harmony_agent/mcp-client`。
- 架构文档：`architecture/HARMONY_AGENT_ARCHITECTURE.md`、`architecture/HARMONY_AGENT_DEVELOPMENT_MODULES.md`。
- RDB 表：`harmony_agent_recovery_snapshot`、`harmony_agent_memory_snapshot`。
- ArtifactManifest 评估字段：`harmonyAgentBenchResultsJson`。

包定义、import、文件依赖锁、fixture、验收脚本、SQL 与设备损坏注入目标同步修改。依赖仅复用原有本地文件，4 个命名空间目录改名后，9 个内部 Junction 仍指向原模块目录；没有下载或安装依赖。

## 数据与契约兼容

这是尚未形成首个 source commit/tag 的项目命名调整。更名前的 HAR、ArtifactManifest JSON 和数据库不能直接视为当前命名版本：宿主必须重新编译依赖，重新生成评估 manifest；已有数据库如需保留数据，应由外部 composition root 在备份后显式迁移表名，再使用当前 backend。本次不打开、改写或自动迁移任何已有数据库，也不声称旧 JSON 字段能够自动转换。

## 历史材料与当前证据

按项目所有者随后明确提出的全工作区清除要求，源码、维护文档、历史文本、旧副本和生成缓存统一使用当前名称。文档用“历史测试包名”指代更名前设备身份。受修改的历史日志仅为经过名称替换的参考材料，原二进制已退役，原 SHA-256 保存在退役记录和修改清单中；不把历史设备通过数算作当前代码通过。

本次检查包括工作区中可读取的物理文件、文件名、UTF-8/UTF-16 内容，以及 ZIP、gzip/TAR 归档和 Git zlib 对象内部内容。经项目所有者明确授权，6 个 Codex 历史差异/回滚引用已更新，427 个旧快照对象及关联目录树已替换，旧命名不能再从这些快照恢复；Git 完整性检查通过，HEAD 和仓库配置保持原状。最终名称扫描为 0 命中。Junction 不重复遍历，17 个目录联接单独检查；第三方工具目录和工作区外路径不修改。源码与 Git 工作树保留，不 reset。详细历史材料处理说明见 [HISTORICAL_MATERIALS_NORMALIZED.md](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/artifacts/HISTORICAL_MATERIALS_NORMALIZED.md)。

首次维护文件更名记录位于 `artifacts/naming-unification/20261002/`，全工作区处理及最新核对位于 `artifacts/complete-naming-cleanup/20261002/`。验证路线为项目技能的 `35-30-project-layout-and-build-surfaces.md`、`35-50-rdb-and-storage.md` 和 `testing-arkts/WORKFLOW.md`。签名、设备安装/卸载和真实设备测试不属于本轮命名清除；T08 仍须取得当前代码的签名及设备证据后才可关闭。
