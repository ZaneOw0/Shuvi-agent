> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_ENCRYPTED_RDB_CONFIGURATION.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Agent 加密 RDB 配置

## 1. 目的

`agent_storage` 的两个 RDB backend 接收已经打开的 `RdbStore`，因此数据库创建和关闭仍属于产品宿主。`createEncryptedRdbStoreConfigs` 为执行恢复库和长期记忆库提供统一的 API 26 安全配置，避免宿主漏掉加密或误用内存数据库。

该 helper 固定：

- `encrypt: true`；
- `persist: true`；
- 执行恢复库与长期记忆库必须使用不同且安全的文件名；
- 默认数据安全等级为 `S3`，宿主可在完成数据分级后显式改为其他受支持等级；
- 不接收、保存或记录原始数据库密钥，使用 HarmonyOS 加密 RDB 的平台默认密钥生命周期。

## 2. 宿主接线

```text
EncryptedRdbConfigurationRequest
  → createEncryptedRdbStoreConfigs
  → relationalStore.getRdbStore(context, configs.execution)
  → relationalStore.getRdbStore(context, configs.memory)
  → RdbSnapshotBackend / RdbMemorySnapshotBackend
```

宿主应把两个 `RdbStore` 纳入 `createSingleAgentHostRuntime` 的 execution storage 和 memory storage 生命周期资源，并在关闭时逆序释放。不得把配置对象、数据库口令或底层异常正文写入公共任务事件。

## 3. 官方依据与边界

HarmonyOS API 26 SDK 的 `relationalStore.StoreConfig` 声明 `encrypt?: boolean` 与 `persist?: boolean`；官方 ArkData 文档说明 `encrypt: true` 且未提供 `cryptoParam` 时使用平台默认加密参数。数据库创建后若变更加密状态，应由宿主在受控迁移流程中调用 `rekeyEx`，不能直接改 `StoreConfig.encrypt`。

本实现只验证和生成配置，不调用 `getRdbStore`，因此主机单元测试不能证明设备文件已经加密。发布前仍需签名设备验收：首次创建、关闭重开、升级保留、失败恢复、备份策略以及受控 `rekeyEx` 迁移分别记录证据。
