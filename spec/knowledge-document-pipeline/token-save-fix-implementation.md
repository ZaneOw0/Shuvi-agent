# MinerU Token 保存修复实施报告

**日期**：2026-10-15。**实施状态**：COMPLETED，仅 F001–F004；不代表设备保存、UI 或真实 API 已通过。

**起点**：`a799981 feat(knowledge): 增加 MinerU 安全配置与复杂文件转发链路`，分支 `dev/rag`。沿用已批准 M2-A 契约及 `token-save-fix-tasks.md` 的限定修复授权。本轮没有 commit、push 或其他 Git 写操作。旧 implementation-report.md、verification-report.md 和 148 项历史证据保留。

## 结论与证据层级

1. **是否使用真实 SDK**：生产 `DocumentParseAssembly` 仍默认构造真实 `MineruCredentialStore`，Asset 调用委派至 `@kit.AssetStoreKit`，没有改成生产 Mock。此次 host 执行的是该真实适配器的保存/状态实现，但 Asset 调用由测试具名边界注入；没有实际调用设备 SDK。
2. **确定的调用错误风险**：原 `addSecret` 显式传 `IS_PERSISTENT=false`。官方文档和本机 SDK 说明，设置此属性即需 `STORE_PERSISTENT_DATA`，不是仅 true 才需要；应用只有 INTERNET。本轮删去该属性，保留默认 false，不新增权限。Token 和租约 AES 密钥共用 helper，均获修复。
3. **为何仍未配置**：上述参数可导致新增被拒绝；原代码又会丢掉 SDK code 和失败阶段。已在 host 重现同条件拒绝及修复后回查配置状态。**用户设备当次究竟是 add 拒绝、检查点失败、状态确认异常还是事件问题，尚无本轮设备运行证据，不能据源码指定唯一根因。**
4. **为何可能无反馈**：保存遇忙直接 return；catch 内先 await status 再赋 message，二次刷新失败会跳过原错误消息；UI optional service 调用可无动作，消息原在密码框/按钮之后。这些是源码可证的缺口，前两项有 RED→GREEN 回归；生产 status 原本吞异常为 Unavailable，因此“二次刷新抛错”是故障注入覆盖，不能冒称设备已发生。没有证据证明密码输入已被 stopEditing 吞掉，不改成延迟保留秘密。
5. **保存是否已成功、认证是否有效**：仅 host 注入场景通过；真实保存/刷新/重开、锁屏行为、独立测试别名 CRUD、MinerU 认证/文件解析均未执行。已配置只表示本机属性确认，不表示真实服务凭据有效或免费资格通过。

## 官方依据

