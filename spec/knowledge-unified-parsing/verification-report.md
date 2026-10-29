# 统一 ParsedDocument 与图片知识检索验证报告

**日期**：2026-10-21。  
**状态**：**INCOMPLETE**。本文件为该 feature 唯一一次 Phase 5 / spec-verify 的权威报告，不代表产品已验收。  
**范围**：`build-only`，依据 `tasks.md` Phase 9 的 `<!-- verification_scope: build-only -->` 与本轮明确授权。  
**任务**：仅 T046、T047；父代理已审阅本报告及公共 build meta/log，并按“已处理”勾选 `tasks.md`，不表示构建或部署成功。  
**PROJECT_ROOT**：`/Users/zane/DevecostudioProjects/Shuvi-agent`。  
**CONFIG_ROOT**：由 OS 原生 home `/Users/zane` 解析为 `/Users/zane/.local/share/deveco/`。  
**Confirmed_Feature_Dir**：`/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-unified-parsing/`。

## 结论

| 项目 | 结果 | 实际依据 |
|---|---|---|
| T046：完整 ArkTS checker | PASS | 唯一一次 `arkts_check`，精确有序 90 ETS，返回 `No errors found in 90 file(s).` |
| T046：实际构建 | 未通过；任务整体 INCOMPLETE | checker 后下一工具调用即执行实际 build；唯一一次 `devecocli build --product default` 返回 RC 1；公共输出被既有保守过滤整体隐藏，无法合法取得可用于修复的诊断 |
| T047：缓存签名、安装与普通启动 | SKIPPED / INCOMPLETE | 未满足成功 build 前置；实时清单还显示活动设备 0、四台模拟器均 stopped，不允许启动实例 |
| 最终状态 | **INCOMPLETE** | 无成功 build、无本轮有效新制品、无安装启动；未达到 10 次 build 上限，不将隐藏原因猜为编译或环境错误 |

checker 通过不等于 ArkTS 全工程构建通过。一次 build 的工具退出失败是事实，但失败阶段、具体编译项和是否存在环境问题均无法从允许读取的公共证据确认。不能推定源码已正确或一定存在特定错误。

## 工作流与执行顺序

1. 已读取 canonical `/Users/zane/.local/share/deveco/specs/commands/spec-verify.md`，加载 `deveco-cli`；读取 `AGENTS.md`、`docs/01-协作与工程约定.md`、本目录批准 spec/plan/tasks、handoff 与最终 implementation-report checkpoint。
2. 初始化输出 `[CODE_MODIFIED] initialized code_modified=false`。本轮无 per-story UI loop，协议变量始终为 false；源码编译修复也为 0。
3. 在预先确认的临时父目录下，以 `mktemp -d` 建立新的私有 guard 目录，使用 `apply_patch` 编写 helper，guard 已设为可执行。未复用旧 guard/journal，未修改仓库正常部署脚本。
4. checker 前完成安全 capture/build wrapper、模板检查、清单/hash 核对及设备预检。第一次预检因缺活动模拟器 RC 1；第二次保留该部署阻断、允许独立编译准备完成，RC 0。该调整仅发生于临时 helper，不改生产代码或验收标准。
5. 仅导入 loader 的 `exports.changedEts`，未调用 harness/run；与实施报告最终 00–89 清单逐项顺序比较，长度 90、无重复，三个 checkpoint hash 全部匹配。
6. 唯一一次 `arkts_check` 检查全部 90 ETS，0 诊断。结果后立即输出 `[BUILD_ATTEMPT] attempt=1/10`，下一工具调用为 capture 包装的实际 build，没有插入其他工具操作。
7. build 起止 `2026-10-21T15:10:49.693Z` 至 `2026-10-21T15:11:05.338Z`，CLI 返回 1，capture 的 `run_cmd_exit=1`。公共 `host.log` 仅有 `[private output withheld; see phase and exit metadata]`。
8. 没有读取隐藏/raw 输出、没有修改过滤器、没有推测隐藏诊断；无可执行的定向修复依据，停止该路径，不盲目重复构建。未在 failed build 与 retry 间调用 checker；实际没有 retry。
9. 因 build 未成功，未执行部署脚本、auth status、缓存应用、签名、run 或任何安装。预检也已确认无符合授权的活动模拟器，不能以历史 serial 或自动启动补足。
10. 所有 UI 准备、测试计划生成、per-story verify/fix 及 Phase 2 均按 build-only 跳过。已输出 `[PHASE2_SKIPPED] reason=no_per_story_fix`；本报告采用 Phase 1 的实际 checker/build 与部署跳过结果。
11. 最终 audit 通过既有 capture 落盘，复核源码集合未变、模板原字节 hash 未变及制品确为旧文件。未委派其他 verifier，没有 Agent 创建的后台 worker 或仍在运行的验证会话。

## 精确计数与变更

