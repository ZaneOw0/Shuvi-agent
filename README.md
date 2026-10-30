# Shuvi（休比）

休比是面向 HarmonyOS 手机和平板的智能个人助理，使用 ArkTS / ArkUI 开发。当前处于真实能力整合与验收阶段，完整发布、目标 OpenHarmony 兼容性和真机矩阵尚待完成。

## 当前能力

- **主助手**：设备直连 DeepSeek，支持文字、图片、普通话语音与补充文字；模型在统一工具循环中选择回答、文档操作或日程提议。
- **日程**：生成可编辑草稿，经用户确认写入系统日历并读回；工作台支持手动填写、列表与操作核查。
- **联网搜索**：手机直连 Tavily，用户开启本对话授权后，模型按需搜索并列出网页来源。
- **知识库**：TXT/MD、PDF、图片与 DOCX 的分阶段处理，统一 L0 关键词、L1 语义检索和主助手 L2 引用回答；资料、图片、来源预览与处理任务分页。
- **历史对话**：本机保存普通模型记忆、消息与图片副本；知识库上下文按授权会话隔离。
- **响应式界面**：同一 HAP 适配手机与平板，支持抽屉/常驻侧栏、窗口变化与应用内浮动入口。

知识库解析、图片理解、向量化和回答分别按授权联网。独立搜索 MCP 与 Windows 网关源码保留在仓库，当前手机主链路直接连接供应商。演示模式与真实模式分别标识。

产品目标与未实现范围见 [项目总览](docs/00-项目总览.md)，验收等级与限制见 [项目进度](docs/08-项目进度与验收.md)。

## 快速开始

准备 [平台基线](docs/02-平台基线.md) 对应的 DevEco Studio、SDK 与 `devecocli`。账号登录、模拟器协议和镜像准备由用户在本机完成，凭据与签名材料不入库。

```powershell
# Windows：重新构建、覆盖安装并启动到正在运行的唯一设备/模拟器
.\scripts\dev-run.cmd --no-emulator
```

```bash
# Git Bash：明确指定当前设备
scripts/dev-run.sh --device '<serial>' --no-emulator --product default
# macOS 使用独立入口
scripts/dev-run-mac.sh --device '<serial>' --product default
```

脚本复用本机签名缓存并恢复工程模板，不卸载或清用户资料。命令、签名、设备选择和日志规则见 [脚本说明](scripts/README.md)。

## 仓库结构

| 路径 | 职责 |
|---|---|
| `entry/`、`AppScope/` | HAP、页面、应用服务、平台适配与应用配置 |
| `modules/harmony_agent/` | 八个 Agent HAR；产品使用原六模块及 native_tools，agent_testkit 用于独立测试 |
| `services/` | 独立搜索 MCP 与 Windows 模型网关，不进入 HAP |
| `tests/agent-host/`、`tools/agent/` | Agent 测试宿主与固定样例工具 |
| `scripts/` | 启动、日志、来源核验与 CI 入口 |
| `specs/` | 当前功能契约及模板 |
| `docs/` | 规则、架构、接口、操作指南、诊断与验收记录 |

## 开发与验证

按 [协作约定](docs/01-协作与工程约定.md) 开发：先读相关契约，保持依赖方向，修改 ArkTS 后执行检查与构建。测试逐次落盘，构建、host、模拟器与真机分别记录。

当前工作分支 `fix/patch` 用于发布前小 bug、补丁和仓库规范工作。Git 提交、推送、合并与分支清理遵守用户授权及 PR 规则。

- [功能索引](specs/README.md)
- [文档导航](docs/README.md)
- [Agent 架构](docs/architecture/Agent运行时架构.md)
- [持续集成](docs/deployment/持续集成.md)

## 许可

主项目采用 [MIT](LICENSE)。Agent 模块保留其 Apache-2.0 声明与来源清单；Windows 网关保留自身许可证、第三方声明和来源授权记录。许可范围见各子项目 README。
