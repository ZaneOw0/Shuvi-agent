# 原页标注与片段高亮阶段 5 最终验证报告

日期：2026-10-17。**最终状态：PASS，仅限本次 build-only 验证范围。T010 构建 PASS；T011 部署 PASS。** 本报告是当前简化增量唯一一次 `spec-verify` 的最终 authority，不重委派、不因失败重新调用验证。它不替代或覆盖历史 ROUND2 报告，也不表示 SC-007–SC-010 页面闭环已验收。

## 范围与初始化

- `PROJECT_ROOT=/Users/zane/DevecostudioProjects/Shuvi-agent`；原生 home 动态解析为 `/Users/zane`，`CONFIG_ROOT=/Users/zane/.local/share/deveco/`。已读取该根目录 `specs/commands/spec-verify.md` 并加载 `deveco-cli`。
- 直接使用提供的 `Confirmed_Feature_Dir=/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-pdf-ingestion/`，没有读取或改动 `spec/feature.json`。
- 先读当前 spec/plan/实施报告；指定的 `currenttasks.md` 不存在，文件名检索也未找到，因此以同目录 `tasks.md` 当前任务表为准。用户最新选择与 `<!-- verification_scope: build-only -->` 一致，只处理 T010/T011。
- 读取当前 context、总 spec、安全 capture 和正常 macOS 脚本，以及历史报告中公开的签名操作边界；没有执行历史验证 guard、任务、runtime suite 或旧授权。旧 journal/guard 保持原样，没有删除、改名或绕过。
- 当前源码编译无需修复，因此没有写 `.ets`，没有新增 SDK 调用，不需要为不存在的源码修复加载开发 skill 或搜索 SDK 文档。未新增依赖/权限，V1 与业务契约保持。

## 步骤结果

| 步骤 | 状态 | 实际结果 |
|---|---|---|
| 当前范围/保护基线 | EXECUTED | 保留全部既有脏工作区；不 scaffold、不做 Git 写入 |
| 只读目标清单 | PASS | device list、emulator list、device view 均 RC0；唯一活动 Mate 90 Pro / 127.0.0.1:5555，phone/API26 Release；其余三实例停止 |
| 17 文件 `arkts_check` | PASS，非制品 | 一次调用，`No errors found in 17 file(s).`，紧接实际 build；没有后续 checker |
| 实际 build 1 | PASS | 直接 `devecocli build --product default`，RC0；普通无签名模板下编译打包成功 |
| 编译修复/重试 | SKIPPED | 首次构建成功，源码修复 0、失败重试 0 |
| 实际 build 2 | PASS | 正常 `scripts/dev-run-mac.sh` 内部缓存签名 build，RC0；受限摘要记录 `BUILD SUCCESSFUL`，没有把脚本内部 build 算作 0 |
| T011 增量部署 | PASS，限 CLI 结果 | 同脚本仅一次 `run --skip-build --product default --device 127.0.0.1:5555`，RC0；无重建/重试/卸载/reset |
| 签名与模板 | PASS | 复用既有缓存，无 auth login/license acceptance/signature generate/force sign；模板前后 SHA 相同、工作区与 index diff 均 RC0 |
| Host/counter | REUSED | 无源码修改，未重跑；读取本增量实施阶段已落盘 host278/278、counter32/32，不能当本轮新测试或设备验收 |
| UI 准备/逐故事/Phase 2 | SKIPPED BY SCOPE | 不生成 UI 计划，不调用 verify_ui，不截图、不查看 UI、不运行设备 runtime probe |
| 产物与文档审计 | EXECUTED | 本机公开文件 SHA/字节数/调用计数落盘；更新本报告及当前任务/spec/plan/context/总 spec |

实际 Phase 1 step 1 build 总计 **2/10，2 成功、0 失败**；其中直接 build1、正常脚本内部 build1。实际部署 **1 次，RC0**；部署重建0，per-story build0。Checker1次，源码修复0，UI/截图/runtime/provider请求均0。每次实际 build 前均输出 `[BUILD_ATTEMPT]`，没有超出上限。