| 计数项 | 数值 |
|---|---|
| spec-verify invocation | 1 |
| `arkts_check` 调用 / 输入 | 1 / 90 ETS，每项一次 |
| 实际 `devecocli build` / 上限 | 1 / 10 |
| 成功 / 失败 build | 0 / 1 |
| rebuild / 编译修复 | 0 / 0 |
| 正常签名脚本内部 build | 0 |
| `devecocli run --skip-build` | 0 |
| 安装 / 启动退出码 | 不适用，未调用 |
| 本轮限定 host 回归 | 0，未发生源码修复，无需重跑 |
| UI / 平台 suite / 截图 / layout / 业务按钮 | 全部 0 |
| 真实业务请求 | **0** |

本轮仓库内仅新增本 `verification-report.md`；无 ETS、测试、依赖、权限、SDK、Native 或业务设置修改。临时目录仅含本轮 helper、非敏感审计 journal/baseline，无签名材料或 auth raw。旧 dirty/untracked 工作保持，不执行 Git 写操作。

implementation 阶段 150/150 与累计 60 次 capture 保留于原报告，仅是先前受控 host 证据；本报告未把它重新计为本轮通过，也不将其替代 ArkTS/compiler/platform/model/UI 结论。

## 工具与源码身份

| 字段 | 值 |
|---|---|
| Git HEAD | `c78d79839f9a16aeee71aa2f91a57a3c1df87112` |
| 分支 | `dev/rag` |
| capture 时 dirty_files | 172，本报告创建前 |
| CLI | `/Applications/DevEco-Studio.app/Contents/tools/node/bin/devecocli`，1.3.5 |
| DevEco 根 / DEVECO_HOME | `/Applications/DevEco-Studio.app/Contents` |
| Studio Node / host Node / Bash | v24.14.1 / v22.23.2 / 3.2.57(1)-release |
| checker | `functions.arkts_check`，精确 90 文件，0 错误；该工具不生成 HAP |
| 当前 capture worktree_fingerprint | `c92d4cd84cf49800b88d1e3c2aae0334c20b9a40b25688ad2d8713b4ee9d853f` |
| loader SHA-256 | `18772b30936eed3bb990343bc8e79aed1ef21701fb77b58169d06971fde8ea8b` |
| 有序路径 SHA-256（LF + 末尾 LF） | `55109520e44896b6f3eff562f373e206515cf6f59642792e12822d96c442bb0c` |
| 有序路径 TAB 源码 SHA 序列 SHA-256 | `c89dff9edb669ad2e91fcc00bf778c620ffa587107d00978864c7709a8e6b99b` |

checker 输入唯一出处：implementation-report.md 最终累计清单第 1084–1173 行，与 `entry/src/test/unified-host-entry.cjs exports.changedEts` 一致。未使用历史 23/42/63/72/89 清单。最后 audit 重新计算上述三项 hash，均未变化。

capture 使用 `CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1`，其指纹 scope 为 `public-feature-host-only; excludes unrelated scripts, private paths and signing configuration`，不是全工作区所有文件的证明。当前值与旧实施源码时点 `8c2563c62ba452c63cd5a37bc77f0cd001ef76ba4e2a55f7af8c3329bbc66b55` 不同；本轮精确 ETS 集合仍匹配交接 hash，不误称重做了旧 host 测试。本目录报告不在该 capture 指纹白名单内。

## 目标与模板

实时 `device list --format json`、`emulator list --format json` 均 RC 0；两次预检均没有活动设备。可见清单如下：

| 实例 | 状态 | serial | 类型 / 系统 |
|---|---|---|---|
| Mate 90 Pro | stopped | null | phone / HarmonyOS 7.0.0(26.0.0) |
| Mate X7 | stopped | null | foldable / HarmonyOS 7.0.0(26.0.0) |
| MateBook Pro | stopped | null | 2in1 / HarmonyOS 7.0.0(26.0.0) |
| MatePad Pro 13 | stopped | null | tablet / HarmonyOS 7.0.0(26.0.0) |

**实际选中/使用目标：无。** 历史 `127.0.0.1:5555` 未被当作当前目标使用；未启动、创建、停止、重命名任何模拟器。

`build-profile.json5` 的工作区与 index 检查均干净，模板结构检查通过，已知 lock/备份冲突检查未阻断；仅检查存在性，未读取缓存、lock 或备份内容。原始及最终模板 SHA-256 都是：

`36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`

模板始终未被签名合成或改写。原始/最终 hash 相等，**不是已执行缓存签名后还原的实证**；实际恢复步骤未发生，缓存可用性和登录状态未验证。

预备的窄 CLI guard 只允许精确的清单/view、auth status、受计数控制的 default build，以及当前目标明确 serial 的 `run --skip-build`；signature 与非 status auth 等其他命令一律拒绝。部署子进程的局部 auth-source/proxy 去除逻辑已准备但未执行；未检查/打印环境值，未改全局配置。

## 制品

**本轮无经成功 build 证明的新 HAP。** 以下仅为失败后及最终 audit 时输出目录中已有文件的身份，mtime 早于本轮，不得安装或作为本 feature 成功制品：

