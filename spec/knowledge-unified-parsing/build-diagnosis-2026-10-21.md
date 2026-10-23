# Build 失败诊断报告

**日期**：2026-10-21。  
**状态**：诊断完成，构建失败，未修复。  
**授权范围**：独立诊断；只执行一次 `devecocli build --product default`，不重开上一轮 spec-verify，不修复、不 clean、不签名、不部署、不执行真实业务请求。  
**工程**：`/Users/zane/DevecostudioProjects/Shuvi-agent`，分支 `dev/rag`，HEAD `c78d79839f9a16aeee71aa2f91a57a3c1df87112`。

## 一、结论

本次失败已确定为 **ArkTS 编译错误**，失败任务为 `:entry:default@CompileArkTS`。不是因为没有模拟器而无法构建，也不是仅有警告导致无法判断。工具已进入实际编译阶段；其后阶段是否还能成功，本轮未验证。

同一次构建产生的 Hvigor 日志和结构化报告一致给出 **13 条编号、带文件定位的编译诊断，涉及 8 个文件、4 类问题**。编译器汇总原文为 `COMPILE RESULT:FAIL {ERROR:14 WARN:2106}`。13 条定位错误与汇总 ERROR 14 不一致，不能凭空补出“第 14 处代码错误”，也不能将日志里重复三次的错误块算成 39 个独立缺陷。

| 类别 | 可定位条数 | 错误码 | 本轮判断 |
|---|---:|---|---|
| 接口依赖结构兼容 | 1 | `10605030` | PDF 账本接口之间缺少显式名义类型关系 |
| 未收窄的异常重抛 | 5 | `10605087` | catch 变量未在重抛路径上确认为 `Error` 或其派生实例 |
| 可空作业变量被闭包捕获 | 6 | `10605999` | `job` 的 `undefined` 检查未使后续闭包内访问满足编译器类型要求 |
| 自定义组件方法名冲突 | 1 | `10505001` | 页面业务方法 `freeze()` 与 ArkUI 继承成员重名且签名不兼容 |

以上四类均为当前构建阻断项。清除任意一类都不能据此宣称其余问题已解决，更不能保证后续打包、签名或运行通过。

## 二、实际执行

| 项目 | 本次结果 |
|---|---|
| 实际构建次数 | **1 次**；没有重试或其他内部构建 |
| CLI 命令 | `devecocli build --product default` |
| CLI 入口 | `/Applications/DevEco-Studio.app/Contents/tools/node/bin/devecocli`，安装包版本 `1.3.5` |
| 开始 / 结束（UTC） | `2026-10-21T15:24:07.482Z` / `2026-10-21T15:24:13.304Z` |
| 北京时间 | `2026-10-21 23:24:07` 至 `23:24:13` |
| 外层 CLI 退出码 | `1` |
| CLI 报告的底层 Hvigor 退出码 | `255`，不是外层 CLI 退出码 |
| Hvigor 报告耗时 | `BUILD FAILED in 3 s 970 ms`，不等于整个 CLI 调用耗时 |
| 失败任务 | `:entry:default@CompileArkTS` |
| checker / host 回归 | 本次均未执行；没有源码编辑，不重复上一轮 checker 或测试 |
| 修复 / 配置调整 / clean | 全部 0 |
| 签名 / 安装 / 模拟器操作 / 真实业务请求 | 全部 0 |

构建日志显示资源编译等前序任务已完成或为 `UP-TO-DATE`，然后在 ArkTS 编译中失败。本轮没有成功构建证据，不将输出目录中的旧 HAP 当成本次制品。

`WARN:2106` 是编译器汇总的全量警告数。已取得的 CLI 警告样本主要为系统 API 异常处理和设备能力支持提示；本轮未逐条审计全部警告，不把它们当成 2106 处已确认运行时缺陷，也不将 warning 数量冒充本次 fatal error 的原因。

## 三、定位清单

以下路径均相对 `entry/src/main/ets/knowledge/`；行列为本次编译器报告值。

