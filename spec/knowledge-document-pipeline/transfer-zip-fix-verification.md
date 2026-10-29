# MinerU 上传至 ZIP 修复验证报告

日期：2026-10-15。范围：`build+ui`，来自 `transfer-zip-fix-tasks.md` 的 Verification marker。**最终状态：FAIL，未打通真实 ZIP 闭环。** 当前安全阻塞为原对象唯一获准补传收到 HTTP 403，不能再补传或申请新 batch。不是凭据缺失，也不是仅因自动 UI 工具不可用而停止。

## 1. 流程与计数

`PROJECT_ROOT=/Users/zane/DevecostudioProjects/Shuvi-agent`；原生 HOME 解析为 `/Users/zane`，`CONFIG_ROOT=/Users/zane/.local/share/deveco/`。已读取该目录的 `specs/commands/spec-verify.md`、本轮任务/实施报告、AGENTS 与相关源码。沿用指定 feature 目录和父级两故事，不重新生成测试计划、不提问、不重新委派阶段 5。

| 步骤 | 执行状态 | 实际结果 |
|---|---|---|
| ArkTS 静态检查 | 已执行 | 9 个生产文件及 2 个 `.ets` 测试，共 11 文件，无诊断；不能替代构建 |
| Phase 1 初始 build #1 | 失败 | `CompileArkTS` 的 2 处 `arkts-limited-throw`，没有安装旧产物冒充本轮通过 |
| 编译修复及 build #2 | 通过 | 仅修两个错误回调的领域错误重抛；缓存签名构建成功 |
| `run --skip-build` | 通过 | 脚本锁定 Mate 90 Pro / `127.0.0.1:5555`，当前新版安装启动 RC 0，随后 CLI 实际看到页面 |
| 修复后全量 host | 通过 | **212/212**，fail=0、cancelled=0；包含生产源码/runner/loader/fixture/golden 摘要 |
| US1 `verify_ui` attempt 1 | 工具初始化失败 | `freshStart=true`；未配置多模态模型，无校验 ID、无自动动作或截图 |
| US1 受限 CLI 设备验证 | **失败** | 应用 Query 原 batch 成功、waiting-file → 唯一同对象 PUT → HTTP 403；未到 done、未下载 ZIP |
| US2 `verify_ui` attempt 1 | 工具初始化失败 | 同一模型配置阻塞，`freshStart=true`，无 ID；未重试同一工具故障 |
| US2 受限 CLI 设备验证 | **INCOMPLETE，部分断言通过** | 进度/错误可见、前台往返记录保留、重开检查点持久和凭据已配置已观察；活跃传输切页、成功 ZIP 总览未能验到 |
| Phase 2 | 跳过 | `code_modified=false`，没有故事内源码修复；Phase 1 为权威结果 |
| 文档和最终审计 | 已执行 | 本报告/总 spec 追加实际结果；`git diff --check` RC 0，签名模板字节一致 |

计数：Phase 1 step 1 的 `devecocli build` **2/10**；故事内 fix build **0**；US1/US2 自动调用各 **1/3**；故事内修复/重验均 **0**。编译修复不设置 `code_modified`。输出已包含 `[CODE_MODIFIED] initialized code_modified=false`、两次 build marker、逐故事 `[VERIFY_UI_CALL]` 与 `[PHASE2_SKIPPED] reason=no_per_story_fix`。未达到重试上限，未以新 batch 绕过单对象一次限制。

## 2. 测试计划与实际服务证据

**US1**：在当前原任务点击“继续查询同一任务”并确认既有同账号授权；必须先 Query 原 batch，仅 waiting-file 且原件/Grant/revision/租约一致时同对象完整 PUT 一次；真实 done 后受控 GET ZIP，外层签名/实长/fsync/读回 SHA256/rename/结果关联均满足才算成功。

**US2**：检查真实查询次数、最后响应、可选页进度和上传/下载字节；活跃阶段前台切一级页再返回不暂停；成功后重开，结果路径/字节/hash/接收时间与真实包保持一致，显示“解析服务成功，ZIP 已保存，内容待结构校验”，不索引。

本轮通过应用的生产 Asset/RCP/Repository 恢复，不用外部 curl、Token、签名地址或数据库写入模拟业务。实际顺序：