`[CODE_MODIFIED] initialized code_modified=false` 已输出；该标记只跟踪逐故事修复，本轮保持 false。Phase 2 按 build-only 不适用，输出 `[PHASE2_SKIPPED] reason=build_only`。本轮 Phase 1 的编译/部署结果是最终权威；不存在逐故事 PASS/FAIL/重试数，不能把跳过解读成页面通过。

## 输出与执行边界

首次 build 的原始输出被既有保守过滤器整体 withheld；保留 `run_cmd_exit=0` 和 capture 指纹，不读原始流、不旁路过滤来补诊断。第二次 build 的公开脚本阶段、受限摘要和实际制品相互对应。未报告 warning-free 或全量 lint 通过；没有观察到本轮编译错误、部署错误、超时或登录预检失败。

签名使用已安装独立 CLI `/Users/zane/.local/share/fnm/node-versions/v22.23.2/installation/bin/devecocli`；只在子进程移除 `DEVECO_CLI_AUTH_SOURCE`、`DEVECO_CODE_AUTH_DIR` 并设 `DEVECO_HOME=/Applications/DevEco-Studio.app/Contents`，沿用已记录的代理登录预检适配。本轮脚本预检直接通过，没有先失败再登录。Agent 未读取 `.local`、安全 Key、凭据、剪贴板、输入框、签名缓存/材料或私有 auth/sign 原始日志；仅正常脚本内部复用既有缓存。

新增 ignored 本机限制器 `.cache/result-pages-phase5-cli.cjs` 仅作用于**当前 result-pages 增量**，不替代旧 guard 或恢复旧授权。它只允许正常脚本需要的清单/登录预检、受限 build 和当前 serial 的一次 skip-build run；拒绝签名生成及其他命令，运行前再次验证唯一 device/emulator/view 映射并核对 freshly-built signed HAP SHA。读登录结果仅经原脚本私有输出；公共 journal 只存 operation/attempt/RC/time/制品摘要。限制器最终 SHA `6a1c049f54da5c2a98493174cc9ab3095e3d3cf97905073e0a74b418afa6cb74`。本轮 journal 已完成，禁止重跑/删除后续跑。

实际 signed build UTC `14:24:12.696–14:24:18.557`，run `14:24:20.039–14:24:23.344`；均 RC0、未超时。脚本与限制器均锁定 Mate 90 Pro / `127.0.0.1:5555`，无替代目标、模拟器重启或直接 HDC 命令。安装启动成功仅证明 CLI 部署结果，不证明进程持续健康、数据库迁移、当前343向量状态或页面表现。

## 17 文件最终清单

以下是交接的完整 checker 清单，**本验证对全部17文件均未修改，编译修复清单为空**。前16项相对 `entry/src/main/ets/`，末项为完整相对路径。

