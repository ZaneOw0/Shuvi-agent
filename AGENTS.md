# AGENTS.md — Shuvi（休比）鸿蒙工程

> 面向在本仓库工作的 AI Agent。人类协作规则以 [docs/01-协作与工程约定](docs/01-协作与工程约定.md) 为唯一权威，本文件是它的可执行摘要。
> 状态：已有可构建、可安装的 `entry`；前端为四页导航与日程 Mock 初稿，未接真实能力（见 [specs/01-创建日程并提醒](specs/01-创建日程并提醒.md)）。

## 1. 项目定位

休比（Shuvi）是面向开源鸿蒙社区竞赛的智能个人助理，ArkTS / ArkUI 开发。
链路：`ArkUI → 应用服务 → Agent 主控/子智能体 → 行动草稿 → 确认与校验 → 工具执行 → 平台能力`。
功能范围与优先级见 [docs/00-项目总览](docs/00-项目总览.md) 第 2 节，**未冻结**，改动需求必须由团队确认。

## 2. 开发基本原则（硬性）

1. **先读后写**：改任何代码前，先读相关 spec、现有接口与相邻模块；不臆测平台行为。
2. **不编造 API**：新增系统能力必须给出官方依据（版本、权限条件）。查文档用 `devecocli docs search <关键词>` / `devecocli docs read <documentId>`，不要凭记忆写 `@kit.*` / `@ohos.*` 接口。
3. **不擅自扩权**：不新增依赖、权限、云服务，不改变公共契约；确需变更先说明方案并等待确认。
4. **不伪造成功**：不用兜底假数据、默认值或削弱业务约束来「跑通」。Mock 结果不能当作真实链路完成证据。
5. **类型不替代校验**：模型输出与网络数据必须运行时校验，`as` 断言不算校验。
6. **授权边界**：写入、命令执行与外部操作仅在本任务授权范围内进行；用户要求审批时先展示方案再执行。
7. **不谎报测试**：不得声称未执行的构建 / 测试 / 真机验收已通过；构建通过、模拟器通过、真机通过三者分别记录，不互相替代。
8. **不接触密钥**：API Key、签名证书、`.p12/.cer/.p7b`、私有配置不得进入代码、截图、日志、提交或 AI 上下文。疑似泄漏立即上报并轮换。
9. **不清理用户数据**：不得清除本机日历、个人数据或测试设备既有内容。
10. **Git 只读**：**未经用户明确许可，不执行 `git commit` / `git push` / `git merge` / `git rebase` / 打 tag / force push**。可以读 `git status`、`git diff`、`git log`。

## 3. 项目结构

```
HarmonyPA/
├── AppScope/          # 应用级配置：app.json5（bundleName=com.example.shuvi、版本、图标、名称）
├── entry/             # 唯一 HAP 模块（Stage 模型，deviceTypes: phone，零权限）
│   ├── src/main/ets/
│   │   ├── entryability/EntryAbility.ets        # UIAbility 入口，onWindowStageCreate 加载 pages/Index
│   │   ├── entrybackupability/EntryBackupAbility.ets
│   │   ├── pages/Index.ets                      # 入口页面：四页导航 + 日程 Mock 交互
│   │   ├── components/                          # FeaturePages.ets、Theme.ets
│   │   ├── mock/MockAssistantService.ets        # 前端 Mock 数据，未接真实能力
│   │   └── model/AssistantModels.ets            # 前端领域模型
│   ├── src/test/                                # 本机 host 测试（run-host-tests.cjs）
│   ├── src/main/module.json5                    # mainElement、pages 清单、abilities、requestPermissions
│   ├── src/main/resources/                      # base / dark 资源（element、media、profile）
│   ├── build-profile.json5                      # apiType: stageMode，targets: default / ohosTest
│   └── hvigorfile.ts                            # hapTasks
├── scripts/           # 一键脚本与 Git 钩子，见第 6 节
├── specs/             # 按「用户闭环」划分的功能契约，三条开发线的唯一对齐点
├── docs/              # 00 总览 / 01 协作约定 / 02 平台基线 / 03 鸿蒙概念速览
├── signing/           # 签名占位，仅 README.md 入库，证书材料全部 gitignore
├── .local/            # 本机签名缓存与本地草稿（gitignore，不入库）
├── .github/workflows/ci.yml
├── hvigor/hvigor-config.json5
├── build-profile.json5        # 工程级模板：products(default)、signingConfigs(空)、modules 注册
├── oh-package.json5           # devDeps: @ohos/hypium, @ohos/hamock
├── code-linter.json5          # codelinter 规则，含 @security/no-unsafe-* 系列
└── .gitattributes             # *.sh=LF，*.cmd/*.bat=CRLF，scripts/hooks/*=LF
```

