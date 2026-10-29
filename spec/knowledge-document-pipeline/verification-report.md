# M2-A 阶段 5 权威验证报告

**最终状态：INCOMPLETE**

日期：2026-10-14。本轮唯一 spec-verify 委派；没有再次委派、question 或 Git 写操作。依据动态解析的 home 读取 `/Users/zane/.local/share/deveco/specs/commands/spec-verify.md`，PROJECT_ROOT 为本仓库，Confirmed_Feature_Dir 为本目录。Verification_Scope 保持 `build+ui`，采用父 agent 提供的五条故事复合用例，没有重新生成或改为 build-only。

结论：当前源码实际构建、签名部署及编译修复后 host 通过；**自动 UI 工具因未配置多模态模型而不可用**，两次调用均在初始化处失败，未返回校验 ID、successPart/failPart 或截图。五故事均不能称 UI PASS。无用户 Token 或获准复杂文件，真实服务部分另行 INCOMPLETE。没有以 host、签名安装或旧人工 M1 反馈替代这些证据。

## 逐步结果

| 阶段 | 执行状态 | 实际结果 |
|---|---|---|
| 规范/基线 | EXECUTED | 一次读取 spec/plan/tasks/implementation-report、AGENTS、相关源码及现有 capture/mac-run 脚本；沿用 API26，无依赖或权限扩张 |
| 初始 checker | EXECUTED / PASS | 新增及修改的18个 `.ets` 一次 batch 检查，无报错；紧接 build。clean 不代表实际构建通过 |
| Phase 1 build 1 | EXECUTED / FAIL | CompileArkTS：两处未收窄异常重抛、Promise拒绝参数结构类型、枚举控制流收窄、遗漏 requestActive；摘要 ERROR6/WARN334，具体5条定位见下 |
| Phase 1 build 2 | EXECUTED / FAIL | 前述类型问题修复后，es2abc 拒绝 Concurrent 函数捕获同文件帮助函数；伴随程序数量错误，摘要 ERROR3/WARN333 |
| Phase 1 build 3 | EXECUTED / PASS | 分离无UI文件帮助模块后 cmd_exit0，生成当前 unsigned 产物。公开 host.log 被既有过滤器整体 withheld，保留退出元数据，不读取私有原流 |
| 修复后 host | EXECUTED / PASS | 148 PASS / 0 FAIL / 0 cancel / 0 skip，71.032379秒；原96+新增52保留，当前修复源码重新执行，不引用旧148替代 |
| 签名脚本首次尝试 | EXECUTED / BLOCKED | 代理CLI继承认证环境使登录预检停止；**没有实际第4次build/run**。capture窗口误写2min导致日志参数错误；两项失败证据保留 |
| 签名脚本一次重试 / build 4 | EXECUTED / PASS | 使用现有独立CLI、仅本次子进程取消继承的代理认证来源，正常登录态预检、复用缓存签名、build成功、run --skip-build安装启动RC0。未登录/强签/读缓存/接受协议 |
| Phase 1 UI prep | EXECUTED | 五条父用例保留；禁止真实或假Token代填、凭据删除、样本读取/生成、公网连接与解析请求 |
| Phase 1 UI | BLOCKED / INCOMPLETE | US1工具调用两次均初始化失败；一次工具重试后停止，US2–US5未调用；无UI操作/断言结果或校验ID |
| Phase 2 | SKIPPED | `code_modified=false`，没有 Per-Story Verify & Fix Loop 源码修复；`[PHASE2_SKIPPED] reason=no_per_story_fix`。Phase 1阻塞结果权威 |
| 证据/报告 | EXECUTED | 本报告、总spec增量、capture日志与元数据落盘；T032–T034 checkbox留父agent结案，没有误勾全部通过 |

实际 Phase 1 step 1 `devecocli build` 调用计数 **4/10**：1失败、2失败、3 unsigned成功、4脚本 signed成功。首次签名脚本阻塞在build前不计数；两个第4次预告对应一次实际build。故事内build为0，Phase 2 build/deploy为0。

