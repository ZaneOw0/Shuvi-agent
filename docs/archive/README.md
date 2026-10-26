# 历史文档归档

> 状态：已实现待验收（固定来源归档；不继承上游验收结论）。
> 更新日期：2026-10-23。

当前维护入口是 [项目进度与验收](../08-项目进度与验收.md)、[Agent 架构](../architecture/Agent运行时架构.md) 和 [接入说明](../integration/agent/接入与边界.md)。

## Agent 原文

[harmony-agent-f177176](harmony-agent-f177176/UPSTREAM.json) 保存固定提交的 29 份 Markdown：根 README、PROJECT_STATUS，以及 docs 下的架构、ADR、接口、验收和交接文档。每份增加历史警示；相对文档链接指向固定上游版本，避免把尚未迁入的文件误作本地可用。

清单记录原始 Git blob SHA-256、归档后 SHA-256 和处理方式；使用 `node scripts/verify-agent-docs.cjs` 核验。这里只保存文档，不复制原作者的制品、日志、密钥、签名或私有安装现场。原文命令不构成当前机器上的操作授权。

- [原项目进度](harmony-agent-f177176/PROJECT_STATUS.md)
- [原架构与模块](harmony-agent-f177176/docs/architecture/HARMONY_AGENT_DEVELOPMENT_MODULES.md)
- [原测试矩阵](harmony-agent-f177176/docs/TEST_MATRIX.md)
- [原缺口审计](harmony-agent-f177176/docs/BACKEND_GAP_AUDIT.md)
- [原研究交接](harmony-agent-f177176/docs/MTRouter_TRAINING_REPOSITORY_HANDOFF.md)

## 网关原文

网关历史文件保留在 [services/local-ai-gateway](../../services/local-ai-gateway/README.md)：README.upstream、HANDOFF、PROJECT_MASTER_PLAN、PROJECT_STATUS、TECHNICAL_DECISIONS。来源 `21017a1` 及逐文件哈希位于该目录 UPSTREAM.json；不复制第二份历史正文。

## 维护规则

归档内容保持可追溯，当前改动写入主文档。上游的“完成”“已批准”“已验收”限定于其日期、版本和现场；本仓库重新构建、测试、设备验收与发布必须另有证据。若归档有确需脱敏的内容，单独记录原因和变更，不静默覆盖来源。
