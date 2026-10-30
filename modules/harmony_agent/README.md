# Harmony Agent 模块

本目录保存八个 ArkTS HAR，来源固定为 Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998`。原始文件与版本见 [UPSTREAM.json](UPSTREAM.json)，主仓库适配见 [LOCAL_CHANGES.json](LOCAL_CHANGES.json)。

## 当前用途

产品使用 agent_contracts、agent_core、agent_runtime、mcp_client、agent_connectors、agent_storage 及 native_tools；agent_testkit 用于独立 [测试宿主](../../tests/agent-host/README.md)。应用已装配生产 Runtime，设备直连模型并接入搜索、知识库、日程和文档工具。

应用通过 Index.ets 公共出口使用模块，页面不跨模块访问内部实现。宿主负责平台适配、实际资源与用户授权；模块能力不直接代表每条产品链路已通过设备验收。

## 来源与维护

原始来源清单保留固定快照，本地变更单列原因、旧/新哈希、契约影响及验证。构建生成的 BuildProfile、缓存和产物不入库；HAR 采用本地源码依赖，尚未作为独立 SDK 发布包交付。

```bash
node scripts/verify-agent-host.cjs
node scripts/verify-agent-import.cjs
```

模块自带 README 保留上游接口说明；其中历史测试和机器路径限定于来源版本。当前入口见 [Agent 接入](../../docs/06-Agent模块接入.md)、[模块职责](../../docs/architecture/Agent模块与职责.md) 和 [验收索引](../../docs/verification/README.md)。

## 许可与历史

模块声明 Apache-2.0，保留作者声明与 [标准文本](LICENSE-2.0.txt)。上游 29 份原始文档位于 [固定归档](../../docs/archive/README.md)，研究、发布与设备工具的范围见 [迁移清单](../../tools/agent/迁移清单.md)。
