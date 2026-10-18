# OCR=false 修复：Studio 工具链补充部署记录

日期：2026-10-18。HEAD：`a9092f0`。用户在此前验证结案后明确要求使用已确认的 Studio 工具路径重新部署，功能流程由用户手动验收。本记录是该授权下的独立部署操作，不重写或重新委派此前唯一 spec-verify；旧 `ocr-profile-fix-verification.md` 中登录预检失败与 INCOMPLETE 结论保留为当时事实。

## 当前结果

**重新构建、缓存签名及增量安装启动 PASS，实际用户流程待手动验收。**

| 项目 | 实际结果 |
|---|---|
| CLI | `/Applications/DevEco-Studio.app/Contents/tools/node/bin/devecocli`，1.3.5 |
| Node | `/Applications/DevEco-Studio.app/Contents/tools/node/bin/node`，v24.14.1 |
| 目标 | 重新枚举核对唯一运行 Mate 90 Pro，`127.0.0.1:5555`，API26 |
| 静态检查 | 当前14个修复 `.ets` 再次 arkts_check，一次无错误，紧接本次构建 |
| 登录预检 | 正常脚本确认已登录；没有再次 login/logout |
| 签名 | 正常脚本内部复用既有缓存，没有 signature generate/force-sign，Agent未读取材料 |
| 实际构建 | 脚本内部 `devecocli build --product default` 1次，RC0，无编译失败/修复 |
| 增量部署 | `devecocli run --skip-build --product default --device 127.0.0.1:5555` 1次，RC0 |
| 数据处理 | 不点击恢复/重试/批准/发布/向量化，不清库/卸载/reset，不读取生产库或凭据 |
| 业务云请求 | 没有 MinerU/models/probe/corpus/query/quality 请求；CLI登录态校验与构建部署不当业务云外发 |

本次 CLI 与 Node 不升级。只在部署子进程移除 Agent 认证来源覆盖与大小写代理环境变量；不修改系统/IDE/全局代理或工具配置。先前受控对照中，同一 Studio CLI 保留代理时无登录标志，子进程移除代理后出现 `Current user:`；未将账号原文写入上下文或公共日志。

## 制品与保护核验

- signed HAP：`entry/build/default/outputs/default/entry-default-signed.hap`，**4,234,534 B**。
- SHA256：`6add1061167cb02e63ee172cc78af17f7c8f7f74b1a284c9a8bab22413456d2d`，与实际部署前记录相同。
- 14个修复源文件集合身份：`b9b022831d281dfeb2767cfa1d14c6c98ee093bd48a6310bb414e09d28bbf541`；准备至安装后摘要相同，本次无应用源码修改。
- 签名模板前后 SHA256：`36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`；模板工作区与暂存区 diff 均为0。
- 保留已有未提交修复及无关 untracked，没有 Git commit/push、没有改动旧请求 guard/journal。
- 未读取 `.local`、Key、签名/认证原始输出或用户PDF正文。正常部署脚本内部使用缓存的行为与 Agent直接读取材料不同。
- 没有设备生产读回，因此旧343向量/历史/新失败候选等只按代码与部署方式保护，不冒称本次已逐项核验当前数据库状态。

本轮专用 ignored 限制器 `.cache/studio-ocr-deploy-20261018-cli.cjs` 固定 Studio Node/CLI，仅允许脚本所需的只读清单/登录态、1次default构建和1次指定serial的skip-build部署；签名生成和其他操作拒绝。状态文件记录实际次数与制品，当前授权已处理，不删除状态文件重跑。

## 证据与复现记录

本轮日志使用安全host模式，仅采部署脚本的公开阶段/退出码与本机摘要；默认设备日志刻意未采。准确目录均在 `.cache/test-logs/`：

- `2026-10-18-ocr-fix-studio-deploy-preflight-01-a9092f0/`：源码/模板摘要及本次操作限制，RC0。
- `2026-10-18-ocr-fix-studio-signed-deploy-01-a9092f0/`：登录成功、缓存复用、构建成功、安装启动成功，RC0。
- `2026-10-18-ocr-fix-studio-deploy-audit-01-a9092f0/`：build1/run1均0、artifact对应、source未改/template恢复，RC0。

构建部署时公开功能指纹：`f5d6eaaff2024b28491cd3c42785a3f3edab7e8aac97d3085a2fb78384982bf2`。meta 中 Node v22.23.2 是 capture 的父进程；实际受限部署子进程明确使用 Studio Node v24.14.1，不混同工具来源。

以下为本次实际命令记录，不是重复执行已完成限制器或恢复旧外发授权：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='env -u DEVECO_CLI_AUTH_SOURCE -u DEVECO_CODE_AUTH_DIR -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY -u http_proxy -u https_proxy -u all_proxy -u no_proxy PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH" DEVECO_HOME="/Applications/DevEco-Studio.app/Contents" DEVECOCLI_BIN="$PWD/.cache/studio-ocr-deploy-20261018-cli.cjs" /bin/bash scripts/dev-run-mac.sh --emulator "Mate 90 Pro" --device "127.0.0.1:5555" --product default --no-emulator' \
/bin/bash scripts/capture-test-log.sh ocr-fix-studio-signed-deploy-01 1s 127.0.0.1:5555
```

## 手动验收交接

1. 优先使用已收 ZIP 的《机器学习3线性模型.pdf》，无需重新上传解析或输入 Key。
2. 在“知识库 → PDF 本机任务”刷新，选择该件现有 Failed/Paused 任务的“原 ZIP 重试/恢复”，不要为测试再点“新 attempt 重建”。此前当前attempt3任务为 `kb-4dd55b5a630d1479a70ec5a5a5db913f`；页面实际状态以当前刷新结果为准。
3. 预期本机解包、规范化、图片与快照完成后进入 `AwaitingCoverageReview`。Host已证这份包有33个页脚排除及19个空文本项，报告应如实展示；它们不等于本轮 OCR profile 硬失败仍在。
4. 用户审查报告后自行决定是否确认“部分可用”及发布关键词。结构审查、关键词发布、文档向量化是不同阶段；本次部署没有代用户执行任何一步，也没有授权后续自动外发。
5. 若仍Failed，保留原件/ZIP/任务，记录页面具体 `category / stage` 和数字码；不要通过重复上传、清库或反复新建attempt掩盖原因。

本修复明确覆盖已观察的同 `3.4.4 / hybrid / medium` 协议OCR布尔true/false变体，不保证任意未来协议、损坏ZIP或预算超限结果必然通过。新包真实TaskPool、ImageKit、Review及发布仍由用户手动验收，当前仅安装交付完成。
