# Harmony Agent 模块

> 状态：已实现待验收（八模块及测试宿主已迁入；设备与完整业务接入仍待完成）。
> 更新日期：2026-10-23。

来源：[Harmony_agent](https://github.com/AlterGo-xzy/Harmony_agent/tree/f1771764f129193725a8bccb5da2be6c3604e998)，固定提交 `f1771764f129193725a8bccb5da2be6c3604e998`，标签 `backend-v0.1.0-rc.2`。标签版本不替代各 OHPM 模块版本。

## 范围与使用

从 Git blob 导入八个 HAR 模块，共 224 个文件（包含 40 个 `src/test` 文件），未修改上游业务源码。替代原 `vendor/harmony_agent/`，只保留一套模块源码。具体版本、用途和逐文件 SHA-256 见 [UPSTREAM.json](UPSTREAM.json)。原六模块注册到产品工程；`native_tools` 0.1.1 和 `agent_testkit` 0.6.0 仅注册到独立测试工程，未增加产品依赖。

`entry` 通过本地 OHPM 依赖使用模块 `Index.ets` 公共出口；模块间保留相对依赖。页面不能跨模块访问内部文件，也不能直接调用模型或平台存储。应用现阶段只使用 MCP 连接探针，未装配生产 Runtime。

独立 [测试宿主](../../tests/agent-host/README.md) 引用这八个模块。本机 Hypium 测试 380/380 通过，设备测试包已编译、尚未执行。`native_tools` 当前包含电池状态读取工具及调度适配，不代表已提供日历等全部平台能力；`agent_testkit` 提供故障注入、固定测试场景及评测数据校验，不启动真实模型调用。

已迁入 `tools/agent/fixture` 的 MCP 固定样例服务，原始架构/进度等 29 份文档已进入 [历史归档](../../docs/archive/README.md)。其余设备编排、发布与研究目录处理见 [工具迁移清单](../../tools/agent/迁移清单.md)。各模块自带 README 保留上游原文；其中原机器路径、旧命令、模型配置和历史进度不代表 Shuvi 当前状态，当前操作以本说明和测试宿主 README 为准。

生成的 `BuildProfile.ets`、缓存与构建产物不入库；锁文件由主仓库 OHPM 重新生成。根 SDK、Hypium 和 Hamock 保持主仓库基线，未复制来源工程配置。HAR 使用本地源码依赖，不是已完成依赖重写的独立 SDK 发布包。

## 核验与维护

在 Shuvi 根目录执行 `node scripts/verify-agent-host.cjs`，验证八模块导入基线、版本、依赖闭包、产品与测试用途隔离，以及宿主导入改动和 SDK/测试框架基线。`verify-agent-import.cjs` 验证模块部分，旧命令 `verify-agent-vendor.cjs` 作为兼容入口保留。

当前清单代表导入时的基线，校验失败用于提醒代码偏离基线，不能代替代码评审或测试。后续在主仓库修改模块时，须在同一个 PR 中记录变更原因、原始哈希和新哈希、契约影响及验证证据，并扩展校验清单以区分来源基线与本地修改；不得直接批量刷新哈希掩盖变化。源仓库是否继续独立发布由团队决定。

本次迁移记录、命令及验证边界见 [Agent 接入说明](../../docs/06-Agent模块接入.md) 和 [仓库整合方案](../../docs/07-仓库整合与文档迁移方案.md)。

## 许可

八模块包均声明 Apache-2.0，保留包作者、源文件声明和 [标准许可文本](LICENSE-2.0.txt)。该固定提交没有根 LICENSE / NOTICE；标准文本沿用先前从 Apache 官方取得的副本，不新增或推断作者版权声明。此范围不扩展到尚未导入的研究资料。
