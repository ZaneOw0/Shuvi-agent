# 启动与日志脚本

本目录提供本机开发入口，使用已有 Git Bash、Node、Git、devecocli 和配套工具链。账号登录、模拟器许可与镜像准备由用户完成；脚本不配置 Git、不卸载应用或清用户资料。

## 1. 启动与重新部署

```powershell
# Windows，使用当前运行的唯一设备，重新构建并覆盖安装
.\scripts\dev-run.cmd --no-emulator
# 指定设备，避免多设备歧义
.\scripts\dev-run.cmd --device '<serial>' --no-emulator --product default
```

```bash
scripts/dev-run.sh --help
scripts/dev-run.sh --emulator '<完整实例名>' --product default
scripts/dev-run.sh --device '<serial>' --no-emulator --product default
scripts/dev-run-mac.sh --device '<serial>' --product default
```

| 参数 | 含义 |
|---|---|
| --device | 显式设备序列号 |
| --emulator | 完整模拟器实例名 |
| --product | 产品，默认 default |
| --no-emulator | 不启动停止态模拟器，使用已经运行的实例 |
| --no-build | 跳过构建，需已有有效产物；验收最新改动时不使用 |
| --force-sign | 显式要求重新生成签名材料时使用 |

环境变量：EMULATOR_NAME、PRODUCT、DEVECOCLI_BIN。Windows 包装器定位 Git for Windows Bash，不使用 System32 的 WSL bash。macOS 使用独立 `dev-run-mac.sh`，包含登录态与镜像/许可预检。

## 2. 目标与签名

显式目标优先；device 与 emulator 同时提供时需证明同一实例。清单解析失败或映射矛盾停止，不回退到其他设备；启动后核对目标 serial 就绪，run 带相同 product 和 serial。构建失败不安装。

根 build-profile.json5 为无签名模板。运行前检查模板与本机锁/备份，拒绝覆盖用户编辑。签名缓存在 `.local/`，按实际模板哈希和产品匹配；签名、构建与安装使用同产品。

目录锁 `.local/dev-run.lock` 与本轮备份共同保护临时装配。退出时停止子进程、恢复并核对模板字节，再清自身文件；外部改动或恢复失败保留备份与锁供人工核对。断电等强制终止后不自动清理不明锁。

签名和账号工具原始输出保存在私有本机位置，公共输出只提供阶段、退出码和类别。首次登录、接受模拟器协议和下载镜像由用户自行完成，脚本不代为同意。

## 3. 日志入口

```bash
# 构建 / host，不读取设备日志
CAPTURE_HOST_ONLY=1 RUN_CMD='devecocli build' bash scripts/capture-test-log.sh build
# 应用运行后抓取指定设备日志
bash scripts/capture-test-log.sh device-smoke 10m '<serial>'
```

`capture-test-log.sh <scope> [窗口] [设备]` 先运行显式 RUN_CMD，再取设备日志；CAPTURE_HOST_ONLY=1 跳过设备。结果写入 `.cache/test-logs/<日期>-<scope>-<commit>[-序号]/`，包含 host/device 日志、meta.txt 和 index.tsv。

元数据记录分支、提交、脏文件数、工作区指纹、设备、命令/日志各自退出状态与模板状态。命令失败优先传播原退出码，日志、元数据或索引失败也非零；host-only 不作为设备日志成功。

公共输出保守过滤秘密标记，原始临时流仅清理本轮所有目录。不把私有账号/签名命令交给 RUN_CMD。结果和复现命令写入对应验收记录，功能 spec 链接该记录。

## 4. 故障定位

- 目标未就绪：核对实际实例名、镜像准备、许可和 hdc serial，不创建替代实例或切换其他设备。
- 登录或签名失败：按工具提示由用户处理，不盲重签或替换安装签名。
- 安装停滞：核对设备与 hdc 会话状态；签名不一致时保留用户资料，不卸载绕过。
- 模板恢复失败：保留本轮备份和锁，先核对原字节及外部修改。

## 5. 隔离回归与 CI

```bash
TEST_BASH=/bin/bash node --test scripts/tests/dev-run-mac.test.cjs
```

脚本测试使用自己创建的临时 fixture、假 CLI 和非密钥模板，不访问真实账号、设备或签名。不同平台分别验证，不将 Bash 合同测试扩大为所有 Windows 环境通过。

启动脚本不自动设置 hooks。`scripts/hooks/pre-push` 用于检查签名配置；配置 hooksPath 是独立授权的 Git 操作。CI 入口和环境见 [持续集成](../docs/deployment/持续集成.md)，CI 不签名或安装。