1. 新版打开现有任务，显示 `m2-e60ec2ccc6b4ed47d6d49d326003ca16`、`04_第04章_决策树.pdf`、4,381,223 字节、24 页、身份预检通过。迁移后的旧上传记录显示“实际 PUT 是否发出未知”，查询 0、补传未耗用；这是旧本地记录，不代表历史从未查询。
2. 点击该任务“继续查询同一任务”，滚动到底部点击“确认继续”，没有点击“核对原云任务”、新“提交本件测试”或重新确认原件授权。
3. 累计查询变为 **1**，最后响应显示 **10/15/2026, 9:23:01 PM**，服务状态 **waiting-file**。只有生产控制请求通过 HTTP 200、业务 code 0、batch/data_id 校验后才会发布此状态；本轮未额外采集原始 HTTP 响应或完整 batch 值，不能声称有独立网络抓包。
4. 应用完成本地原件校验、原租约解密/关联/有效期复核，进入 SDK PUT 边界。原件 hash 基线为 `29470c866abd6ce0a107ab316cbd99873dd0003b5c61eda2a69d4dce30a0000a`，original ID 为 `m2-87f6c3ea33f596b11ec313199476645b`。进入该边界证明生产预检未拒绝，**不是 agent 本轮独立读取设备文件 SHA256 的证据**。
5. 唯一补传的意图已持久化，UI 显示 **同对象补传已耗用**；本次供给 SDK **65,536 / 4,381,223 字节**，**未确认上传成功**。供给 SDK 不等于远端收到同等字节。
6. PUT 收到 **HTTP 403**；UI 显示“鉴权或任务访问失败 · HTTP · 403”“失败阶段 HTTP · code 403”，任务为“上传结果未知，请查询”。ZIP 实写 **0 字节**、总长未知、服务未报告页进度，没有成功结果区。
7. 无第二次补传、无新 allocation、无新 task/data_id/batch、无结果 GET。未观察到 pending/converting/running/done，未生成可交付的 ZIP/hash/结果行证据。原远端占用仍保留，未冒充终态释放。

403 的精确根因**未证实**：只能确认原对象上传 HTTP 访问被拒绝，不能断言为 Token 错误、租约过期、源读取错误或 TLS 故障。当前公共错误分类仍是通用 HTTP，页面“SDK PUT 已调用，等待响应”是旧动作描述，不能把它解释为失败后仍在传输。

## 3. UI、迁移与资料保留的证据边界

- 新版成功打开原任务并显示 v2 扩展字段，未出现白屏/崩溃或切空库；这是实际应用迁移/加载可用的证据，不等于七表逐字段字节对照通过。
- 前台工作台 → 知识库 → 解析准备往返后，仍显示同任务、waiting-file、1 次查询、65,536 字节、403 和补传已耗用。由于上传已很快失败，**不能宣称活跃上传/轮询过程中切页不暂停已实测通过**；该路径目前有 host/源码约束，但没有成功活跃设备证据。
- 使用同一当前产物再次 `run --skip-build` 重开后，原任务显示“本机暂停”，符合 initialize 的保守恢复；查询时间、累计次数、字节、403 和补传耗用均保留。没有点击恢复再发送请求。
- 只读设置状态显示 **已配置**；没有保存/更新/删除凭据，没有输入 Token、查询 SECRET、截图密码页或把 signed URL/认证头写入日志。
- 知识库实际仍显示已有两份 MD 资料 `deepseek-chat-completions.md`（6,970 字节）和 `who-hypertension-factsheet.md`（7,567 字节）就绪；没有执行删除/归档/重建、选择新 PDF 或扫描资料目录。
- 加载的验证工作流严格禁止直接 HDC。因此本轮**没有重新读取设备 SQLite/原件/结果物理 SHA256**，没有前后全库 metadata 快照；未运行已有依赖 HDC 的只读 helper。上轮只读快照仅为基线，不充当本轮物理结果证明。由于根本未到结果 GET，本轮也不把 UI“0 字节”写成独立文件不存在断言。
- 无清库、卸载、清设备日志、root、权限变更、依赖/SDK 升级或 Git 写操作。原未提交 Token/transfer 修复和用户 paste 脚本均保留，未读取或执行用户 paste 脚本。未发生需清理的本轮结果下载；未手工删除租约、重置耗用或解除远端占用。

