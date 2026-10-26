# Windows 模型网关设计

> 状态：已实现待验收（主仓库迁移）。
> 更新日期：2026-10-23。
> 适用范围：`services/local-ai-gateway/`，来源 `21017a1`；不声明 OpenHarmony 端侧可运行。

## 1. 背景与选择

Shuvi 需要模型通信能力；当前 Agent 适配器可连接 Windows 本地网关。此次选择将网关作为独立子项目纳入主仓库，复用已有实现、测试与部署材料，保持应用与网关分别构建。

代价是继续需要 Windows 环境和独立运行包；目录整合不解除手机对开发电脑的依赖。正式版采用设备直连模型、团队远端后端还是其他部署方式，仍需团队确认。

## 2. 请求路径与模块

```text
客户端 / Agent HTTP 适配器
  → Windows 回环地址 127.0.0.1:4000
  → .NET 网关：认证、路由、请求限制与用量
  → 私有 Python / LiteLLM：随机内部回环端口
  → 配置的模型供应商
```

| 模块 | 职责 |
|---|---|
| Core | 配置、模型与路由、限制、错误及运行生命周期合同 |
| Runtime | HTTP 代理入口、控制面、健康状态和运行管理 |
| LiteLlm | 私有后端配置生成、启动、探测与排空 |
| Windows | Windows 凭据、文件访问控制、进程和安装等适配 |
| Cli / Launcher | 命令入口、客户端启动和子进程环境注入 |
| Tray / Updater | Windows 托盘、用量展示、升级和卸载辅助 |

公开端点包括 `/health`、`/ready`、`/v1/models`、`/v1/chat/completions`、`/v1/responses`、`/v1/messages`。就绪检查同样受认证保护。基址相同不代表模型能力和请求参数完全兼容。

## 3. 凭据与运行边界

- 客户端访问网关使用安装级令牌，模型供应商 Key 由网关管理；搜索 MCP 的凭据另行配置。
- Windows Credential Manager、Named Pipe、Mutex 和进程管理是当前实现的一部分，不能仅修改监听地址便视为远端服务器部署完成。
- 运行时模型别名由活动 Profile 映射；应用侧必须对齐模型版本、能力、用量和价格，不填假值绕过初始化。
- 失败、取消、有限重试和流式输出行为以源码和对应测试为准；不能把 Node 文本探针结果等同于 ArkTS Planner 请求兼容性。

## 4. 与主仓库的关系

Shuvi `entry` 不引用 .NET 项目、不打包 Python 运行时；Agent 通过模型传输接口连接服务。网关不持有 ArkUI 页面，也不替代端侧授权或本地工具权限检查。

整合后的协作和发布规则以 [01 协作与工程约定](../01-协作与工程约定.md) 为准。旧决策详见 [上游技术决策原文](../../services/local-ai-gateway/TECHNICAL_DECISIONS.md)，其中阶段计划与旧机器操作记录是历史背景，不覆盖主仓库规则。

## 5. 证据与限制

来源提交、逐文件哈希和授权确认记录见 [UPSTREAM.json](../../services/local-ai-gateway/UPSTREAM.json)。迁移后的构建结果和部署限制见 [部署与验证](../deployment/Windows模型网关.md)。Windows 专属实现尚未移植；模型正式部署和目标 OpenHarmony 兼容性仍待确认。
