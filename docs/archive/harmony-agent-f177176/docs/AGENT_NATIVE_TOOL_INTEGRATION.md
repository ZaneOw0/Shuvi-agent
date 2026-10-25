> **历史归档，不是当前操作指南。** 来源：Harmony_agent `f1771764f129193725a8bccb5da2be6c3604e998` 的 `docs/AGENT_NATIVE_TOOL_INTEGRATION.md`。归档日期：2026-10-23。
> 原文版本、机器路径、授权与验收结论只适用于上游现场；Shuvi 当前状态以 [项目进度与验收](../../../08-项目进度与验收.md) 为准。原相对文档链接改指固定上游版本，不代表所链接的制品已经迁入。

# Native Tool 集成说明

`@harmony_agent/native-tools` 0.1.1 是 M08 的无页面 Native Kit Tool HAR。首个纵切为只读电源状态工具 `native://device/power.status.read`，使用 API 26 `@ohos.batteryInfo`，用于让 Runtime 在执行长任务前获得规范化的电量与充电状态。它不提交或控制任务；外部产品仍只通过 `AgentRuntimeFacade` 使用 Agent Runtime。

## 首个工具契约

`BatteryStatusToolAdapter.registryEntry()` 返回 `ToolRegistryEntry`，其中 source 为 `NATIVE`、side effect 为 `NONE`、data boundary 为 `DEVICE_ONLY`、网络需求为 false、估算成本为 0。工具只接受空 JSON object；调用前会核对 tool identity、schema digest 和规范化参数 digest，再验证 M02 grant。

该 API 的当前字段不要求系统权限，因此 `permissionRequirements` 为空，测试宿主也没有为它新增权限声明。能力可用性通过 `SystemCapability.PowerManager.BatteryManager.Core` 独立探测。后续新增需要权限的 Kit 时，adapter 必须列出权限元数据并通过 `NativeExecutionEnvironmentPort.permissionState()` 检查；系统授权 UI 与最终 HAP 权限声明仍由外部产品宿主负责。

成功结果是稳定 JSON，字段为 `batterySOC`、`chargingStatus`、`pluggedType`、`capacityLevel` 和 `isBatteryPresent`。SOC 必须是 0 到 100 的安全整数，其余枚举先转换为稳定字符串；无效平台结果会返回 `NATIVE_INVALID_PLATFORM_RESULT`，平台异常会返回 `NATIVE_PLATFORM_FAILURE`。

## 组合边界

宿主或后续 M09-B composition root 负责注入：

- `NativeDigestPort` 和 `NativeClockPort`：与 Runtime 的摘要及时钟实现保持一致；
- `NativeGrantVerifierPort`：只接受 M02 已签发、仍有效且完整绑定当前调用的内部 grant；
- `NativeExecutionEnvironmentPort`：读取当前权限状态和 Ability 生命周期约束，不能弹出产品确认界面；
- `NativeCancellationSignalPort`：传播 Runtime 取消信号；
- `SystemNativeCapabilityProbe` 与 `SystemBatteryStatusPort`：分别执行系统能力探测和类型化平台读取。

同步电池读取无法在平台调用中途取消，因此 adapter 在调用前和返回后各检查一次取消信号。需要句柄或订阅的后续 Kit 还必须在取消、超时和完成路径释放资源。

`NativeStepDispatchAdapter` 实现现有 M03 `StepDispatchPort`，由注入的 `NativeCancellationResolverPort` 为当前 task/step/dispatch/invocation 解析取消信号，并把完成结果交给 `NativeToolOutcomeSinkPort`。`BatteryStatusToolAdapter.invoke()` 是该内部 Executor adapter 使用的调用入口，不是第二个任务控制入口。公共任务的提交、授权决定、暂停、恢复、取消和对账继续只经过 `AgentRuntimeFacade`。

## 当前验收边界

主机 Hypium contract test 12/12 已通过，覆盖 descriptor/availability、隔离副本、参数与 identity 防篡改、grant fail-closed、能力不可用、后台受限、调用前后取消、平台异常、结果校验和 M03 dispatch 接线。Release HAR 已构建。

`test_host` 已注册 `BatteryStatusDevice`，并成功构建主 HAP 与 ohosTest HAP。设备用例使用真实 `SystemNativeCapabilityProbe` 和 `SystemBatteryStatusPort`，不创建数据库、不访问网络、不写用户数据。2026-10-07 的签名主/ohosTest HAP 已通过独立签名与 Profile 验证，在 API 26 模拟器完成安装和模块核对；`BatteryStatusDevice` 实际运行 1/1 通过，结果码为 0，最终卸载并通过按名称查询和全量 bundle 清单确认不存在。M08 首个 permission-free battery slice 的设备门已关闭，证据位于 `artifacts/t11-m08-native-battery-tool/signed-device-acceptance/20261007-163616/`。

签名并安装主 HAP 与 ohosTest HAP 后，设备运行入口为：

```powershell
hdc shell aa test -b com.harmony.agent -m test_host_test -s unittest OpenHarmonyTestRunner -s class BatteryStatusDevice -s timeout 60000
```

普通 Run 会启动 `TestHostAbility`，而该 Ability 按无页面测试宿主边界保持 `exported=false`；Native Tool 验收应使用 `aa test`，不应修改 Ability 可见性。