## 4. 编译修复与官方依据

本次仅新增两处生产编译修复：

- `MineruCredentialStore.ets:143` 和 `MineruTransportAdapter.ets:130` 的 Promise `.catch((error: BusinessError) => ...)` 在 `instanceof DocumentParseFailure` 后仍不能 `throw error`（`10605087 / arkts-limited-throw`）。改为 `throw new DocumentParseFailure(error.category, error.stage, error.serviceCode)`，保留去敏语义和 code，不改变凭据或传输重试政策。其余既有代码未回滚。
- 已加载 `hmos-arkui-develop-skill` 并读取语法规则。首轮 checker 没检出该编译器问题，失败后未再 checker，直接重建通过；不是故事内修复。无 runtime crash，未触发 crash skill。

收到 403 后重新读取用户给定 MinerU 官方文档，确认仍是原件 raw PUT、上传地址有效期 24 小时、无需 Content-Type、上传完成自动提交；原 batch GET 查询，done 才返回 full_zip_url。公开文档缓存：`/Users/zane/.local/share/deveco/tool-output/tool_13fbbe75a001FKf6l5lDghICAk`。没有调用示例或测试新对象。

同时读取官方 RCP API：`API参考/网络/Remote_Communication_Kit_远场通信服务/ArkTS_API/rcp_数据请求/remote-communication-rcp`，公开缓存 `tool_13fbc7c1d001YZ4fiLjSMWOvg3`。其 RequestHeaders 说明：未提供或空字符串 Content-Type 时 SDK 可能按 RequestContent 补默认类型；单空格可禁用默认类型。当前代码只显式提供 content-length。**这是一项待验证因素，不是已证实 403 根因**；没有抓取原始请求头/存储错误正文，也没有猜测参数并试发第二 PUT。后续诊断应先具备不泄露签名地址/Token/原始正文的最小服务错误类别与请求头安全摘要证据，以及新的明确执行边界；本报告不替用户批准再次上传或新 batch。

## 5. 构建与日志

目标实际为 **emulator**（非物理真机），Mate 90 Pro、phone、API 26 (Release)、`127.0.0.1:5555`。独立 CLI、`DEVECO_HOME=/Applications/DevEco-Studio.app/Contents`，移除继承代理认证来源，只用已有本机账号和签名缓存，未登录或强签。

签名模板构建前/失败后/成功后/重开后 SHA256 均为：`36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`。当前 signed HAP 为 1,381,188 字节，SHA256 `f1c6ee3e87228ae5c8e8c02a9513dcb8b13f7b471d6ae3a7b142416a2145a348`。原始签名/认证输出仅脚本私有目录，agent 未读取；编译诊断由白名单 helper 去敏提取。

下表路径均相对 `.cache/test-logs/`，各目录包含 `host.log`/`meta.txt` 与索引。全部经 `CAPTURE_HOST_ONLY=1` 落盘，不收集宽泛设备日志；“host-only”在此表示禁用附带 hilog，**不表示 RUN_CMD 没有实际 CLI 设备动作**。