- 只读命令：`devecocli docs read '开发指南/安全/Asset_Store_Kit_关键资产存储服务/Asset_Store_Kit开发指导_ArkTS/新增关键资产_ArkTS/asset-js-add'`。IS_PERSISTENT 默认 false，设置该属性需 STORE_PERSISTENT_DATA；不设 GROUP_ID 时无群组。
- 只读命令：`devecocli docs read 'API参考/安全/Asset_Store_Kit_关键资产存储服务/ArkTS_API/ohos_security_asset_关键资产存储服务_/js-apis-asset'`。ATTRIBUTES 不含明文；query 无记录抛 24000002；add/query/update/remove 参数和错误码已核对。
- 本机公开 SDK：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/api/@ohos.security.asset.d.ts`，31/61 权限条件，334–363 query 与未找到错误，488/551/619/644 的访问/同步/冲突/返回类型，896 的持久属性。没有读任何私有配置、签名材料或真实凭据。

## 实现结果

| 任务 | 结果 | 变更与理由 |
|---|---|---|
| F001 链路与 RED | 完成 | 核对 View→Service→Assembly→Asset→ATTRIBUTES；新增具名 Asset 注入边界及 host loader，使测试执行真实适配器代码，而非只有假 CredentialPort；先保留旧语义取 RED |
| F002 平台调用 | 完成 | 省略 IS_PERSISTENT；保护条件/冲突拒绝保持；区分保存前查询、凭据新增/更新、保存后确认和删除阶段；仅保留 SDK 数值 code 与固定分类；同步参数抛错和 Promise 拒绝都进入同一去敏边界 |
| F003 反馈/输入 | 完成 | 开始即发布忙态；遇忙可见拒绝但不清活动认证请求；仅 Configured/Missing 对应成功；先保留原错误再有界处理二次刷新；UI 明确无服务/意外失败并上移消息；保存前复制输入和模式，立即清密码框，finally 再清 |
| F004 Polish/host | 完成 | 最终 180/180、差异空白检查通过；本报告和总 spec 只追加本轮事实；未触 Verification 任务 |
| F005–F007 Verification | 排除 | checker/build/签名部署/设备 UI、真实 Asset 和真实 MinerU 留给下一阶段，没有执行或勾选 |

保存后确认失败明确为“写入已返回，状态未确认”，保留确认阶段及真实查询 code，不误说 add 未写入、不自动重试覆盖、不假已保存。无记录只按官方 24000002 识别；重复、缺失或不符保护属性仍不能配置。不读取 SECRET 做保存状态确认。

`MineruAssetStorePort` 仅为 infra 构造注入，现有构造调用不变，默认具名 SDK 实现；不加 UI、诊断路由、外部配置开关或核心领域契约。测试 loader 仅在 host 给这两个模块提供 SDK 枚举/编码和测试调用，枚举值直接取本机 SDK AST，未手写猜值；Kit 默认 Asset 操作若未注入则立即拒绝。租约测试只走共用新增 helper 后在测试 SECRET 读取处停止，不声称 AES-GCM 或文件 I/O 已验证。

## 回归与日志

所有测试使用现有 capture 脚本，`CAPTURE_HOST_ONLY=1`，`log_exit=not-run`，无设备访问。目录前缀均为 `.cache/test-logs/`，每项有 host.log、meta.txt 和全局 index.tsv；未改或绕过公开输出过滤。

| 证据目录 | 真实结果 | 可作何种证据 |
|---|---|---|
| `2026-10-15-m2-save-fix-red-a799981/` | cmd_exit=1，公开输出 withheld | 只作退出/过滤记录，不推断用例数或失败内容 |
| `2026-10-15-m2-save-fix-red-public-a799981/` | cmd_exit=1，公开输出仍 withheld | 同上；保留失败尝试，不读私有原流 |
| `2026-10-15-m2-save-fix-red-assertions-a799981/` | **171 项，152 通过 / 19 失败 / 0 取消 / 0 跳过，71.098 秒** | 修改公开用例名、把预期异常转固定断言后得到完整 TAP；原148保持通过，新增23中19失败，尚未修生产保存语义 |
| `2026-10-15-m2-save-fix-asset-green-a799981/` | **21/21，0 失败，0.686 秒** | F002 适配器定向 host，包括共用租约密钥新增参数，不是平台执行 |
| `2026-10-15-m2-save-fix-feedback-green-a799981/` | **60/60，0 失败，0.697 秒** | F003 服务/适配器及视图源码契约；非 ArkUI 运行 |
| `2026-10-15-m2-save-fix-all-green-a799981/` | **180/180，0 失败 / 0 取消 / 0 跳过，71.106 秒** | 最终原148+新增32全部 host；保留源码/runner/loader/fixture/golden 指纹和边界审计 |

首两轮过滤触发来自测试名/未捕获的预期非秘密错误文本；后续只调整测试公开表达为固定断言，未打印输入/SDK 原 message。上述前两轮不充当 RED 断言证据。构造值统一是明显非秘密的 unit 值，不入设备、不请求网络；数值错误由测试注入，仅验证透传，不声称设备出现相同错误。

### 复现

全量（RED 与最终 GREEN 使用同一命令，仅 scope 不同）：

```bash
CAPTURE_HOST_ONLY=1 RUN_CMD='DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" node --test entry/src/test/run-host-tests.cjs' /bin/bash scripts/capture-test-log.sh m2-save-fix-all-green
```

适配器定向在 node 参数加 `--test-name-pattern="MineruCredentialStore"`；服务/视图定向加 `--test-name-pattern="DocumentParseService|MineruCredentialStore|保存视图"`，对应 scope 为 m2-save-fix-asset-green、m2-save-fix-feedback-green。定向结果不能代全量结果。

最终运行 Node v22.23.2（现有 fnm 路径）、SDK TypeScript 转译器 4.9.5；host 转译执行不是 ArkTS checker/CompileArkTS。HEAD a799981，最终 host 快照 dirty10，工作区指纹 `1153bf850d8a9513fa712c7d1a12cbf9e23f09ecfca2abc0272338765abc9b20`；之后只新增本报告、总 spec 和任务勾选，报告态不混称同一指纹。完整 SHA 在最终 host.log；capture/mac-run/deps/M1 核心/golden/六原件保护审计通过，INTERNET 单一权限、备份隔离未变。

新增32项为：7项凭据 service 反馈故障、24项真实凭据适配器代码注入边界、1项保存视图源码顺序/按钮/消息/输入清理契约。覆盖省略权限属性、查询前/后失败、写后缺记录/保护异常、同步抛错、数值code、冲突/状态不符不覆盖、SECRET字节清零、更新/删除、租约共用helper、适配器→service公开消息。视图源码断言只能证明接线与顺序，不证明原生 TextInput/Watch 或实际可见布局。

## 文件与偏差

修改生产：

- `entry/src/main/ets/knowledge/infra/MineruCredentialStore.ets`
- `entry/src/main/ets/knowledge/application/DocumentParseService.ets`
- `entry/src/main/ets/knowledge/ui/DocumentParseView.ets`

修改测试/文档：

- `entry/src/test/DocumentParseServiceCases.ets`
- `entry/src/test/run-host-tests.cjs`
- `spec/knowledge-document-pipeline/token-save-fix-tasks.md`（仅 F001–F004）
- `specs/02-个人知识库问答.md`（新增 6.2.11，本轮事实）

新增：`entry/src/test/MineruCredentialStoreCases.ets`、`entry/src/test/mineru-host-loader.cjs`、本报告。

必要细化只有 infra 注入边界、host 专用 loader 与 UI 源码契约测试，用于填补原假凭据测试无法发现实际 Asset 参数错误的空白；没有生产 Stub。删除操作共用相同错误/刷新路径，做对应最小修复，未扩展新功能。没有独立 Setup/Foundational 新任务：已有有效 oh-package.json5，不 scaffold、不安装依赖。执行按 F001→F002→F003→F004，并逐任务即时勾选。

## 未完成项与安全交接

本实施任务无失败/阻塞项。下一阶段仍须 F005 的实际 ArkTS/构建取证；F006 真实独立别名非秘密 CRUD、生产仅 ATTRIBUTES、本人配置后的应用保存/刷新/重开；F007 获准单件 PDF 的应用内部真实服务验证。不得把本报告升级为真实 Asset/认证/UI/解析通过。若需要用户重新输入，秘密只能由本人在应用填写，agent 不能获取、代填或绕过授权。

本轮没有 checker/build/run/deploy/UI/device/API 调用，没有读取获准目录 PDF 或其他个人文件；不读/覆盖/删除生产 Key，不清库/卸载/重置/新增权限，不触签名、依赖、SDK 或脚本配置。`scripts/paste-to-emulator.sh` 和 `spec/knowledge-emulator-e2e/` 原未跟踪内容未读、未执行、未改。旧 M1/M2 未完成结论仍保留。