## 编译修复

1. `DocumentParseService.ets` 原204/238行：上传catch只重抛已通过instanceof校验的DocumentParseFailure，其余归一为“上传结果未知，原身份保留”，不暴露系统原文，不把未知当成功。
2. 同文件原306行：用具名成员 `pauseFailedResume` 检查异步动作后的真实阶段，保留UploadUnknown/Received，不用断言规避静态枚举收窄。
3. `MineruTransportAdapter.ets` 原88行：Promise reject参数使用明确Object类型，满足ArkTS名义类型；原91行遗漏的requestActive补初始化并在finally失效，迟到认证不能继续使用已结束请求。
4. `DocumentFileAdapter.ets` 的Concurrent复制函数：帮助函数原样移至新 `infra/DocumentFileOperations.ets`，worker使用导入符号；Assembly/PdfPreflight/Transport的帮助函数import随之调整。没有循环依赖、UI导入、I/O或预检预算削弱。

实际修改5个已有M2文件并新增1个M2 infra文件：application/DocumentParseService、infra/MineruTransportAdapter、DocumentFileAdapter、DocumentParseAssembly、DocumentPdfPreflight；新增DocumentFileOperations。无故事内修复、无UI源码修复。已加载可用的hmos-arkui-develop-skill，并查官方TaskPool使用规范和既有TextProcessingAdapter；环境没有arkts-error-fixes技能，未伪造调用。失败build→fix→重build间没有再checker。

## UI 测试计划与权威故事状态

| 故事 | 父用例与预期概览 | Phase 1尝试 / ID | 权威状态与未覆盖 |
|---|---|---|---|
| US1 | 我的/知识库入口→固定MinerU精准vlm；空密码、不预填/显示/复制/连接；空值保存不可用；切页返回清空 | 2次工具调用，0次实际UI验证；ID均无 | INCOMPLETE：工具初始化不可用。真实Asset CRUD/锁定未测，不写假值到生产别名、不删用户凭据 |
| US2 | 解析准备→选择器取消；无新增/网络，M1数量状态不变；默认关/普通资料门禁/逐文件五确认缺条件不可提交 | 0次；ID无 | SKIPPED / INCOMPLETE：同工具阻塞。无样本，Picker取消、保真SHA、PDF/Office预检及逐文件UI均未测 |
| US3 | 空任务/四格式仅转发与产物未验证；未同意零外发，无ready/索引/服务成功/Token/签名URL假状态 | 0次；ID无 | SKIPPED / INCOMPLETE：工具阻塞；真实申请/原字节PUT/Query/ZIP UNVALIDATED接收未执行 |
| US4 | 设置/任务切换、停本机、返回一级、停止重启不清数据；不自动API恢复/secret预填，不造pending；仅本轮toggle变化才恢复 | 0次；ID无 | SKIPPED / INCOMPLETE：工具阻塞。没有改变任何开关/旧偏好；实际任务暂停/查询/租约/生命周期云行为未测 |
| US5 | 仅已有可辨fixture标题/metadata→对应golden关键词查询→返回M2；M1资料历史保留，M2不进M1索引；空目录说明/四格式边界准确 | 0次；ID无 | SKIPPED / INCOMPLETE：工具阻塞，未查询或读取设备资料。原96/golden本机host保留，不扩大为六文件设备全导入/检索通过 |

UI错误（两次完全相同，已原文告知）：

```text
UI 意图校验功能不可用：未配置多模态模型。请在配置文件中为 ui_verification agent 配置一个支持多模态的模型，或登录账号以使用内置多模态模型。
```

US1第二次调用为工具初始化故障的一次重试，不是应用断言失败后的代码修复。没有第三次调用、没有改DevEco配置/登录/替换模型，也没有手工layout/截图冒充verify_ui。工具失败不作为产品FAIL；未执行关键UI覆盖使整体INCOMPLETE。

## 当前产物与部署身份