依赖方向铁律：`entry` 组装核心与平台实现；适配器实现核心声明的接口；**核心不引用页面与具体适配器**；禁止循环依赖与跨模块访问内部实现；页面不直接调用模型、不直接写系统日历。

## 4. 工具链与基线版本

以 [docs/02-平台基线](docs/02-平台基线.md) 为准，升级须单独评审：

| 项目 | 值 |
|---|---|
| runtimeOS / SDK | HarmonyOS `26.0.0`，API Level `26`（SDK 包 `26.0.0.105`） |
| compatible / target SDK | `26.0.0` |
| modelVersion | `26.0.0`（根 `oh-package.json5`、`hvigor-config.json5`） |
| Hvigor / 插件 | `6.26.4` |
| OHPM | `26.0.0.630` |
| DevEco Studio | `26.0.0.821` |
| DevEco Code CLI | `devecocli` `1.3.2` |
| CI：CLT / JDK | `26.0.0.821`（含 API 26 的 SDK）/ JDK `21`（`CLT_HOME`、`JAVA_HOME`） |

注意本机存在两套 Node（IDE 配套 `24.14.1` 与 PATH 中 `24.18.0`），命令行操作前确认实际使用的工具来源。

## 5. 工具链、构建与运行

优先使用 DevEco Code 内置工具，不要用裸 shell 替代：

| 目的 | 工具 | 等价命令 |
|---|---|---|
| 快速静态检查单个 `.ets` | `arkts_check` | — |
| 构建 / 打包 | `build_project` | `devecocli build` |
| 启动应用到设备 | `start_app` | `devecocli run` |
| 设备与模拟器管理 | — | `devecocli device list` / `devecocli emulator list|start|stop` |
| 生成签名材料 | — | `dev-run` 已封装（模板合成 + `.local/` 缓存，见 6.1）；底层为 `devecocli signature generate --product default`，需先 `devecocli auth login` |
| 查 HarmonyOS 文档 | — | `devecocli docs search / read / catalog` |

工作流约束：

- `.ets` 文件改完先 `arkts_check`，再 `build_project`；构建失败出现 `ERROR` 时加载 `arkts-error-fixes` skill 修复后重跑。
- **必须先 `build_project` 成功，才能 `start_app`**；任务结束前也必须保证 `build_project` 通过。
- ArkTS 严格规则由构建阶段（`CompileArkTS`）强制拦截，本地报错以构建输出为准。

## 6. 脚本与 Demo 启动方法

一键脚本把「设备/模拟器 → 签名 → 构建 → 安装运行」串起来：

```bash
scripts/dev-run.sh                  # 自动选活动设备，否则启动模拟器；构建并安装运行
scripts/dev-run.sh --force-sign     # 强制重新生成签名材料
scripts/dev-run.sh --no-build       # 跳过构建，仅安装运行
scripts/dev-run.sh --no-emulator    # 不自动启动模拟器（无设备直接报错）
scripts/dev-run.sh --device <serial> --emulator <name> --product default
scripts\dev-run.cmd                 # Windows 入口，转发到 dev-run.sh
```

环境变量：`EMULATOR_NAME`、`PRODUCT`、`DEVECOCLI_BIN`。

**两处平台适配，勿改回依赖 PATH**：`dev-run.cmd` 显式定位 Git Bash（由 `where git` 推导并校验）——部分机器上 PATH 里的 `bash` 会命中 WSL 启动器而失败；`dev-run.sh` 依次探测 `devecocli` / `devecocli.cmd` / `devecocli.exe`——Git Bash 不按 PATHEXT 补后缀。

### 6.1 签名：模板合成 + 本机缓存

仓库中的 `build-profile.json5` 是**模板**（`signingConfigs: []`）。脚本运行时由模板合成带签名版本，结束（含异常退出，靠 `trap`）**自动还原为模板**；本机签名缓存在 `.local/`（gitignore，不入库），按模板哈希判断是否需要重新生成，模板变化时自动重签。

