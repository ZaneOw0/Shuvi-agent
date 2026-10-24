# Agent 独立测试宿主

> 状态：已实现待验收（构建与本机测试见验证记录；设备运行待验收）。
> 更新日期：2026-10-23。

本工程承载 Agent 设备测试，不是 Shuvi 产品入口。使用固定来源 `f1771764f129193725a8bccb5da2be6c3604e998` 的 `test_host`、资源与测试，源码来源及三处适配见 [UPSTREAM.json](UPSTREAM.json)。包名改为 `com.example.shuvi.agenttest`，与产品 `com.example.shuvi` 和上游 `com.harmony.agent` 分离；生命周期测试中的启动目标同步更新。

## 1. 工程边界

- 通过相对路径引用 `../../modules/harmony_agent/` 的八个模块，不复制第二份核心代码。
- 产品仍只注册原六模块；`native_tools` 和 `agent_testkit` 本轮仅注册到测试工程，没有加入产品 entry 依赖。
- `test_host` 是唯一 entry HAP；`test_host_test` 是 ohosTest feature HAP。测试 UIAbility 没有页面内容，打开它不会出现 Shuvi 聊天界面。
- 根 SDK、Hypium `1.0.25`、Hamock `1.0.0` 与主仓库一致，不沿用上游的 Hypium `1.0.28`。锁文件由 OHPM 生成。
- 宿主声明 INTERNET 供网络测试使用；没有修改产品权限。`signingConfigs` 为空，自动构建产物未签名。
- 模块和宿主源码包原许可声明保留，标准许可文本见 [Apache-2.0](../../modules/harmony_agent/LICENSE-2.0.txt)。

## 2. 本机复验

在 Shuvi 根目录执行，DevEco 路径按本机安装位置填写：

```powershell
node scripts/verify-agent-host.cjs

$devecoRoot = 'C:\Program Files\Huawei\DevEco Studio'
$env:DEVECO_SDK_HOME = Join-Path $devecoRoot 'sdk'
$env:JAVA_HOME = Join-Path $devecoRoot 'jbr'
Push-Location tests/agent-host
try {
    & "$devecoRoot\tools\ohpm\bin\ohpm.bat" install --all
    if ($LASTEXITCODE -ne 0) { throw '依赖安装失败' }
    & "$devecoRoot\tools\hvigor\bin\hvigorw.bat" assembleHap assembleHar --no-daemon
    if ($LASTEXITCODE -ne 0) { throw '宿主构建失败' }
    & "$devecoRoot\tools\hvigor\bin\hvigorw.bat" --mode module -p module=test_host@ohosTest -p product=default assembleHap --no-daemon
    if ($LASTEXITCODE -ne 0) { throw '设备测试包构建失败' }
} finally { Pop-Location }

.\scripts\test-agent-unit.ps1 -DevEcoHome $devecoRoot
node scripts/test-agent-fixture.cjs
```

`test-agent-unit.ps1` 逐模块运行官方 Hvigor/Hypium 本机测试，检查进程退出码、报告更新时间及通过/失败/忽略数；报告缺失、旧报告、零用例或未全部通过都会失败。可用 `-Modules native_tools,agent_testkit` 缩小范围。证据写到忽略的 `.local/agent-tests/<时间>/`，不自动安装依赖或访问设备。

`test-agent-fixture.cjs` 仅在电脑 `127.0.0.1` 临时端口启动固定样例服务，运行其协议测试后关闭服务；不读取 Tavily 或模型凭据。它验证测试服务本身，不代表 ArkTS 客户端设备链路通过。

两个工程共享 HAR 源目录及工具生成的缓存，根产品构建与测试宿主构建应顺序执行；不要同时在两个 IDE 窗口构建。`.test/`、`build/`、`oh_modules/`、生成的 `BuildProfile.ets` 不入库。

## 3. 设备测试的前提

目前只编译设备测试包，没有签名、安装、卸载或运行设备测试。后续在专用模拟器或明确的测试设备中运行，并按测试组选择，不能直接把全部用例当成无前提的快速检查。

| 测试组 | 需要准备什么 | 影响与边界 |
|---|---|---|
| BatteryStatusDevice | 设备电池能力 | 读取电池状态；模拟器结果不代表所有硬件 |
| McpDeviceSmoke / McpFacadeDevice | 设备可达的固定样例 MCP 服务、`fixtureUrl` | 会发起测试网络请求；需明确地址或端口转发 |
| LocalAIGatewayDevice / LocalAIGatewayFacadeDevice | 测试网关端口、必要 MCP fixture 端口及相应测试脚本 | 不是自动使用本机正式模型配置；配套网关设备编排脚本尚未迁移 |
| ShuviWebSearchDevice | 搜索服务地址、用例要求的模式与相应配置 | 配套设备编排脚本待迁移；真实供应商请求须另行明确范围，不因本机 Mock 通过而自动执行 |
| StorageDeviceRecovery / MemoryDeviceRecovery | 隔离测试宿主的数据目录 | 会创建、读取、删除固定名称的测试数据库 |
| RuntimeRdbDeviceRecoverySeed / Recover | 分阶段执行及中间进程终止 | 验证跨进程恢复，不能当普通单步测试执行 |
| SecurityStorageDevice | 测试专用凭据别名、加密数据库及设备接口支持 | 会写入、轮换和删除样例凭据，备份/恢复/换钥并清理测试库；禁止代入真实 Key |

后续设备步骤必须使用本工程的包名，确认不会覆盖已有测试数据。不要直接运行上游默认包名、路径和卸载逻辑的脚本。未迁入的发布、迁移和设备编排工具见 [整合方案](../../docs/07-仓库整合与文档迁移方案.md)。

## 4. 验证记录

本轮结果见 [Agent 测试迁移验证](../../docs/verification/agent/测试宿主迁移.md)。当前 HarmonyOS API 26 的编译与本机测试，不替代目标 OpenHarmony 真机验收。