当前清单通过CLI核对唯一活动 `Mate 90 Pro / 127.0.0.1:5555`，phone、HarmonyOS7.0.0(26.0.0)，其他三个实例停止；没有自动选择其他目标、直接HDC或设备文件写入。

- 当前源码：HEAD `34880f9fd990f8a9023c7a96436b27ca8b3f3d4d` / dev/rag，加现有实现及本轮编译修复的未提交工作区。成功build3、host、signed部署4的dirty_files均26、worktree_fingerprint均 `975f823966c74e22146b4477ffaeffa51a3be42881deb9b01000bf397c4c7544`；随后仅报告/总spec文字增量，不能混称证据指纹相同。
- 包 `com.example.shuvi`，项目versionCode1000000、versionName1.0.0，未通过改版本号冒充新验证。
- `entry/build/default/outputs/default/entry-default-signed.hap`：1291420字节，mtime2026-10-14T20:43:36+0800，SHA256 `cc682f903493e72773bbbbc914ce39fca9e8a798c08f66bceedb6607a6f73bd5`。
- 同次unsigned HAP：1248278字节，mtime2026-10-14T20:43:35+0800，SHA256 `d4cad2d9986dc47dbf05d91e5dc3e9b9932eec02b6a63f1da8d799ad0f8d9033`。
- signed证明来自正常缓存合成、脚本公开build成功/run成功阶段与当前signed文件，不以SignHap任务名或旧app代验。未读证书、签名缓存、私有build/run/auth原文。安装启动RC0不等稳定进程/页面渲染/平台能力通过。
- 公开build模板SHA前/后均 `36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`；只读git diff确认template/脚本/依赖/原fixture/golden/M1核心无变化。未检查/清理用户设备旧文件或数据库。
- Nodev22.23.2，代理和独立devecocli均1.3.4；沿用本机DevEco26.0.0.821/API26/Hvigor6.26.4，不升级。SDK host转译器4.9.5不替代严格ArkTS构建。

| 本轮修复源码 | SHA256 |
|---|---|
| application/DocumentParseService.ets | b745f1d05dc6429a3aeba2a954bf53caa5fe18fc3c496b8dc0ca64c53a98201f |
| infra/MineruTransportAdapter.ets | c947b466f3a98dfb24e3401eb31dceed850bce4e2e14b1160b14137f0e5e50e2 |
| infra/DocumentFileAdapter.ets | b8fbfa538e2f11a20452439df9a577246c852103b5b732ea94205c01ceaea0ab |
| infra/DocumentFileOperations.ets | cd10b6b6ec098bc28fc678cf303257d9c9fcc959c72a4133d90c802943d21bc3 |
| infra/DocumentParseAssembly.ets | 82a6aad8b728cdfaafbdeae51d16e8e0ce7442963b3f1d07aa60bcf8f0e0e7d1 |
| infra/DocumentPdfPreflight.ets | 520fb2d6dc7dd68e6062a24d949b0930c0c035801ce5791d2d44bb38515130db |

其余源码、题集和六原件摘要见本轮host.log；摘要只证明所用版本，不等实际SDK适配器执行。

## 日志与复现

证据根 `.cache/test-logs/`，以下各目录完整前缀为 `2026-10-14-`、后缀为 `-34880f9`；包含meta.txt并记入index.tsv。旧阶段4RED/GREEN、旧M1报告与人工两资料反馈不覆盖。

| scope | 公共证据 |
|---|---|
| m2-verify-build-01 | host.log/meta.txt：cmd_exit1；公开尾部诊断，完整首次输出只读取非秘密编译诊断用于定位 |
| m2-verify-build-02 | host.log/meta.txt：cmd_exit1；Concurrent捕获错误及es2abc伴随错误 |
| m2-verify-build-03 | cmd_exit0/meta；host.log整体withheld，未绕过滤器读取私有原流 |
| m2-verify-buildfix-host | 可读host.log全部148项、71.032379秒、当前源码/fixture摘要，cmd_exit0 |
| m2-verify-signed-deploy-04 | cmd_exit1/log_exit1：登录预检阻塞、2min参数错误；未build/安装 |
| m2-verify-signed-deploy-04-retry | cmd_exit0/log_exit0；公开缓存签名/build/install阶段。device.log整体withheld，不称崩溃扫描或稳定运行通过 |
| m2-verify-runtime-evidence | 有界应用日志采集log_exit0，但device.log为空；ui-tool.log记录两次初始化故障。空日志不证明没有运行时问题 |