| 文件 | 最终 SHA256 |
|---|---|
| knowledge/domain/KnowledgeSearchModels.ets | `6a8ee3663daba4565f78b945c913bc16a09096fd55e26a902d860b3f7a5692e0` |
| knowledge/domain/PdfLocalModels.ets | `3561cf31ef845b437175e84fb887557d0c8310fc46edc26bc4d4dd72c9e1d7a1` |
| knowledge/domain/KnowledgePorts.ets | `4e396ef6c11b760d3e3904b5668bfa028f2f26d41d7faa937cfca98afb711c35` |
| knowledge/domain/TextKnowledgePorts.ets | `b28ca60f8e42048f4616c4e917d695f1f7e5229ef497c520ce89ad052ca1318a` |
| knowledge/application/PdfPageReferenceService.ets | `e3f3c51d746c866dfb48db00c9fae1f1b1a749e3a97be6a233fe62f24bc7146f` |
| knowledge/application/KnowledgeSearchService.ets | `dd066eac4bc8c8b3cc4ad2d5b9d05f5d881dc94aca87189eb0e64e6ebca0f590` |
| knowledge/pipeline/KnowledgeMatchPolicy.ets | `bfbdd89359cedbde2f73acb1876d7441ad245213403cd3e84690ee93c9270b47` |
| knowledge/pipeline/KnowledgeRetrievalPolicy.ets | `ca0b6307545ce767949aef0934641b6969b4f6ea6bcc970dd2639fa4728657e5` |
| knowledge/infra/PdfKnowledgeRepository.ets | `41bfa896d869013b1eafeb5cc4c73513c1898b9ba4270232519a14aec9571926` |
| knowledge/infra/TextRdbRepository.ets | `e8ce9f93ac6ac8991279a709a540e2dd8904ee61b8161172f2ff529b978c483c` |
| knowledge/infra/KnowledgeAssembly.ets | `c6e6bc44f7d27efa71372174a7c9c0377c25dfad96a1c0273d5e1b197709c564` |
| knowledge/infra/PdfPageAdapter.ets | `e3a94f11a20b7d1aeb471a0ce6dd77c2889af32664113b2ed2efaa198d6b06f7` |
| knowledge/ui/KnowledgeResultCard.ets | `777875c9546d99f46e28589b36b8cbfbd32ad25fc7496ab8f945ef17ee41e27f` |
| knowledge/ui/KnowledgeView.ets | `9ba996d870caded3bc07058aae01fefa797f595501b9cd556a9e3f0dc8343b66` |
| knowledge/ui/PdfSourceView.ets | `49cb2c43b15686366cbbb31c742d9f2e6feedec9c55d2972b5b0957d55bc3030` |
| pages/Index.ets | `baa2fc541f971ee30faf96b3ae18181167a144cc3f4dc81d8f7cc5cc29d72b1d` |
| entry/src/test/KnowledgeResultCases.ets | `0ed640f989856d5ec36cb2eaafbd5b2a34dd0d066137f4a5e49c5fd73363397f` |

这17文件按表顺序 `path + NUL + SHA256 + LF` 计算的集合 SHA：`bf181e1132b47a21ae4d439d42c6e5aa454f88a4a6c565633332c5e0e7f25258`。公共审计还记录各文件 mtime，全部早于实施最终 host。页证据资源10,633B，SHA仍 `d99055bb5e8005a73d2c085870cc4f5a405ef8ee59768d3354e8844e72faee39`；没有生产导入。

## 产物身份

product=`default`，module=`entry`，debug，bundle=`com.example.shuvi`，API26；HEAD仍 `9f5992c`/`dev/rag` 加既有未提交变更。当前 Node v22.23.2、Bash3.2.57；未升级工具链。

| 产物 | 字节 | SHA256 |
|---|---:|---|
| entry/build/default/outputs/default/entry-default-signed.hap | 4177165 | `8b6d26050b815e20553f9971a1d487a06d83b91a1e40889de494ebec6578ffd3` |
| entry/build/default/outputs/default/entry-default-unsigned.hap | 4116343 | `3c09ba82b4517d4e3ecaea8fabddb430b8f37ea2ebb279a4f6f210265b7bc39d` |
| build/outputs/default/Shuvi-agent-default-signed.app | 4132639 | `bd22eb36ef029485bb4e99c686f0afe3ad8edba1a3d0283ed8ecf58bd4409184` |
| build/outputs/default/Shuvi-agent-default-unsigned.app | 4117881 | `2814cd8b3a8aa44fd9030901947684996ec67903bc051674f446c293a23a1387` |

实际部署 HAP SHA 与 signed build/journal/最终文件一致。模板前后 SHA均 `36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`，最终模板 worktree/index diff0。签名材料本身未读。

## 证据与命令

以下目录统一位于 `.cache/test-logs/2026-10-17-<scope>-9f5992c/`，均由原 capture 以 `CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1` 独占建立并写 index。命令 RC 与设备日志 RC分离；所有 `log_exit=not-run`，有意不采设备日志。

| scope | 命令 RC | 证据 |
|---|---:|---|
| result-pages-phase5-target-01 | 0 | 只读 device/emulator list/view |
| result-pages-phase5-build-01 | 0 | 首次编译/打包成功元数据；输出被既有过滤器 withheld |
| result-pages-phase5-signed-deploy-02 | 0 | 正常缓存签名、内部build RC0、skip-build部署RC0 |
| result-pages-phase5-artifact-audit | 0 | 17文件/制品/模板/hash/actual calls，本机文件审计 |
| result-pages-phase5-closeout-audit | 0 | 文档结案后的本机公开文件复核；不重复build/run/tests |

