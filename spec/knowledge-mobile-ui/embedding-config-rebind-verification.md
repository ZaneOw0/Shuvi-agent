# 嵌入配置绑定失效与重新确认修复

日期：2026-10-27。分支：`dev/rag`，基线 `f8561ea`。状态：已实现，最终宿主回归、构建、模拟器保数据部署与设置界面检查通过；7 个业务文件独立 ArkTS 检查通过，入口页由实际构建验证。真实模型恢复待用户确认，未做真机验收。

## 用户流程

保存相同嵌入配置保留原版本和检测、自动入库确认。实际修改配置或保存 / 删除 Key 时，先持久化自动入库确认失效，再进行配置或安全存储操作。重新打开应用会核对旧设置绑定，不自动继承旧确认。用户在「我的 → 嵌入模型 → 自动入库」确认范围、可能费用和当前配置基准后，点击「重新确认并恢复自动入库」。

## 页面事项

- 绑定失效显示「配置或 Key 已变化，自动入库已暂停」，并清除旧版本勾选。
- 重新确认入口直接恢复当前配置的自动入库；配置保存中或重复提交时禁用。
- 配置阻塞任务显示「等待重新确认配置」，输入数量错误单独提示。
- 保留鉴权诊断、未知结果及可能重复计费提示。
- 修复首次从「我的」打开嵌入设置时的异步刷新：配置服务仍为普通引用，用显式 `embeddingOpening` 状态显示加载，并在完成 / 失败后刷新页面，防止成功加载后仍显示未就绪。

## 业务与 Agent 事项

- 失效确认不复制 Key、不自动更新许可绑定；新绑定只在用户确认后写入。
- 启动时将输入完整且无 InFlight / Unknown 请求的旧配置失败任务转换为 AwaitingConfig；无关失败、未知任务及本机迁移任务不自动重发。
- 保留固定输入、已完成计数、向量及请求回执；相同绑定下复用已核向量，已发送任务换配置时保留旧任务并使用新向量世代。
- 配置 / 许可失效持久化失败时停止本次配置、凭据写入。每段输入与发送前继续检查配置，防止中途变更后沿用旧确认。

## 平台能力

沿用现有 HarmonyOS API、三库及安全存储实现；没有新增依赖、权限、服务、数据库版本或系统能力。已有数据保留，不卸载或清库。构建部署仅使用已匹配模板的本机签名缓存，模板由现有所有权锁与恢复工具保护，不执行 Git 写入或远端操作。

## 验收方式与证据

最终宿主回归 **185/185**；使用合成数据、内存文件 / SQLite、受控传输替身，真实业务请求和私有文件读取均为 0。新增 11 项覆盖：相同配置保存、配置变化及再次确认、凭据修订、旧失败任务重启恢复、未知结果不重发、错误分类、界面旧确认清除、处理中途配置变更保留向量、确认失效持久化失败、首次打开异步加载及失败释放加载后可重试。正常、拒绝确认、模型未知结果和存储 / 输入异常均覆盖；宿主结果不等于真实平台或模型质量通过。

