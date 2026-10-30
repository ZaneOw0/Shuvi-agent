# Windows 模型网关设计

## 1. 位置与用途

`services/local-ai-gateway/` 是独立 Windows x64 / .NET 网关，保留固定来源、模型传输、认证、运行时管理与测试。当前手机主助手直接连接 DeepSeek，联网搜索直接连接 Tavily；网关不是该链路的前置进程。

## 2. 架构边界

网关通过本机服务接口连接客户端与模型运行时，安装级客户端令牌和供应商 Key 分别管理。Windows Credential Manager、Named Pipe、Mutex 与进程管理属于当前实现，移植为远端服务或 OpenHarmony 能力须单独设计。

entry 不引用 .NET 工程、不打包 Python 运行时。Agent 的模型传输端口保留注入能力，使用网关时仍需配置实际模型目录、价格与凭据，并验证请求/响应协议及取消。

## 3. 来源与交付

来源固定 `21017a1e91a1067119f4772762295c3e343cef40`，UPSTREAM.json 保存逐文件哈希与授权记录；网关自带 LICENSE、第三方声明和运行时清单。源码可构建不代表完整私有运行包已装配、安装或真实模型已验收。

[部署说明](../deployment/Windows模型网关.md) 管理本机操作，[子项目 README](../../services/local-ai-gateway/README.md) 提供入口。历史技术决策原文保留来源标记，当前主仓库规则见 [协作约定](../01-协作与工程约定.md)。
