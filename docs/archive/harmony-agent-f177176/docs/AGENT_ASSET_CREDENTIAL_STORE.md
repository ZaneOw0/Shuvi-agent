> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_ASSET_CREDENTIAL_STORE.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Agent AssetStore credential store 接入

`@harmony_agent/agent-connectors` 提供 `AssetStoreProviderCredentialPort`，把 HarmonyOS API 26
`@ohos.security.asset` 的只读查询接入现有 `ProviderCredentialPort`。它用于产品宿主按
`providerId + scope` 解析调用期凭据，不增加任务控制入口，也不负责把生产密钥写入仓库。

## 安全边界

- 绑定表必须显式列出 `providerId`、最小 `scope`、Asset alias 和认证 header 类型。
- 同一 `providerId + scope` 以及同一 alias 都不能重复；未知 scope 在访问 AssetStore 前拒绝。
- 仅支持 `Authorization: Bearer ...` 与 `x-api-key`，不接受任意 header 名或任意前缀。
- Asset 查询只请求单条记录与明文；拿到的字节在生成调用期 header 后立即覆写为零。
- 空值、非 HTTP 可打印 ASCII、空格、换行和 NUL 会被拒绝；错误不包含 alias、provider、scope 或 secret。
- 适配器只调用 `asset.query`，不调用 `add`、`update` 或 `remove`，也不记录凭据。

## 宿主接线

```ts
const gateway: AssetCredentialBinding = new AssetCredentialBinding();
gateway.providerId = 'local-ai-gateway';
gateway.scope = 'gateway.invoke';
gateway.alias = 'shuvi.gateway.invoke';
gateway.headerKind = AssetCredentialHeaderKind.AUTHORIZATION_BEARER;

const credentials: ProviderCredentialPort = new AssetStoreProviderCredentialPort(
  [gateway], new HarmonyAssetSecretQueryPort());
ports.credentials = credentials;
```

产品宿主必须在受控设置或部署流程中预先写入 alias 对应的 Asset。写入、更新与轮换属于宿主职责；
轮换后下一次 `resolve` 会重新查询，不缓存旧值。若宿主写入时启用 `Tag.IS_PERSISTENT`，API 26 SDK
明确要求 `ohos.permission.STORE_PERSISTENT_DATA`，该权限不由本 HAR 自动添加。

## 验收范围

主机测试覆盖 Bearer、`x-api-key`、未知 scope 前置拒绝、绑定冲突、畸形 secret、字节清零和
错误脱敏。Release HAR 构建用于证明 API 26 类型与打包兼容。真实 Asset 写入、轮换、锁屏策略、
应用卸载后的数据行为及签名设备调用，必须由最终产品宿主在不暴露 secret 的条件下单独验收。