- 最终宿主：`.cache/test-logs/2026-10-26-embedding-config-rebind-entry-host-f8561ea/`；此前仅配置链路版本 183/183 为 `.cache/test-logs/2026-10-26-embedding-config-rebind-final-host-f8561ea-2/`。
- 7 个业务修改文件 ArkTS 独立检查：`.cache/test-logs/2026-10-26-embedding-config-rebind-final-check-f8561ea-2/`，RC 0。
- 增加入 `Index.ets` 的 8 文件独立检查：`.cache/test-logs/2026-10-26-embedding-config-rebind-entry-check-f8561ea/`，RC 1。检查器无法解析既有生成模块 `BuildProfile`，分别影响 Index、FeaturePages、RuntimeStartupCheck、DirectModelCheckService、McpConnectionCheckService 的 5 处既有导入；未添加占位模块或修改这五处导入。最终实际构建 `CompileArkTS` 与 `SignHap` 均成功。
- 初次宿主有一项 UI 测试依赖未隔离；中间最终回归有一项历史 401 提示顺序回归，修正后上述最终回归全部通过；失败日志保留。
- 最终构建 / 部署：`.cache/test-logs/2026-10-26-embedding-config-rebind-final-build-deploy-f8561ea/`，build / run / 设备日志均 RC 0。复用匹配模板的本机签名缓存，模板字节恢复、Git diff 0、所有权锁已释放。安装后应用进程存在；首次构建为 `.cache/test-logs/2026-10-26-embedding-config-rebind-build-deploy-f8561ea/`，首次设置检查 `.cache/test-logs/2026-10-26-embedding-config-rebind-ui-confirmation-f8561ea/` 如实记录到异步未就绪界面，之后修复入口刷新并重新构建。
- 最终 signed HAP：12,158,977 字节，SHA-256 `4c443458aaa51fbee20944116686e49c71f115decea8fdf7bcff0128c61332c9`；构建部署 capture 工作区指纹 `9110de191773eccdbddc756d8708294e400c60258aa59cbe94e5f8d7bf1b5088`。此后仅本机验证驱动 / 文档更新，源码未变。
- 最终界面：`.cache/test-logs/2026-10-26-embedding-config-rebind-final-ui-f8561ea/`，命令与设备日志均 RC 0；复现驱动为同一 `verify.cjs final-ui`，通过应用菜单 → 我的 → 嵌入模型进入，无需再次打开页面。布局确认 `upd-embedding-config-changed` 与「重新确认并恢复自动入库」可见，截图 `.cache/embedding-config-rebind/final-embedding-settings.png`。两项确认均未勾选、确认按钮禁用；应用留在此页。
- 设备只读结果：原 6 个配置失败任务均为 `AwaitingConfig / UnifiedConfigChanged`，包括截图原 0/5 正文任务；总任务 29 不变、请求准入记录 13 不变、未知任务 0。自动入库 enabled / baseline 为 0，未代用户重新授权、未导入新资料或触发模型探测 / 语料 / 问题请求。真实向量入库成功不能由上述结果推定。
- 保数据部署复现：`RUN_CMD='"/d/Huawei-DevEco-Studio/DevEco Studio/tools/node/node.exe" .cache/embedding-config-rebind/verify.cjs deploy' DEVECOCLI_BIN='C:/Users/Zeto/.cache/deveco/bin/devecocli.cmd' /c/Univ/Git/bin/bash.exe scripts/capture-test-log.sh embedding-config-rebind-build-deploy 5m 127.0.0.1:5555`。该本机驱动仅在 gitignore 的 `.cache/`；内部调用现有 `dev-run-support.cjs` 执行模板校验、所有权锁、签名缓存与恢复，随后 `devecocli build --product default --modules entry` 成功才执行 `devecocli run --skip-build --device 127.0.0.1:5555 --module entry --product default`，不安装依赖、不生成新签名或修改 Git 配置。

目录日期由 UTC 生成，故前缀为 2026-10-26；本文日期按 Asia/Shanghai。

宿主复现（Git Bash，使用现有 SDK 与 Node，不安装依赖）：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
DEVECO_SDK_HOME='D:/Huawei-DevEco-Studio/DevEco Studio/sdk' \
RUN_CMD='"/d/Huawei-DevEco-Studio/DevEco Studio/tools/node/node.exe" entry/src/test/run-host-tests.cjs --unified-only' \
/c/Univ/Git/bin/bash.exe scripts/capture-test-log.sh embedding-config-rebind-final-host
```

设备人工验收：进入自动入库设置，核对配置变化提示；由用户本人确认当前发送范围与可能费用，观察原 0/5 正文任务恢复。涉及真实模型请求的重新确认不由 Agent 代为执行。本轮构建部署与后续模型真实成功分别记录。