| 编号 | 文件与行列 | 错误码 | 诊断 |
|---:|---|---|---|
| 1 | `infra/PdfAssetAdapter.ets:287:55` | `10605030` | `Structural typing is not supported (arkts-no-structural-typing)` |
| 2 | `infra/VectorRdbRepository.ets:176:49` | `10605087` | `"throw" statements cannot accept values of arbitrary types` |
| 3 | `infra/ParsedDocumentAssets.ets:43:65` | `10605087` | 同上 |
| 4 | `application/ParsedDocumentIngestionService.ets:68:7` | `10605087` | 同上 |
| 5 | `infra/ParsedDocumentAdapters.ets:56:80` | `10605087` | 同上 |
| 6 | `infra/DocxResultReader.ets:35:73` | `10605087` | 同上 |
| 7 | `application/UnifiedProcessingQueue.ets:135:214` | `10605999` | `'job' is possibly 'undefined'` |
| 8 | `application/UnifiedProcessingQueue.ets:147:126` | `10605999` | 同上 |
| 9 | `application/UnifiedProcessingQueue.ets:147:183` | `10605999` | 同上 |
| 10 | `application/UnifiedProcessingQueue.ets:147:226` | `10605999` | 同上 |
| 11 | `application/UnifiedProcessingQueue.ets:148:44` | `10605999` | `UnifiedProcessingJob \| undefined` 不能传给 `UnifiedProcessingJob` 参数 |
| 12 | `application/UnifiedProcessingQueue.ets:152:138` | `10605999` | `'job' is possibly 'undefined'` |
| 13 | `ui/KnowledgeMigrationView.ets:38:17` | `10505001` | `freeze` 与基类 `CustomComponent` 的同名成员类型不兼容 |

### 3.1 PDF 账本接口名义关系缺口

`PdfAssetAdapter` 的成员 `ledger` 声明为本文件第 22 行定义的 `PdfAssetLedgerPort`。第 287 行将它作为第二个参数传入 `PdfImagePayloadExporter`，而后者构造器在 `infra/PdfImagePayload.ets:11` 要求 `PdfImageDescriptorPort`。

`PdfImageDescriptorPort` 在第 8 行声明 `assetDescriptor(id)`。`PdfAssetLedgerPort` 第 32 行虽有同名同形方法，但没有显式继承该窄接口。这里依赖的是两个不同接口的结构兼容，触发 ArkTS 的名义类型限制。问题不在 JPEG 字节、图片导出返回值或图像运行时解码。

依据：本机官方《从 TypeScript 到 ArkTS 的适配规则》中的 `arkts-no-structural-typing`，错误码 `10605030`。

### 3.2 五处异常重抛的共同问题

五处代码都在 catch 后执行清理、检查或状态更新，然后直接抛出该 catch 变量。当前路径没有将该变量收窄为允许抛出的 `Error` 或派生类实例。

`ParsedFailure`、`KnowledgeFailure`、`DocxFailure` 本身均继承 `Error`，所以不能把问题归因为这些领域异常类缺少继承，也不能据此认定运行时异常一定不是 `Error`。`ParsedDocumentIngestionService` 在构建错误消息时使用的领域类型判断，仅影响消息表达式，并未保证后续所有重抛路径的类型。

这几处还承担回滚、释放租约、取消检查、保留 Markdown 降级或刷新状态等语义。只做机械性的通用异常替换，可能损失原异常类型、堆栈、对象身份与 `category/stage/code` 等定位字段；清理操作自身的失败也可能覆盖原始失败。这里是后续评审需保留的语义风险，不是本次新增的运行时复现结论。

依据：同一官方适配规则的 `arkts-limited-throw`，错误码 `10605087`，只允许抛出 `Error` 或其派生实例。本次没有提出或应用修复代码。

### 3.3 队列闭包中的可空作业类型

