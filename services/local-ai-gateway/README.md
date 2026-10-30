# Local AI Gateway（Shuvi 子项目）

> 状态：已实现待验收（源码导入）；迁移后的验证记录见主仓库部署文档。
> 运行平台：Windows x64 / .NET 10。该子项目不参与 Hvigor 构建，不进入手机 HAP。

本目录保存固定上游提交 `21017a1e91a1067119f4772762295c3e343cef40` 的网关源码、测试、脚本和运行时清单。文件来源与导入哈希见 [UPSTREAM.json](UPSTREAM.json)，许可证见 [LICENSE](LICENSE)，第三方声明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

用户于 2026-10-23 确认已取得作者书面授权，覆盖将源码和文档并入 Shuvi-agent 并按主仓库可见范围发布。该记录是维护者的确认，不是授权书原文，也不改变原 LICENSE；授权书由团队保管。

## 当前维护入口

- [Windows 模型网关部署与验证](../../docs/deployment/Windows模型网关.md)
- [Windows 模型网关架构](../../docs/architecture/Windows模型网关设计.md)
- [整合方案](../../docs/07-仓库整合与文档迁移方案.md)
- [协作与工程约定](../../docs/01-协作与工程约定.md)

上述链接的相对路径以本文件所在目录为准。源码导入不代表手机端已完成模型接入，也不代表 Windows 网关已适配 OpenHarmony。

## 本地构建和测试

在 Windows 上准备 `global.json` 指定的 .NET SDK，从本目录执行：

```powershell
dotnet test LocalAIGateway.slnx -c Release -r win-x64 -p:SelfContained=true
```

该命令构建并运行自动测试，不安装正式网关、不调用真实模型。完整 Python/LiteLLM 运行包仍需按部署文档组装，不能把编译出的 CLI 当作完整安装包。命令使用已有 NuGet 配置和网络访问条件；依赖版本由 `Directory.Packages.props` 管理。

可在主仓库根目录核对导入基线：

```powershell
node scripts/verify-gateway-import.cjs
```

该校验用于首次导入的一致性。后续业务修改应明确记录相对上游的变更，再决定是否更新基线，不能通过改哈希隐藏未评审修改。

## 历史资料

`README.upstream.md`、`HANDOFF.md`、`PROJECT_MASTER_PLAN.md`、`PROJECT_STATUS.md` 和 `TECHNICAL_DECISIONS.md` 保留原文并增加历史标识。原作者机器路径、清理动作、分支规则、历史证据路径不构成当前环境的执行指令；尚未迁入的制品和报告不能视为本机可用。

上游 `.github` 工作流没有复制为嵌套工作流。主仓库 CI 已加入 `scripts/ci-gateway.ps1`，runner 的 .NET 环境和远端执行仍待确认，见 [持续集成说明](../../docs/deployment/持续集成.md)。安装、升级、卸载和设备脚本不随源码导入自动运行。
