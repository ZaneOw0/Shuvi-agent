# OCR profile / worker 最小修复验证报告

日期：2026-10-18。HEAD：`a9092f079532e3f4d0a4a302527ffc1d87f62eec`。本轮 Phase 5 仅执行一次，不重新委派或 reinvoke。

## 权威结论

**Authoritative Final Status：INCOMPLETE**，适用范围仅当前 T007/T008 的 `build-only`。T007 构建 **PASS**；T008 已处理但部署 **INCOMPLETE**。正常缓存签名脚本在登录预检停止，未进入缓存签名合成、第二次实际构建或 `run --skip-build`。不能将本报告解释为新33页PDF已恢复到Review、真实TaskPool错误已验证，或用户问题已在模拟器消失。

用户指定的 PROJECT_ROOT 为 `/Users/zane/DevecostudioProjects/Shuvi-agent`，Confirmed_Feature_Dir 为本目录；CONFIG_ROOT 经系统原生HOME解析为 `/Users/zane/.local/share/deveco/`。已读取该目录 `specs/commands/spec-verify.md`，本feature当前 `tasks.md`（不是currenttasks.md）、spec B1/B2、FR-042–048/SC-011–014、plan F1–F4/F-K1–3及完整实施报告。`<!-- verification_scope: build-only -->` 明确有效，无UI计划生成、故事验证或Phase 2。

## 逐步结果

| 步骤 | 状态 | 本轮实际结果 |
| --- | --- | --- |
| 初始化/范围 | executed | 只T007/T008；加载deveco-cli及hmos-arkui-develop-skill，无源码修改，无需新增SDK API |
| 目标清单 | executed / PASS | 两次capture readonly device/emulator list/view均唯一活动Mate 90 Pro，127.0.0.1:5555，phone，API26；其它三个实例停止，不启动 |
| arkts_check | executed / PASS | 指定14ets一次，`No errors found in 14 file(s).`，紧接首轮build；checker不产生制品 |
| Phase 1 step 1 | executed / PASS | 实际1/10次 `devecocli build --product default --modules entry --build-mode debug`，RC0，`BUILD SUCCESSFUL in 5 s 265 ms` |
| 编译修复/重试 | skipped | 首构建成功；源码修复文件0，失败build0，未再checker |
| 缓存签名部署脚本 | failed / 环境阻塞 | 原 `scripts/dev-run-mac.sh` 调用1次，RC1；公共提示登录预检未通过，停止于设备/缓存签名/构建/run之前 |
| `devecocli run --skip-build` | skipped / INCOMPLETE | 实际调用0次；当前只有unsigned HAP，无可安全部署signed制品；不登录/新签/强签/卸载绕过 |
| host/counter | 引用实施证据 | 本轮源码未改，重测0次；不把既有299/299、32/32说成本轮执行 |
| UI准备/故事/修复循环 | skipped | build-only且用户禁止，无verify_ui、截图、点击、恢复、运行时探针；B1/B2不记页面PASS |
| Phase 2 | skipped | build-only，`code_modified=false`；Phase 1结果为本报告权威结果 |

脚本公共提示为“未登录华为开发者账号。请先执行：devecocli auth login”。这里只证明原脚本未获得其要求的登录态预检标志，不推断凭据已失效或账号真实状态；没有查看认证或签名原始输出。按批准边界停止，不执行提示中的login。第一次脚本尝试前曾输出预留 `[BUILD_ATTEMPT] attempt=2/10`，但预检阻塞没有触发该build，**实际计数仍1**，不记第2次失败构建。

## 调用计数与限定改动