`UnifiedProcessingQueue.ets:128` 将 `job` 声明为可变的 `UnifiedProcessingJob | undefined`。第 133 行已检查无作业时返回，但后续第 135 行的 `find` 回调、第 145–149 行的异步准入回调及第 152 行的视觉回调继续捕获该变量。

编译器在这些闭包访问及传参处仍将 `job` 视为可能 `undefined`，因此形成六条诊断。这不是六种独立业务故障，也不是缺少作业数据的设备实测结果。现有源码已经有空值检查，具体问题是检查之后的可变联合类型在闭包使用点仍未满足编译期要求。

本轮未通过运行时代码验证队列并发行为，不将该诊断外推为已经发生错误派发、额外收费或数据损坏。

### 3.4 迁移页面业务方法与组件成员冲突

`KnowledgeMigrationView.ets:38` 声明的业务方法 `freeze()` 返回 `Promise<void>`，用于冻结迁移范围；第 60 行按钮调用它。ArkUI 组件继承链中已有 `freeze(boolean)` 通用成员，返回组件属性类型。

本机 API 26 SDK 的 `ets/component/common.d.ts:19691` 和第 `19713` 行提供该成员的重载。编译器因此报告业务方法与 `CustomComponent` 同名成员不兼容。这不是迁移服务冻结批次算法的失败，也不是 UI 点击后才发生的问题。

## 四、为什么前面只看到了失败退出码

本轮发现两个不同的可观测性问题，不能与应用编译错误混为一谈：

1. **仓库公共日志过滤为整份隐藏。** `scripts/dev-run-support.cjs:317` 的 `publicOutput` 在全文命中敏感关键词后隐藏整份输出，第 320 行规则包含不带词边界的 `token`。因此即使仅出现编译器符号名，也存在误触发的可能。上一轮公开日志确实只有 withheld 提示，但未回读其隐藏内容，不能断言它具体由哪个词触发。本次没有改过滤器。
2. **本轮 CLI 返回的编译正文不完整。** 新 CLI 输出只保留到警告编号 286，正文中间即转入 `hvigor build failed`；同次 Hvigor 文件日志和分析报告实际含完整错误块。因此只看 CLI 返回文本会漏掉真正的编译诊断。本轮只读提取本次生成的文件，未读取旧隐藏原始日志，未再次构建。

只读核对安装代码后，**未发现 CLI 对普通 build 设置固定正文长度或警告数量上限**。launcher 的 `cli.js:49` 使用继承输出；实现包 `@deveco/deveco-cli-common/dist/cli.js` 第 20 行构建适配器也继承 stdout/stderr，第 26 行错误提取未裁剪正文。因此不能将第 286 条处停止直接归因为“CLI 固定截断”。本次采集器也没有报告缓冲超限或调用错误。

Studio 随附 Hvigor 的 `src/cli/handler/client-event-handler.js` 存在输出写入后收到终态即退出、没有显式等待输出排空的路径，但实际 workspace 解析的 Hvigor 副本未在本次核实。该行为仅是可能的进一步调查方向，**不是已证明的本次丢失原因**。本轮不更改工具、不重跑构建来验证该假设。

本次采集器位于仓库外临时目录，子进程输出不直接进入 AI 上下文；仅保留脱敏的任务阶段、诊断文本、文件行列和统计。没有保存原始 stdout/stderr，没有读取凭据、认证原始流或签名材料。

## 五、既有测试结论的边界

上一轮 90 文件 checker 无诊断、实施阶段 150/150 host 通过，仍然是各自范围内的历史结果，不应抹除。但本次真实 `CompileArkTS` 已明确报告上述错误，所以它们不能证明工程可构建。

`entry/src/test/unified-host-entry.cjs:129` 至第 138 行会将 UI 组件转为方法级测试类并去除 `build()`，随后用 TypeScript `transpileModule` 转译。该路径不是完整 ArkTS 编译，也不会验证真实 ArkUI 自定义组件继承、全部类型诊断或系统运行时行为。这解释了为何方法级 host PASS 与 `freeze()` 组件类型冲突可以同时存在。

