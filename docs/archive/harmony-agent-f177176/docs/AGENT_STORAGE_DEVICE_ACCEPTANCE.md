> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_STORAGE_DEVICE_ACCEPTANCE.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Agent Storage 设备验收

2026-10-02 历史材料已按所有者要求统一名称。下文历史设备 7/7 为结果转述，相关旧日志可能经过名称替换、旧 signed HAP 已退役；当前 RDB 表的验收须独立运行。处理清单见 `artifacts/complete-naming-cleanup/20261002/changes.json`。

本文只描述 `agent_storage` 的 test-only 验收流程，不交付产品页面、产品 Entry Ability 或产品 HAP。测试复用仓库现有无页面 `test_host`；Agent 的唯一外部业务控制入口仍是 `AgentRuntimeFacade`。

当前测试宿主包名为 `com.harmony.agent`；本页以“历史测试包名”指代更名前的设备身份。旧文本已规范化、旧签名 HAP 已退役，原文件 SHA-256 仅留作追溯。T07 历史成功记录属于旧包名及旧 RDB 表，今后复验命令使用当前包名。

## 历史验收结论

- `agent_storage` 0.4.0 当前合并主机 Hypium：39/39 已运行通过，其中本页对应的 M05-A 为 26 项；M05-B 设备门另见 [`AGENT_MEMORY_DEVICE_ACCEPTANCE.md`](https://github.com/AlterGo-xzy/Harmony_agent/blob/f1771764f129193725a8bccb5da2be6c3604e998/docs/AGENT_MEMORY_DEVICE_ACCEPTANCE.md)。T07 的设备 7/7 是旧 schema 证据，0.4.0/schema 1.2 必须重新运行本页套件后才能取得当前设备证据。
- API 26 签名主 HAP 与 ohosTest HAP：已构建并安装成功。
- `StorageDeviceRecovery`：7/7 已在 API 26 模拟器运行通过，`Failure: 0`、`Error: 0`。
- 验收后 `历史测试包名` 已卸载，并通过独立查询验证 bundle 不存在。
- 成功运行目录：`artifacts/t07-device-acceptance/20261001-211416/`。

## 用例

`StorageDeviceRecovery` 当前包含 8 项：

1. 加载 `@harmony_agent/agent-storage` HAR；
2. `PREPARED` intent 与 `RESERVED` budget 在 RDB close/reopen 后保留；
3. 调用中退出后，reopen 在返回恢复 session 前把 `IN_FLIGHT` 可靠固化为 `UNKNOWN_OUTCOME`；
4. 已观察到 provider 结果、但结果提交前退出时，不伪造成功，reopen 后仍为未知；
5. `COMMITTED` outcome、provider receipt 与实际预算在 close/reopen 后保留；
6. 两个 stale recovery session 竞争 lease/CAS 时只有一个成功；
7. 持久化摘要损坏时 fail-closed；
8. opaque Runtime checkpoint 与任务枚举在真实 RDB close/reopen 后保持一致。

第 8 项已编译进当前签名 ohosTest HAP 并完成安装，但本轮按类只运行 T26 两阶段用例，没有单独重跑完整 `StorageDeviceRecovery`；下文 7/7 仍是 T07 旧 schema 的历史设备证据。

T26 另新增两项按类筛选的两阶段用例：

1. `RuntimeRdbDeviceRecoverySeed` 通过 `createRdbRecoveredAgentRuntime` 创建唯一 Facade，授权一个 Tool step，使真实 RDB 持久化 active operation 与 lease，但不回调完成；随后输出 `T26_SEED_READY` 并保持测试进程存活；
2. 验收脚本同时核对就绪标记与 bundle PID 后执行 `aa force-stop com.harmony.agent`，再核对 PID 消失；
3. `RuntimeRdbDeviceRecoveryRecover` 在新进程中重新打开同一 RDB，要求 Facade 为 `WAITING_RECONCILIATION`、Adapter 调用数为 0、operation/budget 为 `UNKNOWN_OUTCOME`/`UNKNOWN` 且 recovery lease 已释放；
4. recover 成功后 fixture 删除数据库，脚本卸载 bundle 并保存独立核对日志。

该链路已在 API 26 签名包上完成。seed 被 force-stop，因此预期输出为就绪标记后 `App died`；它不伪装为一个正常完成的 1/1。通过条件是就绪标记、停止前存活 PID、停止后 PID 消失、recover 1/1 及卸载核对全部成立。

每项 RDB 测试使用独立数据库，并在开始前清理旧 fixture、在 `finally` 中关闭 RDB 后删除数据库。

## 工作区内构建

```powershell
$env:DEVECO_SDK_HOME='D:\DevEco\DevEco Studio\sdk'
& 'D:\DevEco\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=agent_storage@default -p product=default test --no-daemon
& 'D:\DevEco\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=test_host@default -p product=default assembleHap --no-daemon
& 'D:\DevEco\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=test_host@ohosTest -p product=default assembleHap --no-daemon
```

T26 本地未签名构建结果：

- `agent_storage.har`：70,080 bytes，SHA-256 `8D59F009568380526DC44A45D7973CA11FD33E8960DF2E9447780EB9BD23AFBC`；
- 主 HAP：8,708 bytes，SHA-256 `EC3EC976011706AA01CFF11428D4812E91650FF937EA7AAE8F3E72CF06DB3697`；
- ohosTest HAP：2,954,945 bytes，SHA-256 `0362C49E9DBB6887377F8153091BE033FD6B612A0837EF64EBAF86689EFC34B7`；
- 两个 HAP 构建日志均明确 `No signingConfig found for product default`。

常规未签名构建产物位置：

```text
test_host/build/default/outputs/default/test_host-default-unsigned.hap
test_host/build/default/outputs/ohosTest/test_host-ohosTest-unsigned.hap
```

T26 验收使用的签名交付物：

```text
artifacts/t26-rdb-runtime-recovery/20261011-234747-signed-build-v4/deliverables/test_host-default-signed.hap
artifacts/t26-rdb-runtime-recovery/20261011-234747-signed-build-v4/deliverables/test_host-ohosTest-signed.hap
```

- 主 HAP：47,064 bytes，SHA-256 `4C9A5082A759DB1BB62768821D1A3443C2BCB3741249B0178C4204990BFDAF7C`
- ohosTest HAP：3,003,143 bytes，SHA-256 `2F43BB3AA2356FB625A8C361090E28A83B8DD009C5B96D80894B1A16BE37ADC1`
- 项目已有签名材料未被复制；临时 product 关联结束后，根 `build-profile.json5` 已按原始字节与 SHA-256 恢复。私钥和口令未进入验收目录。

## 设备运行

使用已有 DevEco/组织签名流程生成可安装 HAP；不得把私钥、证书口令或账户凭据提交到仓库。确认目标设备和 bundle 后，执行：

```powershell
hdc install -r <signed-main-hap>
hdc install -r <signed-ohosTest-hap>
hdc shell aa test -b com.harmony.agent -m test_host_test -s unittest OpenHarmonyTestRunner -s class StorageDeviceRecovery -s timeout 60000
```

T26 的跨进程用例必须使用当前版本签名主/测试 HAP。取得签名、安装与设备操作授权后，使用工作区脚本：

```powershell
.\tools\test-runtime-rdb-recovery.ps1 `
  -MainHap <工作区内的 signed main HAP> `
  -TestHap <工作区内的 signed ohosTest HAP>
```

脚本要求恰好一个 HDC target，依次执行安装、后台 seed、核对就绪标记与进程 PID、force-stop、核对 PID 消失、recover 1/1、卸载、按名称查询和全量 bundle 清单核对，并只把日志写入 `artifacts/t26-rdb-runtime-recovery/<timestamp>/`。安装还必须明确报告成功，不能只依赖 HDC 退出码。任一步无法形成明确证据都会失败。

## T26 当前验收结果

- 设备：`emulator 7.0.0.106(SP1DEVC00E999R4P11)`，API 26，目标 `127.0.0.1:5555`；
- 签名主 HAP：47,064 bytes，SHA-256 `4C9A5082A759DB1BB62768821D1A3443C2BCB3741249B0178C4204990BFDAF7C`；
- 签名 ohosTest HAP：3,003,143 bytes，SHA-256 `2F43BB3AA2356FB625A8C361090E28A83B8DD009C5B96D80894B1A16BE37ADC1`；
- 两个 HAP 均通过 SDK `hap-sign-tool verify-app`；安装均明确成功；
- seed 输出 `T26_SEED_READY`，停止前 PID 为 12616；`aa force-stop` 成功，停止后 PID 为空；
- recover：`Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0`；
- 卸载成功，按名称查询失败且全量 bundle 清单精确匹配数为 0；
- 根 `build-profile.json5` 在签名构建后按原始 SHA-256 恢复；签名值和口令没有写入验收日志。

成功设备证据位于 `artifacts/t26-rdb-runtime-recovery/20261011-234816/`，最终签名构建与验证证据位于 `artifacts/t26-rdb-runtime-recovery/20261011-234747-signed-build-v4/`。T26 已关闭。

以下是 T07 历史目标与完整旧套件报告：目标 `127.0.0.1:5555`，系统版本 `emulator 7.0.0.106(SP1DEVC00E999R4P11)`，API 版本 26。Hypium 报告：

```text
Tests run: 7, Failure: 0, Error: 0, Pass: 7, Ignore: 0
```

T07 安装、测试、设备信息和清理日志位于其历史成功运行目录的 `logs/` 下；T26 使用上文单独列出的成功目录，`acceptance-summary.json` 是机器可读摘要。

验收后清理：

```powershell
hdc uninstall com.harmony.agent
```

同时确认测试 bundle 已不存在。测试自身会删除 fixture 数据库，但卸载验证仍然必须独立完成。
