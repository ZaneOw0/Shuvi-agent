# Windows 模型网关部署

> 范围：独立 Windows x64 网关源码与验证；当前手机主链路直接连接供应商。

## 1. 环境与构建

工具版本由子项目 global.json 和工程配置管理；当前目标为 .NET 10 / net10.0-windows，SDK 10.0.302 允许同特性带补丁滚动。需要上游 PowerShell 脚本时使用 PowerShell 7。

```powershell
Set-Location services/local-ai-gateway
dotnet --version
dotnet test LocalAIGateway.slnx -c Release -r win-x64 -p:SelfContained=true
```

自动测试使用假服务，不请求真实模型。主仓库 `scripts/ci-gateway.ps1` 验证构建和新 TRX，排除非测试辅助项目，具体 runner 环境见 [CI](持续集成.md)。

## 2. 运行包与安装

完整运行包需按 runtime-manifests 准备并校验依赖，再使用子项目装配/验证/打包脚本；源码构建不自动下载私有 Python 运行时或安装软件。

安装、升级、卸载和自动启动涉及当前用户 Local AppData、凭据管理和进程状态，按用户授权执行。供应商 Key 与客户端令牌在受控本机入口管理，不通过仓库、消息或命令行参数传递。

手机回环地址指手机自身，开发转发和正式部署分别配置；改变监听地址不能替代服务认证与平台适配。

## 3. 来源、验证与限制

源码来源和哈希在 [UPSTREAM.json](../../services/local-ai-gateway/UPSTREAM.json)，保留 [LICENSE](../../services/local-ai-gateway/LICENSE) 与 [第三方声明](../../services/local-ai-gateway/THIRD-PARTY-NOTICES.md)。来源授权由团队保管，不扩大原许可。

主仓库已有源码导入和自动测试记录，见 [宿主迁移](../verification/agent/测试宿主迁移.md) 与 [CI 复核](../verification/agent/整合CI门禁复核.md)。历史电脑探针不作为当前手机验收，完整运行包、正式安装、实际模型、账单与 OpenHarmony 部署均需对应版本证据。