复现初build及host（无真实解析网络）：

```bash
CAPTURE_HOST_ONLY=1 RUN_CMD='DEVECO_HOME="/Applications/DevEco-Studio.app/Contents" devecocli build --product default' bash scripts/capture-test-log.sh m2-verify-build-reproduce 1s
CAPTURE_HOST_ONLY=1 RUN_CMD='DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" node --test entry/src/test/run-host-tests.cjs' bash scripts/capture-test-log.sh m2-verify-host-reproduce 1s
```

本轮成功signed部署复现命令（仍须授权目标/当前清单/现有登录和签名条件成立）：

```bash
DEVECO_HOME="/Applications/DevEco-Studio.app/Contents" RUN_CMD='env -u DEVECO_CLI_AUTH_SOURCE -u DEVECO_CODE_AUTH_DIR DEVECOCLI_BIN="/Users/zane/.local/share/fnm/node-versions/v22.23.2/installation/bin/devecocli" bash scripts/dev-run-mac.sh --emulator "Mate 90 Pro" --device "127.0.0.1:5555" --product default --no-emulator' bash scripts/capture-test-log.sh m2-verify-deploy-reproduce 2m "127.0.0.1:5555"
```

本报告不是后续重新委派验证的指令；本轮按一次委派结束。

## 未覆盖与安全审计

- UI自动执行全部未完成；未获页面渲染、空密码/输入清理、默认关/逐项同意、Picker取消、M1导航/查询、设置/任务重启证据。不存在校验ID或可用截图。
- 真实Asset CRUD/锁定/AES-GCM租约、Picker URI/保真SHA/fd、TaskPool载荷/取消/PDFKit地域ARM实际页数及资源释放、RDB真实布局/事务/恢复/清理、选择性备份均未证。
- rcp真实异步回调等待/onDataEnd/TLS/3xx/Token认证域隔离/实字节硬cap/请求墙钟/上传读回、云slot/429/未知响应恢复、真实四格式产物ZIP和UNVALIDATED接收均未证。当前host仅可注入假端口执行真实业务编排，不是平台或网络通过。
- 无获准样本或用户Token，不读取/代填/截图凭据、不读.cache用户PDF或设备旧正文、不生成/下载伪真实样本、不做含假认证值的公网请求或检查连接、不扫描目录、不解包/猜schema/复杂索引/原页高亮/M3/LLM/embed/sync。
- 未改变用户Credential、解析开关或既有偏好，未导入/删除任何设备资料；无uninstall/wipe、HDC写、强签/login/license、Git config/commit/push/merge/rebase等写操作。未接触.local/privatecfg/证书原文，脚本只按授权内部复用缓存。
- `git diff --check`通过；M1受保护核心/fixture/golden/依赖/启动及capture脚本字节审计通过，knowledge-emulator-e2e未跟踪记录保留。M1旧失败和人工反馈仍分层保留。

计数审计：每次实际初build均有BUILD_ATTEMPT，实际4≤10；US1两次VERIFY_UI_CALL均freshStart=true且只含US1，2≤3，US2–US5为0；code_modified初始化false且没有故事内源码fix，Phase2跳过，未伪造最终复验或限额超限。没有AUDIT_VIOLATION计数超限。工具故障重试不伴随代码fix为环境阻塞处理，不算故事应用恢复成功。

**最终权威：INCOMPLETE。T032构建/host已取证，T033当前signed安装启动已取证，T034安全UI未执行且真实Token/样本/服务缺项保留。不得标整功能PASS或已验收。**