| 证据目录 | 内容 |
|---|---|
| `2026-10-15-transfer-zip-verify-build-1-a799981` | 首构建失败，未部署 |
| `2026-10-15-transfer-zip-verify-build-diagnostics-a799981` | 去敏编译诊断，2 个具体 ERROR；含公开编译警告，不是私有签名正文 |
| `2026-10-15-transfer-zip-verify-build-2-a799981` | 缓存签名构建成功、当前产物安装启动成功 |
| `2026-10-15-transfer-zip-verify-host-postcompile-a799981` | 修复后 212/212 全量回归、源码/fixture/golden SHA、工作区指纹 |
| `2026-10-15-transfer-zip-verify-original-task-a799981` / `2026-10-15-transfer-zip-verify-resume-visible-a799981` | 当前部署后原任务、原件与旧记录扩展字段 |
| `2026-10-15-transfer-zip-verify-resume-confirmation-a799981` / `2026-10-15-transfer-zip-verify-confirm-visible-a799981` | 同任务继续授权界面 |
| **`2026-10-15-transfer-zip-verify-real-query-first-a799981`** | **实际 Query→waiting-file→唯一 PUT→403、实字节和耗用状态** |
| `2026-10-15-transfer-zip-verify-foreground-return-a799981` / `2026-10-15-transfer-zip-verify-failure-retained-a799981` | 前台往返已有资料与失败状态 |
| `2026-10-15-transfer-zip-verify-reopen-a799981` / `2026-10-15-transfer-zip-verify-persisted-checkpoint-a799981` | 同产物重开及检查点持久 |
| `2026-10-15-transfer-zip-verify-safe-config-status-a799981` | 非输入框白名单只读状态“已配置”，没有密码截图 |
| `2026-10-15-transfer-zip-verify-final-audit-a799981` | 产物/模板/helper/source 摘要、唯一目标和 diff 检查 |
| `2026-10-15-transfer-zip-verify-report-audit-a799981` | 报告写入后的同产物/源码/模板一致性及 diff 检查 RC 0 |

host 时 HEAD `a799981`、dirty 23，工作区指纹 `e902d7e99020c63420b0aeea42b67b38d40f9f29fd164d07febd16071bf9e7dd`。随后仅取证 helper/文档改变，不将后续文档状态冒称同一指纹。最终两个编译修复文件 SHA：Credential `5b18432fd871a4e8ee3e9028d1228fa7bf9eb77b0571bbee38a2633b7ca6ab7b`、Transport `0983460d0de63395b845646eafd0b2824e3a8984cba2fd3776131940495c52ec`。其余知识源码、六 fixture/golden 摘要见 host 日志。

不触发 MinerU 业务请求的复现命令：

```bash
env -u DEVECO_CLI_AUTH_SOURCE -u DEVECO_CODE_AUTH_DIR \
  DEVECO_HOME=/Applications/DevEco-Studio.app/Contents \
  DEVECOCLI_BIN=/Users/zane/.local/share/fnm/node-versions/v22.23.2/installation/bin/devecocli \
  CAPTURE_HOST_ONLY=1 \
  RUN_CMD='/bin/bash scripts/dev-run-mac.sh --device 127.0.0.1:5555 --emulator "Mate 90 Pro" --product default --no-emulator' \
  /bin/bash scripts/capture-test-log.sh transfer-zip-verify-build

CAPTURE_HOST_ONLY=1 DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  RUN_CMD='node --test entry/src/test/run-host-tests.cjs' \
  /bin/bash scripts/capture-test-log.sh transfer-zip-verify-host

CAPTURE_HOST_ONLY=1 RUN_CMD='node .cache/transfer-zip-verification.cjs layout' \
  /bin/bash scripts/capture-test-log.sh transfer-zip-verify-observe
```

自动工具的两个初始化失败原文均为：“UI 意图校验功能不可用：未配置多模态模型。请在配置文件中为 ui_verification agent 配置一个支持多模态的模型，或登录账号以使用内置多模态模型。”无自动校验 ID，未伪造截图/日志查询。CLI helper 仅内存解析 layout、排除输入框/URL/Bearer，落盘白名单非输入文字及 bounds；不是 verify_ui 自动通过证据。

## 6. 交付与停止

权威结论：**US1 FAIL；US2 INCOMPLETE；总体 FAIL**。U006 构建部署动作完成，但 U007 的真实 done/ZIP 门槛失败，U008 成功路径未完成。任务复选框按父级交接要求留给父 agent 结案，不全部勾选。

用户可在已部署版本进入：**知识库 → 复杂文件解析准备 → 解析准备 / 任务**，下滑查看原 task 的 1 次查询、上传供给 65,536 字节、0 ZIP 字节、HTTP 403 和同对象补传已耗用；引擎设置只读状态应为“已配置”。不要把“继续查询”理解为还可再补传，也不要重置原任务或重新提交。

本轮已停止真实云动作。不解包、不做内部 schema/成员校验、不建索引/向量化，不进入 M2-B/M3/M4。没有真实 ZIP 可交用户验收，不能将本报告视为功能打通或用户验收通过。
