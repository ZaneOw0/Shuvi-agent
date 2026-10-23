> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_TEST_HOST_SIGNING.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Agent 无页面测试宿主：包名与签名配置

当前 bundleName：`com.harmony.agent`。

2026-10-02 的全工程统一命名及主机复验记录见 [HARMONY_AGENT_NAMING.md](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/docs/HARMONY_AGENT_NAMING.md)；最新构建证据位于 `artifacts/naming-unification/20261002/`。下文此前只改宿主身份的记录不是全工程更名后的设备验收。

应用显示名称及 vendor：`harmony_agent`。本地 SDK 要求 bundleName 至少由三段以点分隔，因此单独的 `harmony_agent` 不能用作包名。

该包名只属于现有设备测试宿主。模块名仍为 `test_host` / `test_host_test`，沿用现有 HAR 依赖及唯一业务入口 `AgentRuntimeFacade`。

## 已完成的本地包名变更

- `AppScope/app.json5` 的 app.bundleName；
- AppScope 的 vendor、应用显示名称和 Ability 标签；
- `tools/test-mcp.ps1` 的目标 bundle；
- `test_host/src/ohosTest/ets/test/McpDeviceSmoke.test.ets` 的生命周期测试 Want；
- Memory/Storage 文档的后续验收命令。

历史包名的设备通过数仅作为历史结果转述。随后按所有者要求，旧文本已规范化、含旧命名的 HAP/HAR 已退役；不能将经过名称替换的材料算作当前版本的原始设备证据。更名不迁移设备沙箱数据，历史测试 bundle 的卸载状态也只属于历史记录。

本地验证：新包名主 HAP/ohosTest HAP 的 unsigned 构建均通过，两个打包产物的 module.json 已确认新 bundleName，验收脚本 PowerShell 语法检查通过。证据位于 `artifacts/test-host-identity/20261002-harmony-agent/identity-summary.json`。本轮使用项目技能的 `35-30-project-layout-and-build-surfaces.md` 与 `testing-arkts/WORKFLOW.md` 路线；未签名、未安装或运行新包名。

## 截图中的自动签名入口

截图已打开“项目结构 → 项目 → 签名配置 → default”，勾选了“自动生成签名文件”和“关联已注册应用”。下方文件路径为空，目前还不能据此确认签名生成完成。

1. 先关闭该对话框并刷新工程，确认 `AppScope/app.json5` 已显示新 bundleName，再重新打开签名配置。
2. 选择 `default`，保留“自动生成签名文件”，选择自己的开发者团队。该测试宿主没有需要关联的已注册 AGC 应用时，取消“关联已注册应用”；若确实要关联，则选择包名与 `com.harmony.agent` 匹配的应用。
3. 包名显示或填写 `com.harmony.agent`，与 AppScope 保持一致。
4. 点击“应用”；如果“应用”不可点，点击“确定”，完成 IDE 提示的登录或签名生成流程。自动模式中灰色的密钥库、别名和口令栏由 IDE 管理，不猜填密码。
5. 生成后检查密钥库、证书及 Profile 路径或 DevEco Managed Profile 详情，确认新包名、目标设备及有效期。若界面仍为空或报错，尚未完成配置。
6. 确认工程级 `build-profile.json5` 出现签名配置，且 `app.products` 下 `name=default` 的产品引用对应 signingConfig。核对时只检查名称/引用关系，不输出签名口令字段。

自动签名参考入口：[Huawei 自动签名指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing-auto)。截图是当前 IDE 界面的依据；是否成功必须由生成结果及实际构建确认。

Profile 中的 bundle-name 必须与应用 bundleName 一致，改名后必须选择或生成匹配新名称的 Profile；旧 Profile 不能因文件存在就假定适用。依据：[OpenHarmony HarmonyAppProvision 说明](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/security/app-provision-structure.md)。

## 已有签名文件的手动配置

若手里已经有完整签名材料，或要求签名文件路径也固定在工作区内，则使用手动配置：取消“自动生成签名文件”和“关联已注册应用”，在此界面选择已有的 `.p12` 密钥库、`.cer` 证书、匹配新包名的 `.p7b` Profile，并填写该密钥库真实的 store password、key alias、key password。算法保持实际证书支持的值；不要猜测凭据。

工作区内的本地签名材料可放在 `D:\Harmony_agent\.local\signing\`，`.local` 已加入 Git ignore。签名口令只在 IDE 中输入，不发到聊天，不写入验收目录；根 build-profile 中的签名秘密也不能因为签名文件被忽略就视为可提交内容。自动模式生成后应核对实际路径，不能假定它自动遵守工作区内保存边界。

## 配置后验收

2026-10-02 19:44 当前状态：DevEco 已生成一套新的 managed debug Profile，本机签名工具验证其包名为 `com.harmony.agent` 且有效期正常；但根 `build-profile.json5` 的 `signingConfigs` 仍为空，说明生成材料后尚未把配置应用到工程。两个现有 HAP 的独立验证结果均为 `signature not found`。请在当前“签名配置 → default”窗口点击“应用”，再点击“确定”；完成后根配置应出现非空 signingConfig，`default` product 应引用它。不要把口令发到聊天或写入验收目录。

以新包名重新构建主 HAP 与 ohosTest HAP，确认两个产物都实际为 signed，且使用同一签名身份。签名配置完成不等于构建、安装或测试完成。

本项目使用 ohosTest 的 `aa test` 入口；普通 Run 的 `aa start TestHostAbility` 仍会受现有 exported=false 限制。Device 测试命令中的 bundle 改为 `com.harmony.agent`，测试模块仍为 `test_host_test`。

2026-10-02 已按用户授权完成当前包名的 signed 主 HAP/ohosTest HAP 构建、签名验证、API 26 安装、`MemoryDeviceRecovery` 3/3 和独立卸载验证。验收后工程 `signingConfigs` 与产品引用已恢复为空，Hvigor 缓存和 Codex 快照中的临时签名配置已脱敏，敏感值残留为 0。T08 已关闭；证据见 `artifacts/t08-signed-device-acceptance/20261002-195000/`。