| 文件（均位于 `entry/build/default/outputs/default/`） | 字节 | mtime（UTC） | SHA-256 |
|---|---|---|---|
| `entry-default-signed.hap` | 6086425 | 2026-10-20T13:55:45.690Z | `3a527793a280f5aa5afbbb4d9017b3a63319f5ea3a2534d36dc6a28e5b0905e1` |
| `entry-default-unsigned.hap` | 6014812 | 2026-10-20T13:55:45.603Z | `4c8c015630adc9145b92efe3f8cfa8609a6cad98e89cb420d8a16e45666eb455` |

## Capture 证据与命令

本轮全部公共证据均为 `.cache/test-logs/` 下的唯一目录，读取仅限公共 `host.log` / `meta.txt`；每轮同时保留索引，未覆盖历史。`status=skipped-host-only` 仅指跳过设备日志，不代表 RUN_CMD 未执行，以下以 `run_cmd_exit` 与审计事件共同判定。

| 相对 `.cache/test-logs/` 的目录 | RUN_CMD RC | 结果 |
|---|---|---|
| `2026-10-21-knowledge-unified-verify-preflight-c78d798/` | 1 | 首次目标检查阻断 `sole-active-emulator-required`，失败历史保留 |
| `2026-10-21-knowledge-unified-verify-preflight-c78d798-2/` | 0 | 编译前置及三 hash 完成；明确活动设备 0，不解除部署限制 |
| `2026-10-21-knowledge-unified-verify-build-01-c78d798/` | 1 | 实际 build 唯一一次；公共输出整体 withheld，无可用详细诊断 |
| `2026-10-21-knowledge-unified-verify-audit-c78d798/` | 0 | 完整非敏感 journal、checker 结果转录、当前 hash、模板及旧 HAP 身份 |

四次 capture 的源码指纹均为上述 `c92d4c…853f`。checker 为独立工具调用，audit 中的 checker 行是该真实结果的后续持久记录，不是第二次执行，也不声称 capture 包装了 checker 内部进程。没有设备日志、auth/signing raw 或业务资料进入公共证据。

实际捕获命令结构如下；`preflight` 执行两次，scope 保持相同由脚本自动分配 `-2`，`build` 和 `summary` 各一次：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='node /var/folders/nf/pb46rg9s22nbdsfm6kr463sr0000gn/T/deveco/upd-verify-20261021.QTi9zD/verify.cjs preflight' \
/bin/bash scripts/capture-test-log.sh knowledge-unified-verify-preflight

CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='node /var/folders/nf/pb46rg9s22nbdsfm6kr463sr0000gn/T/deveco/upd-verify-20261021.QTi9zD/verify.cjs build' \
/bin/bash scripts/capture-test-log.sh knowledge-unified-verify-build-01

CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='node /var/folders/nf/pb46rg9s22nbdsfm6kr463sr0000gn/T/deveco/upd-verify-20261021.QTi9zD/verify.cjs summary' \
/bin/bash scripts/capture-test-log.sh knowledge-unified-verify-audit
```

build wrapper 内唯一构建命令为 `/Applications/DevEco-Studio.app/Contents/tools/node/bin/devecocli build --product default`，工作目录为 PROJECT_ROOT；调用前以局部环境提供 DEVECO_HOME，未读取环境值。guard、helper 与 journal 保留供此次审计，不得复用本轮 journal 或自动触发第二次 spec-verify。以上是复现说明，不新增执行授权。

## 安全范围与剩余阻断

本轮真实 MinerU、DeepSeek、corpus/query embedding、models/probe/balance/质量/OCR 等业务请求全部 **0**；没有启用视觉或自动嵌入设置，没有导入、解析、查询、迁移、历史升级或业务按钮交互。

没有读取生产 DB、用户原件/ZIP、旧私有 fixture、`.local`/signing/private/raw 内容、Key 或 auth 原始输出；没有读取、修改或执行禁用脚本与禁用 e2e 目录。未卸载、清数据、强签、新签、login，未直调 hdc，未清理用户资料，未改变正常脚本/依赖/权限/SDK/Native/全局工具或代理配置。无 Git 写操作，无第二 verifier、无后台 worker。

具体未解决项：

1. 实际 build RC 1，公共诊断被过滤，不能安全定位失败或制定有依据的编译修复。禁止为获得诊断读取隐藏输出或放宽 filter；本轮在此停止，T046 未完成成功构建。
2. 当前无活动模拟器，且本轮禁止启动；即使将来有可用制品，也不能使用 stopped 实例或历史 serial 绕过实时目标条件。T047 未执行，签名缓存/安装/启动未获实证。
3. 本轮没有新 HAP。普通 install/launch 本应只证明安装启动，不是 Cold 或 UI 可用；本轮连该项也未发生。

平台 FS/RDB/向量 SQL/AssetStore/RCP/恢复、真实模型费用与质量、实际生产迁移/容量、正式 UI 与真机验收均不在本轮 scope，未补 PASS。现三库名/旧 wire/新根/普通库备份等产品约束未因本报告而改变。本次唯一验证已收口为 **INCOMPLETE**，由父代理据此评审和关闭工作流，不自动重启 verifier 或扩大权限。