build、签名部署及首次产物审计的公共 feature 指纹同为 `1bd6ac949b81d41cb5ac364cb843675744a35a81e0331d1a40a667c96db2e5c5`，dirty114。实施最终host指纹 `8915f8e135dfb152b60a293275c4a9572e9036c8eddf0ee2ae945d3ec1b6a308` 包含当时文档状态；实施报告已说明随后仅文档更新。本验证没有源码改动；结案文档会再改变 aggregate 指纹，源码集合 SHA不变。

复现命令仅作审计记录，**不是重跑当前已处理阶段或旧授权的许可**：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
DEVECO_HOME="/Applications/DevEco-Studio.app/Contents" \
RUN_CMD='devecocli build --product default' \
/bin/bash scripts/capture-test-log.sh result-pages-phase5-build-01

CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='env -u DEVECO_CLI_AUTH_SOURCE -u DEVECO_CODE_AUTH_DIR DEVECO_HOME="/Applications/DevEco-Studio.app/Contents" DEVECOCLI_BIN="$PWD/.cache/result-pages-phase5-cli.cjs" /bin/bash scripts/dev-run-mac.sh --device 127.0.0.1:5555 --emulator "Mate 90 Pro" --no-emulator --product default' \
/bin/bash scripts/capture-test-log.sh result-pages-phase5-signed-deploy-02 30m 127.0.0.1:5555

CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='node .cache/result-pages-phase5-audit.cjs' \
/bin/bash scripts/capture-test-log.sh result-pages-phase5-artifact-audit 30m 127.0.0.1:5555
```

Checker文字记录 `.cache/arkts-check/result-pages-phase5-initial.txt`；公共调用摘要 `.cache/result-pages-phase5-public-summary.json`，journal `.cache/result-pages-phase5-cli-events.jsonl`。未读取脚本私有 build/auth/sign/run 原始输出。

沿用实施证据：`result-pages-host-final-08` 为 **278/278、RC0、72.732090583s**（旧257+21，fail/cancel/skip/todo0）；`result-pages-counter-01` 为 **32/32、RC0、450.64425ms**。完整路径与复现命令见实施报告；本轮没有源修复，不重复host/counter，也不删原测试/golden。

## 未验范围与存量保护

C1–C3均没有本轮 UI 测试状态。静态来源对齐仍只引用实施证据：292受审文字nodes覆盖343块、5块跨页；5空nodes与原页30未绑定。**生产页证据登记、真实Span高亮/历史UI、原件已核页跳转、新无direct相似查询、SC-007–SC-010页面/真实similar衔接均未执行**，不以build PASS冒已验。未运行完整16题、region overlay、LLM、真机或压力测试。

本轮未执行上传/解析/重向量化、models/probe/corpus/query、provider请求、生产查询/页导入/设备库读回或任何runtime探针；全部旧外发授权保持耗尽。没有索取新的授权，没有模拟结果代替真实相似。

文档/content/snapshot/report/vector generation/space/readbackSet身份与343keyword/64图/M1history16/KBhistory9/qualitycached24继续按实施报告的**历史基线**保护，本轮未重新读库验证。未修改normalizer/chunker/snapshotwire/embedInput/vector空间，未主动清理任何原件/ZIP/历史/用户数据；部署引发的应用启动不等这些运行时状态已被验证。

## 最终审计与结论

本轮手动改动仅为本报告、当前tasks/spec/plan/context/总spec状态和ignored本机限制器/审计/文字证据；业务17ets修复列表为空。`git diff --check` 只作格式检查，不作为构建或功能验证。无 commit/push/Git配置写入，无 auth login/license acceptance/signature generate/强签/卸载/reset/HDC写入；不读私人paste脚本/凭据/签名/私有raw。没有超限或重复Phase5调用。

**T010 PASS，T011 PASS；最终 PASS（严格限定本次 build-only）。** 当前简化增量源码与制品已构建并部署，页面与生产来源/真实相似链仍未验收；任务勾选表示本验证已处理，不是 C1–C3/SC-007–SC-010全通过。报告结论最终，不再次 spawn/reinvoke 验证。