- `build_fix_attempts` 实际 **1/10**：初始build1、编译retry0、脚本内部signed build0；build与run均有本轮独立事件账本，未复用旧guard/journal。
- 正常签名部署wrapper调用1次（RC1）；实际 `run --skip-build` **0次**，安装/启动0次，部署重试0次。
- `code_modified` 初始化false且未改变；源码/测试/权限/依赖/SDK/数据库布局/类型及白名单规则均未修改。T007构建成功不要求放宽失败字段、成功payload、CRC或预算。
- 新增仅本轮ignored审计文件：`.cache/ocr-fix-phase5-20261018-cli.cjs`、`-events.jsonl`、`-checker-result.json`、`-audit.cjs`。限制器只允许固定build、skip-build run及原脚本必需的只读inventory/auth status，禁止签名生成和额外命令；独立CLI固定为用户指定已安装路径，不改工具配置。
- 受检14ets集合SHA256：`66b1c2e209e66261428f102de8842358c1ddf91725f4865cba909f0a2db16b03`。精确列表沿用实施报告，包含PdfWorkerModels/PdfWorkerPolicy及main/test两处PdfWorkerCases。
- 手动文件编辑仅apply_patch。保留父agent已有spec/plan/tasks修改及无关paste/e2e，未读或运行后者；没有Git commit/push/reset/checkout等写操作。

## 制品与模板

| 项目 | 本轮实际值 |
| --- | --- |
| unsigned制品 | `entry/build/default/outputs/default/entry-default-unsigned.hap` |
| 大小 | **4174557 B** |
| SHA256 | `8e6443dcffc5dd14485145a0c5d1922c5aabfab2e96849e2bb803f1af0421000` |
| signed制品 | 当前输出目录无 `entry-default-signed.hap`，未部署 |
| 模板前/后SHA256 | `36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`，精确相同 |
| 模板工作区/暂存区diff | 均0；脚本在合成之前停止，未进入签名模板替换，不冒称已完成缓存签名/恢复流程 |
| build/脚本/制品审计时点指纹 | `9b6a57d9a7c78edf607f332c3dec9d3d14735aef34e680931a9da69c1c64a302` |

指纹为capture的public-feature-host-only范围，排除无关脚本、私有目录和签名配置；不是生产库或完整工作区内容的保持证明。后续仅本报告与进度文档新增，构建时点指纹不回填为文档收尾指纹。

## 本轮证据

所有以下目录前缀 `.cache/test-logs/2026-10-18-`、后缀 `-a9092f0/`，均独占capture，`CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1`；`log_exit=not-run`，未采设备日志或runtime。

| scope | cmd_exit | 内容 |
| --- | --- | --- |
| ocr-fix-phase5-target-01 | 0 | 构建前只读清单与view |
| ocr-fix-phase5-build-01 | 0 | 第1次实际build安全摘要、HEAD/指纹 |
| ocr-fix-phase5-target-predeploy-02 | 0 | 部署脚本前重新核唯一目标 |
| ocr-fix-phase5-signed-deploy-01 | 1 | 原脚本阶段/RC摘要；登录预检阻塞，没有实际build/run |
| ocr-fix-phase5-artifact-audit-01 | 0 | 14源集合/实际调用数/制品字节与SHA/模板diff0/安全动作数 |
| ocr-fix-phase5-closeout-audit-01 | 0 | 文档收尾后仅重复本机制品/账本/模板及diff审计，不build/run |

checker工具结果另以原文转录到 `.cache/ocr-fix-phase5-20261018-checker-result.json`，不是再次checker或伪造工具原始产物。实际调用事件 `.cache/ocr-fix-phase5-20261018-events.jsonl` 仅有build-start/build-end（attempt1/RC0）。构建摘要只从本次内存输出提取非敏感诊断与RC，未读private/raw、未修改或绕过公共过滤器。

