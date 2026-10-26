> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_MEMORY_DEVICE_ACCEPTANCE.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Agent Memory 设备验收

2026-10-02 历史材料已按所有者要求统一名称。下文历史设备 3/3 为结果转述，相关旧日志可能经过名称替换、旧 HAP 已退役；不能当作当前版本的原始设备证据。处理清单见 `artifacts/complete-naming-cleanup/20261002/changes.json`。

本文只描述 T08/M05-B 长期记忆的 test-only 验收流程。测试复用无页面 `test_host`，不创建产品页面、产品 Entry HAP 或第二条 Agent 控制入口。

2026-10-08 的 `agent_storage` 0.4.0 合并主机套件为 39/39，其中 M05-B 仍为 13 项；本页的签名设备 3/3 结论仍只覆盖长期记忆设备门，不覆盖 M05-A schema 1.2 的新增 Runtime checkpoint 用例。

## 当前签名验收结果（2026-10-02 19:55，Asia/Shanghai）

- 当前命名版本的主 HAP 与 ohosTest HAP 均完成 debug 签名，签名工具验证通过，内置 Profile 包名为 `com.harmony.agent`，两包证书链一致。
- API 26 模拟器 `127.0.0.1:5555` 安装两个模块成功；`MemoryDeviceRecovery` 实际结果为 `Tests run: 3, Failure: 0, Error: 0, Pass: 3, Ignore: 0`，result code 0。
- 最终卸载成功，按名称查询和全量 bundle 清单均确认 `com.harmony.agent` 不存在。
- 工程 signingConfig、产品引用和 Hvigor 同步缓存已脱敏；经明确授权移除两个不可达的 Codex 快照旧对象，签名敏感值残留为 0，`git fsck` 通过。
- 签名产物 hash、构建、安装、运行、清理及 Git 完整性证据位于 `artifacts/t08-signed-device-acceptance/20261002-195000/`。T08/M05-B 已关闭。

当前测试宿主包名为 `com.harmony.agent`，签名配置步骤见 [AGENT_TEST_HOST_SIGNING.md](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/docs/AGENT_TEST_HOST_SIGNING.md)。下文以“历史测试包名”指代更名前的设备身份；相关旧文本已规范化、旧 HAP 已退役，原文件 SHA-256 仅留作追溯。历史 3/3 属于旧包名及旧 RDB 表的 unsigned 构建；当前命名版本仍需独立设备验收。

## 历史验收结果（2026-10-01 23:30，Asia/Shanghai）

- 用户授权补装 unsigned ohosTest HAP、运行三项测试及卸载清理后，已在 `127.0.0.1:5555` 实际完成该范围。
- 系统：`OpenHarmony-7.0.0.105`，API 26；ohosTest 安装成功，并查询确认 `test_host` 与 `test_host_test` 两个模块。
- `MemoryDeviceRecovery`：`Tests run: 3, Failure: 0, Error: 0, Pass: 3, Ignore: 0`。真实 RDB close/reopen 与索引重建、stale session CAS 单胜者、损坏摘要 fail-closed 均通过。
- `aa test` 成功启动 runner；`TestHostAbility.exported=false` 保持不变。
- `历史测试包名` 已卸载；按名称查询失败及全量 bundle 清单中不存在交叉确认清理完成。
- 本轮实际安装的 unsigned ohosTest HAP SHA-256：`695394BB0AA4FCB5F81010E19E198071062BFE80F6C5E96EA15111367F6E06BB`。本轮未签名，主 HAP此前由用户 IDE 安装；现有主机测试没有重跑。
- 原始输出、安装与清理日志、产物和源码指纹：`artifacts/t08-device-acceptance/20261001-232918/`。
- **设备行为门已通过；签名门未验证。** 本页既有关闭条件仍要求签名产物及对应验收证据，故 T08 暂不关闭；不把模拟器接受 unsigned HAP 记作签名通过。

## 历史设备诊断（2026-10-01 23:26，Asia/Shanghai）

