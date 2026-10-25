> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/ENVIRONMENT_IMPACT.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# 本机环境影响与回退记录

以下历史记录中的模块和依赖路径按当前 `harmony_agent` 命名展示；旧文本和副本已按所有者要求规范化，原 SHA-256 保存在处理清单中。这些历史结果不表示当前版本已经设备复验。更名和清除仅在本工作区内执行，9 个内部依赖 Junction 的目标保持在本工作区内，未安装依赖或修改全局配置。

2026-10-02 经所有者专项授权，还处理了本工作区 `.git` 中 6 个 Codex 历史差异/回滚引用和 427 个关联旧对象，旧命名无法再从这些快照恢复。Git 完整性检查通过；HEAD、仓库配置及当前源码未因这次快照处理改写。执行记录位于 `artifacts/complete-naming-cleanup/20261002/git-preparation/applied.json`。

## 永久设置

本任务没有修改以下内容：

- 注册表、用户或系统环境变量、PATH。
- 防火墙、代理、证书、签名配置。
- HarmonyOS SDK 或 DevEco Studio 安装。
- 模拟器配置。

验收脚本只在子进程范围设置 `DEVECO_SDK_HOME`、`MCP_FIXTURE_URL` 和 `MCP_PROTOCOL`，结束后恢复原值。Fixture Server 使用临时端口并在 `finally` 中停止。设备测试成功安装 HAP 后，默认也在 `finally` 中卸载；仅 `-KeepTestApp` 会保留。

## 依赖和下载

工程测试依赖已锁定：

- `@ohos/hypium@1.0.28`
- `@ohos/hamock@1.0.0`

Node Fixture Server 只使用 Node.js 内置模块，没有 npm 依赖。官方 MCP SDK 仅查询过发布元数据，没有安装。

项目内 `oh_modules` 保留，以便在不联网的情况下复验。只有显式传入 `-InstallDependencies` 时，验收脚本才会调用 OHPM。

T02 经用户明确授权后，仅为 `agent_core` 的本地 `file:../agent_contracts` 依赖执行了一次 OHPM 安装。命令显式把 prefix 与 cache 限定在本工作区，生成 `agent_core/oh-package-lock.json5` 和被忽略的 `agent_core/oh_modules`；没有下载新的 registry 包。OHPM 尝试初始化用户目录中的 DevEco telemetry 路径，但被文件系统沙箱以 `EPERM` 拒绝，未获得工作区外写权限。

T07 没有运行 OHPM 或下载依赖。为让 Hvigor 解析两个既有工作区模块，只在 `agent_storage/oh_modules/@harmony_agent/` 内建立了 `agent-contracts` 与 `agent-core` 两个目录联接，目标分别仍位于本工作区的 `agent_contracts/` 和 `agent_core/`；构建与测试产物也只写入 `agent_storage/build` 和 `agent_storage/.test`。没有为本步骤写入工作区外路径。

后续 T07 设备测试源码编译同样没有运行 OHPM。仅在 `test_host/oh_modules/@harmony_agent/` 增加了指向工作区内 `agent_contracts/`、`agent_core/` 和 `agent_storage/` 的三个目录联接；既有 `mcp-client` 联接保持不变。HAP 产物只写入 `test_host/build`。没有安装 HAP、连接设备、创建设备数据库或写入工作区外路径。

## 已完成的精确清理

此前依赖安装/元数据查询产生、且可精确归属本任务的全局缓存只有以下文件。它们已在最终验收后按完整路径删除，并逐项验证不存在：

- `C:\Users\Admin\.ohpm\cache\content-v1\sha512\8a\3c\03af12a8578dc8821a4cfba1979be585a191bad22704d1b45c7fe7e1768888d633b0fd8d9669f748430b02f7922e4bc3878152eaae64c6864c55af41dab6`
- `C:\Users\Admin\AppData\Local\npm-cache\_cacache\content-v2\sha512\bc\7e\d9e3334bede7567d0d684ffd1ee90205099f7a716db6826f9539006df07c26e57c3c3833ed57c28edd243b78e9532a778aaecfc3519ec8efdce966dd6469`
- `C:\Users\Admin\AppData\Local\npm-cache\_cacache\index-v5\97\54\55a9256b911b2d89a03198b349b31a9caf2870c18812e88bface08c2eb1a`
- `C:\Users\Admin\AppData\Local\npm-cache\_logs\2026-09-23T16_19_00_638Z-debug-0.log`

没有执行全局 `npm cache clean` 或 OHPM cache clean。项目构建中间物与项目内 `oh_modules` 均保留，以支持离线复验；它们不是未记录的下载残留。