本轮没有重新调用 checker，因此不能进一步断言 checker 漏报的内部原因；本轮也不验证真实模型、生产迁移、语义质量、平台数据库或 UI 操作。

## 六、证据与未改动核对

独立 capture 目录：

- `.cache/test-logs/2026-10-21-knowledge-build-diagnosis-c78d798/`：唯一 build，`meta.txt` 的 `run_cmd_exit=1`。
- `.cache/test-logs/2026-10-21-knowledge-build-diagnosis-readback-c78d798/`：只读提取本次构建文件，`run_cmd_exit=0`；该步骤 build 次数为 0。

允许阅读的脱敏证据：

- `.cache/test-logs/knowledge-build-diagnosis-20261021.sanitized.json`：CLI 阶段、警告样本、一次构建计数与前后 hash。
- `.cache/test-logs/knowledge-build-diagnosis-20261021.readback.sanitized.json`：仅本次 Hvigor 文件日志/分析报告的脱敏错误及来源身份。

本次 capture 的实际命令如下。临时构建采集器有一次性标记，已消耗；这些命令是审计记录，不应直接再次执行。只读提取采集器不含构建调用。

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='node /var/folders/nf/pb46rg9s22nbdsfm6kr463sr0000gn/T/deveco/build-diagnosis-20261021.cjs' \
/bin/bash scripts/capture-test-log.sh knowledge-build-diagnosis

CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='node /var/folders/nf/pb46rg9s22nbdsfm6kr463sr0000gn/T/deveco/build-diagnosis-readback-20261021.cjs' \
/bin/bash scripts/capture-test-log.sh knowledge-build-diagnosis-readback
```

下列构建日志/报告来源的 mtime 均落在本次 build 时间窗口内；没有读取轮转旧日志：

| 本次工具生成来源 | mtime（UTC） | SHA-256 |
|---|---|---|
| `.hvigor/outputs/build-logs/build.log` | `2026-10-21T15:24:13.001Z` | `13ab7759dd7324a2243cf2d6236151102a803b0052688a9819f3e4aaca9d60cd` |
| `.hvigor/report/report-202610212324090040.json` | `2026-10-21T15:24:12.985Z` | `5244f4182fbe560841867dd2a397d89ad23e6de9b8396de31faeb858fa976eb1` |

构建前后核对了交接中 90 个 ETS 文件及 11 个关键工程配置/日志脚本，共 **101 文件**，哈希完全相同：

- ETS 集合 SHA-256：`c89dff9edb669ad2e91fcc00bf778c620ffa587107d00978864c7709a8e6b99b`。
- 101 文件集合 SHA-256：`2f7bab1e267b3671dd566be90953a2d5d305ef7cba48483eac9f23f6b9b1f66a`。
- capture 指纹：`c92d4cd84cf49800b88d1e3c2aae0334c20b9a40b25688ad2d8713b4ee9d853f`；其 scope 为公开 feature host 范围，不冒称全盘取证。

没有修改应用源码、现有工程配置、日志过滤器、旧 spec/plan/tasks 或上轮验证报告。现有 dirty/untracked 工作保留。构建正常更新 ignored 构建缓存与报告，不属于源码修复。仓库新增交付仅本中文报告，诊断证据保存在 ignored `.cache/`，临时采集器保留在仓库外；没有 Git 写操作。

官方依据通过本机 `devecocli docs search/read` 读取，文档 ID 为 `开发指南/学习ArkTS语言/从TypeScript到ArkTS的适配指导/从TypeScript到ArkTS的适配规则/typescript-to-arkts-migration-guide`。组件 `freeze` 签名另与本机 API 26 的 `common.d.ts` 逐项核对。没有依据搜索摘要猜测其他新 API。

## 七、后续边界

本次已完成“定位 build 失败并提交报告”的目标，**未执行任何修复**。当前至少存在本报告列明的四类构建阻断，后续需要独立授权修复和重新构建；本报告不将其转为默认修复任务，不启动安装或其他测试。
