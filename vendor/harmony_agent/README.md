# Harmony Agent 固定源码快照

来源：[AlterGo-xzy/Harmony_agent](https://github.com/AlterGo-xzy/Harmony_agent)，提交
[`a12b6a18cbbf1188a4708997f73cea3b55860fed`](https://github.com/AlterGo-xzy/Harmony_agent/tree/a12b6a18cbbf1188a4708997f73cea3b55860fed)。
导入日期：2026-10-20；当时位于 `codex/shuvi-search-error-projection`，尚未合入上游 `main`。

此目录只完成依赖和编译接入，Shuvi 页面仍使用已有 Mock。不存在导入后自动初始化 Runtime、联网搜索或模型的行为。

## 来源与范围

六个模块：`agent_contracts`、`agent_core`、`agent_runtime`、`mcp_client`、`agent_connectors`、`agent_storage`。
上游导出的生产源码、入口、模块配置、混淆规则及模块说明共 156 个文件，逐文件 SHA-256 见 `UPSTREAM.json`。
导入内容直接读取固定提交的 Git blob，未复制上游工作区，未修改上游业务源码。

不包含上游测试宿主、研究资料、测试目录、签名或私有配置。模块 `src/main/ets/testing/` 是上游公共入口引用的测试辅助实现，作为完整源码依赖保留；Shuvi 没有调用它来替代真实 Runtime。
`BuildProfile.ets` 由本工程 Hvigor 生成并忽略；OHPM 锁文件由本工程重新生成，不属于上游哈希清单。

模块间继续使用相对 `file:` 依赖。构建产出的 HAR 用于验证，不是已发布的可独立安装 SDK 包；Hvigor 的本地依赖打包警告需保留，不能把这些 HAR 直接当作完成依赖重写的发布制品。

## 许可证

六个上游 `oh-package.json5` 均声明 `Apache-2.0`。本提交上游根目录无独立 `LICENSE` / `NOTICE` 文件；
这里附上从 [Apache 官方](https://www.apache.org/licenses/LICENSE-2.0.txt)取得的标准许可文本 `LICENSE-2.0.txt`，
保留包中的作者、许可字段和源文件原有声明，不替上游编造版权归属。
新增的说明、校验脚本和工程配置属于 Shuvi 集成改动。

## 核验与升级

在 Shuvi 根目录执行：

```powershell
node scripts/verify-agent-vendor.cjs
```

脚本核对源码哈希（允许 Git 的 LF/CRLF 行尾差异）、模块版本、许可、内部依赖闭包、
entry 依赖路径和工程模块注册，并拒绝模块中未列入清单的额外源码。执行时不依赖上游克隆或网络。
它验证与清单的一致性，不替代代码评审、许可审查或编译。

升级时单独评审新 commit、公共契约和依赖变化，再重新导出同一范围、更新清单并由 OHPM 更新锁文件。
不要直接修补本目录的公共接口；必要修复先交上游，再引入固定的新提交。接入记录见 [阶段 A 说明](../../docs/06-Agent模块接入.md)。