因此 `build-profile.json5` 不应出现本地改动——`git status` 里看到它被改动即为异常。签名材料本身仍由 `devecocli signature generate` 生成到本机 `~/.ohos/config/`，不入库。

**一次性手动步骤（脚本只提示、不代为执行）**：`devecocli auth login`（脚本仅做登录态预检）、`devecocli emulator license accept`（脚本不代为同意协议）。

### 6.2 pre-push 钩子

`scripts/hooks/pre-push` 逐个提交检查，拒绝推送含签名配置的 `build-profile.json5`。`dev-run.sh` 会自动执行 `git config core.hooksPath scripts/hooks`。

CI 门禁（顺序：依赖安装 → 代码检查 → 构建）：

```bash
scripts\ci-windows.cmd              # 需先设置 CLT_HOME 与 JAVA_HOME
scripts\ci-windows.cmd --no-install # 跳过依赖安装
```

CI 已知限制：`codelinter.bat` 退出码恒为 1，脚本改读其 JSON 报告判定；CI 不签名、不安装、不做设备测试；真机验收为人工门禁。触发条件仅为 `pull_request → main` 与 `push → main`。

## 7. ArkTS 编码约束

ArkTS 不是任意 TypeScript，写 `.ets` 前加载 `arkts-grammar-standards` skill。红线：

- 禁止 `any` / `unknown`（用户明确允许时除外）；禁止 `as` 类型断言。
- 禁止结构化类型，用显式继承；禁止动态属性访问（`obj[dynamicKey]`）。
- 对象字面量必须有明确类型上下文（带类型变量或带类型函数参数）。
- 对外接口使用明确类型；错误必须可理解并保留定位信息。
- 长耗时调用异步执行，不阻塞 UI；页面离开、用户取消、进程终止分别定义行为。
- 持久化结构带版本与升级策略；系统写入操作要有稳定 ID 与结果记录。

## 8. Git 与协作

- 长分支：`main`（可集成、可演示）+ `dev/ux`、`dev/agent`、`dev/platform` etc；功能短分支从对应 `dev/*` 切出。
- **禁止直接推 `main`，禁止 force push**；PR 至少 1 人评审，建议 squash merge。
- 提交格式：`类型(范围): 中文描述`，如 `feat(calendar): 增加日程确认卡片`。类型：`feat / fix / docs / style / refactor / perf / test / build / ci / chore / revert`。
- 单提交只做一个逻辑变化，不混入无关格式化或依赖升级。
- 改变接口、权限、行为或配置时，在**同一个 PR** 中更新相关文档。
- 交给 AI 的任务说明应包含：目标、spec、SDK/API、允许修改范围、约束、验收方式。

## 9. 文档与 spec

- 文档语言中文，技术名词保留原文，中英文间留空格。
- 功能 spec 按用户闭环划分，文件名 `NN-功能名.md`，模板见 [specs/_模板.md](specs/_模板.md)。
- spec 描述顺序固定：`用户流程 → 页面事项 → 业务与 Agent 事项 → 平台能力 → 验收方式`。
- 状态流转：`待确认 → 已确认待实现 → 已实现待验收 → 已验收 → 已下线`，状态变化附版本与证据。
- 验收必须覆盖四类路径：正常、异常、权限拒绝、模型失败。
- 跨模块契约先形成共同理解再并行实现；页面可用固定样例，核心可用假适配器。

## 10. 常见坑

- 页面白屏：`EntryAbility.onWindowStageCreate` 必须 `loadContent`，且与 `resources/base/profile/main_pages.json` 清单一致。
- `HAR` 不能声明 UIAbility / AbilityStage，也不宜依赖 `AppScope` 资源；HSP 不能独立上架。
- 同一设备类型只允许一个 `entry` 类型 HAP。
- `.sh` 必须 LF、`.cmd/.bat` 必须 CRLF、`scripts/hooks/*` 必须 LF（无扩展名，已在 `.gitattributes` 单独约定），改动脚本注意行尾。
- 签名相关改动、`.local/`、`build/`、`.hvigor/`、`oh_modules/`、`.idea/` 均被 gitignore，不要试图提交。
- 进程被回收后不假设 Agent 自动续跑；「草稿生成 / 日程创建 / 提醒注册 / 提醒送达」不可混为成功。