- 用户提供的 DevEco 普通 Run 日志显示，在 `aa start -a TestHostAbility` 阶段返回 `00402028` / Ability 不可见。
- 源码 `test_host/src/main/module.json5` 的 `TestHostAbility.exported` 为 `false`；本轮设备查询也显示该 Ability 的 `visible` 为 `false`。外部普通启动受到可见性限制，参见 [Huawei 启动调试故障说明](https://developer.huawei.com/consumer/cn/doc/doccenter-tools-faq/faqs-app-debugging-23)。
- 模拟器 `127.0.0.1:5555` 当前在线，设备实际报告 API 26、`OpenHarmony-7.0.0.105`；不沿用历史预检的系统字符串。
- `历史测试包名` 当前已安装为 debug bundle，只有 `test_host` 主模块；尚无 `test_host_test`。本代理仅执行只读查询，安装来自用户的 IDE 操作。
- T08 使用 ohosTest 的 `aa test` 入口；普通 Run 主 HAP 不会执行 MemoryDeviceRecovery。现有 Ability 配置保持不变。
- 尚需补装 ohosTest HAP后才具备执行条件。当前候选是 `test_host/build/default/outputs/ohosTest/test_host-ohosTest-unsigned.hap`，SHA-256 `695394BB0AA4FCB5F81010E19E198071062BFE80F6C5E96EA15111367F6E06BB`。该产物仍为 unsigned，不能记作签名通过；其设备安装能力也尚未验证。
- 补装、测试以及最后卸载会改变当前测试 bundle 状态，须按用户要求先取得授权；卸载会删除该 bundle 沙箱数据。
- 诊断证据：`artifacts/t08-launch-diagnostic/20261001-232620/diagnostic-summary.json`，包含脱敏后的设备模块/可见性信息与用户日志来源标记。T08 仍未关闭。

历史实际运行命令保存在 `artifacts/t08-device-acceptance/20261001-232918/` 的原始日志中。当前包名的可执行命令见下文，不能用历史包名日志证明当前版本已经验收。

## 历史接手预检（2026-10-01 23:14，Asia/Shanghai）

- 会话默认工作区与 Git 根均为 `D:\Harmony_agent`；沿用现有模块和无页面 test_host。
- 已重新通过主 HAP 与 ohosTest HAP 的 API 26 unsigned 构建；未重跑已完成的主机测试。
- SDK 26.0.0.105、Hvigor 6.26.4、HDC 3.2.0f 已从本机工具核实。
- 当前根 signingConfigs 为空；`hdc -p list targets -v` 未返回目标，本轮未取得设备版本或 bundle 存在性证据。
- 未签名、未安装、未运行设备测试、未卸载。T08 保持未关闭。
- 本轮证据：`artifacts/t08-takeover-preflight/20261001-231154/`，包括成功构建日志、首次 wrapper 引导失败日志、源码指纹、产物副本与 hash。
- 设备在线后，仍需用户授权确切签名身份及对 `127.0.0.1:5555` 上 `历史测试包名` 的安装、三项 fixture 测试与卸载清理。

## 历史状态（20261001-214016；不是本轮设备复验）

- `agent_storage` 0.3.0 合并主机 Hypium：37/37 已运行通过，其中 M05-B 仍为 13 项。
- 主 HAP 与 ohosTest HAP：API 26 类型检查和 unsigned 构建通过。
- API 26 模拟器 `127.0.0.1:5555` 在线，系统版本 `emulator 7.0.0.106(SP1DEVC00E999R4P11)`。
- `MemoryDeviceRecovery`：3 项源码已编译，尚未安装或运行。
- 未运行原因：当前根 `build-profile.json5` 没有 signingConfig，产物是 unsigned；不在命令或仓库中复用、猜测或记录证书口令。
- 设备上 `历史测试包名` 查询失败，说明本次预检没有留下已安装测试 bundle。
- 预检证据：`artifacts/t08-device-preflight/20261001-214016/`。

## 用例

`MemoryDeviceRecovery` 包含 3 项：

1. 权威 Memory 记录在真实 RDB close/reopen 后保留，词法索引由权威记录重建并可检索；
2. 两个 stale durable session 竞争 revision CAS 时只有一个写入者成功；
3. RDB 中持久化摘要被篡改后，重新打开 fail-closed。

每项测试使用独立数据库，在开始前删除旧 fixture，并在 `finally` 中关闭 RDB 后删除数据库。

## 工作区内构建

```powershell
$env:DEVECO_SDK_HOME='D:\DevEco\DevEco Studio\sdk'
& 'D:\DevEco\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=agent_storage@default -p product=default test --no-daemon
& 'D:\DevEco\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=test_host@default -p product=default assembleHap --no-daemon
& 'D:\DevEco\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=test_host@ohosTest -p product=default assembleHap --no-daemon
```

历史预检 unsigned 产物（20261001-214016）：

- `test_host-default-unsigned.hap`：8,291 bytes，SHA-256 `BDB1922D949944A97CDEBB32733A9ACE1CB78AAE2E8738C359E3BDBE44AC974B`；
- `test_host-ohosTest-unsigned.hap`：2,140,888 bytes，SHA-256 `221749D4DD6C79D43DCDBA27AA33529E9B0D4021B59D1D1EA8A301D3DFB3888C`。

## 签名设备门完成记录

unsigned 模拟器的历史安装、3/3 运行与清理已取得证据；当前命名版本又使用同一签名身份的主 HAP 与 ohosTest HAP 完成了签名验收。私钥、证书口令或账号凭据未进入验收摘要或命令输出。实际执行入口为：

2026-10-02 19:44 的最新预检确认：DevEco managed debug Profile 已生成并通过签名工具验证，包名匹配 `com.harmony.agent`，但根 `build-profile.json5` 仍是空 `signingConfigs`，当前两个 HAP 仍为 unsigned。随后 API 26 模拟器 `127.0.0.1:5555` 上线；只读查询发现主模块 `test_host` 已安装，`test_host_test` 尚未安装。下一步必须先在 DevEco 的签名配置窗口点击“应用/确定”，让 `default` 产品实际引用该签名配置；然后才能构建签名产物并进入设备验收。脱敏证据见 `artifacts/t08-signed-preflight/20261002-1942/preflight-summary.json`。

```powershell
hdc install -r <signed-main-hap>
hdc install -r <signed-ohosTest-hap>
hdc shell aa test -b com.harmony.agent -m test_host_test -s unittest OpenHarmonyTestRunner -s class MemoryDeviceRecovery -s timeout 60000
hdc uninstall com.harmony.agent
```

签名产物 hash、安装日志、Hypium 3/3 原始输出、设备版本和独立卸载验证均已保存；T08 已关闭。unsigned 历史构建未被用来替代本次签名证据。