下列为**已执行命令记录，不授权自动重跑**，限制器/证据/本报告均属于本次唯一验证：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 RUN_CMD='node .cache/ocr-fix-phase5-20261018-cli.cjs summary-build' /bin/bash scripts/capture-test-log.sh ocr-fix-phase5-build-01 1s
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 RUN_CMD='env -u DEVECO_CLI_AUTH_SOURCE -u DEVECO_CODE_AUTH_DIR DEVECO_HOME="/Applications/DevEco-Studio.app/Contents" DEVECOCLI_BIN="/Users/zane/DevecostudioProjects/Shuvi-agent/.cache/ocr-fix-phase5-20261018-cli.cjs" /bin/bash scripts/dev-run-mac.sh --emulator "Mate 90 Pro" --device "127.0.0.1:5555" --product default --no-emulator' /bin/bash scripts/capture-test-log.sh ocr-fix-phase5-signed-deploy-01 1s 127.0.0.1:5555
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 RUN_CMD='node .cache/ocr-fix-phase5-20261018-audit.cjs && git diff --check' /bin/bash scripts/capture-test-log.sh ocr-fix-phase5-artifact-audit-01 1s 127.0.0.1:5555
```

子进程取消两个代理认证来源变量后仍被预检阻塞；没有为此login、改全局环境/配置或读取认证数据。独立CLI路径 `/Users/zane/.local/share/fnm/node-versions/v22.23.2/installation/bin/devecocli`，Studio `/Applications/DevEco-Studio.app/Contents`。正常脚本raw始终内部私有，未交公共RUN_CMD或读取。

## Host与功能边界

沿用实施最终 `.cache/test-logs/2026-10-18-ocr-fix-host-closeout-03-a9092f0/`：299/299（旧278+21），73.859146541秒，指纹 `813430e646e0c456c59b85aeb90b8acf39588032938df3951f61b13fd4cbb10b`；counter沿用 `.cache/test-logs/2026-10-18-ocr-fix-counter-01-a9092f0/`，32/32。本轮只读取这些公共日志，没有重跑测试、旧云guard或候选。

| 标准 | 当前证据与未验边界 |
| --- | --- |
| SC-011 / B1 | 实施host新false包52CRC/展开8482133B/342主项/346nodes/294validated/52excluded（33页脚Unsupported/NodeTypeUnsupported＋19EmptyText）及codec通过；46图仅引用。**本轮没有真实ImageKit/落盘读回/恢复到Review，不能标功能PASS** |
| SC-012 | 实施host旧true snapshot `7cc6022572ca890114c4e90e3096ddc5318eaceee755ba44ebcb5e83b847e281`、report `6b57aaa8827b25325bf41c1a2f82fb4c81fb3a95f6c0af1ee4d92d06a55ac864` 精确回归，343块及负例保留；本轮未读设备生产库，不声明旧343/向量当前实际状态已复测 |
| SC-013 / B2 | 具名数据/白名单/成功payload策略host及当前源码编译通过；**真实TaskPool/跨线程错误及页面展示未验**，不以checker/build替代 |
| SC-014 / FR-048 | 本轮provider请求0、Key读取0、运行时恢复0、生产profile/checkpoint更新0、发布/向量化0；部署阻塞及未验项明示，不消费旧授权 |

源码未主动迁移旧Published/Retained，既有processingKey和旧true快照保护沿实施回归；未做生产读回证明，不能把历史readbackSet SHA当本轮测得。新attempt3 `kb-4dd55b5a630d1479a70ec5a5a5db913f` 及其余候选均未恢复/删除，不创建第四attempt，不改原件/ZIP或请求is_ocr。page_footer不改正文，也不自动批准Review。

## 自审与结束

实际build1/10且前有BUILD_ATTEMPT；预留attempt2因预检未调用。CODE_MODIFIED始终false；verify_ui/截图/故事retry/Phase2均0并按build-only跳过。无超限或未报告的编译修复。未读取Key/密码/剪贴板/.local/签名/private/raw；正常脚本内部只运行登录态预检，未走缓存读取/签名生成。未auth login/license/signature generate/force sign、未直接HDC、未卸载/reset/清数据、未发MinerU/models/probe/embedding/query。

T007/T008按“已处理”勾选并分别记录PASS/INCOMPLETE，勾选不等部署通过。本轮最终只交付**当前源码构建通过，安全部署未完成**。本报告唯一结案，不能自动再次invoke Phase 5或重跑本轮限制器；功能真实恢复/Review及线程验收仍未执行。
