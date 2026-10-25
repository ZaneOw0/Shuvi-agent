# Agent 测试辅助工具

> 状态：已实现待验收（仅迁入 MCP fixture；设备编排及发布工具待适配）。
> 更新日期：2026-10-23。

`fixture/` 来自 Harmony_agent 固定提交 `f177176`，三个原始文件及哈希见 [UPSTREAM.json](UPSTREAM.json)。Node.js 标准库实现，无 npm 第三方依赖。它模拟协议响应、会话与故障，只用于测试，不作为真实搜索或模型服务。

从 Shuvi 根目录运行 `node scripts/test-agent-fixture.cjs`，自动使用回环临时端口并清理自身启动的服务。不要把 fixture 的通过数当作 Agent 设备测试结果。

上游的 Git 改写、工作区迁移、安装/卸载和 SDK 发布脚本未原样复制。它们包含原作者机器路径、包名或设备清理行为；后续逐项适配和验收，不能从来源仓库直接批量执行。

已迁移、替代与未迁移项见 [迁移清单](迁移清单.md)。当前 CI 的本机入口及 runner 条件见 [持续集成说明](../../docs/deployment/持续集成.md)。
