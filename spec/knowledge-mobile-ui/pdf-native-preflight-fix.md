# 原生 PDFKit 预检恢复与解析状态回显修复

日期：2026-10-27。分支：`dev/rag`，基线 `5a2e058`。状态：已实现，最终统一宿主 196/196、实际构建通过；ARM 模拟器 / 真机成功路径由用户验收。本轮保留原生 PDF Kit，不引入替代库，不升级 SDK、增加权限或改变数据库结构。

## 用户流程

PDF 原件保存后，先做文件签名与原生页数 / 加密预检。详情内「仅重试本机PDF预检（不发送）」可恢复旧的预检阻止记录，无需删除重导，不形成外发授权或云端任务。点击「解析这份文件 → 同意发送并解析」时，对尚无云任务的 PDF 先复核原件和预检，成功后才保存逐文件确认并进入既有申请、上传、查询与结果接收链路；已有任务沿原身份继续。

## 页面事项

- 列表将未通过预检的 PDF 标为「PDF预检未通过」；详情显示具体预检原因，不继续以「可开始解析」掩盖阻断。
- 本机重试和真实解析期间显示处理消息。服务层正常返回的 NoRequest 消息以及抛出的异常均回显，失败后保留原件和状态，不把短暂刷新当成成功。
- PDF 预检失败不生成新的确认或云任务；本机重试不会启用全局解析、读取 / 更新 Key、申请上传或下载结果。
- 本机能力诊断增加「隔离PDFKit预检（不联网）」；不支持的设备仅报告缺少能力，支持的设备使用隔离自制一页 PDF 检查直接加载与正式预检适配器。

## 业务与 Agent 事项

- `DocumentPdfWorker.ets` 将原生对象封装在独立 `@Concurrent` 工作线程。返回固定六项数值回执：结果、页数、ParseResult、操作阶段、SDK 错误码、释放错误码；原生对象与原始异常不跨线程传递。
- 采用官方文档的同步 `loadDocument(path, '')` 用法，工作线程在调用前后检查取消 / 截止时间。不将移除进度回调宣称为已证根因；本轮实际定位的是 Windows 模拟器的模块缺失。
- 在创建原生对象前检查 `SystemCapability.OfficeService.PDFService.Core`，构造、加密检测、加载、页数读取和释放均有明确失败处理；取消原先多个失败合并为泛化 `-5` 的诊断丢失。
- 主线程复核 PDF 文件签名、运行时校验数值回执，完整成功才发布 1–50 页证据并清除旧错误。能力不足、坏文件、加密、超时、取消、释放失败及不合法回执均不产生默认页数。
- `retryPdfPreflight` 在来源保护内校验原件 hash / 大小后重新预检并持久化。已存在云任务的文件拒绝重建预检提交；摘要不符、预检或持久化失败时抛出 `DocumentParseFailure` 并保持外发阻止。
- PDF 提交前的门禁拒绝既更新状态消息也抛出类型化异常；其他格式维持原行为。未修改解析许可、免费确认、请求限额或旧任务恢复策略。

## 平台能力与依据

沿用 HarmonyOS API 26 的 PDF Kit、ArkTS taskpool、文件系统、RDB 与既有安全存储。官方 `PdfDocument.loadDocument`、`isEncrypted`、`getPageCount`、`releaseDocument` 使用 `SystemCapability.OfficeService.PDFService.Core`，起始 API 12；未引入新的平台能力。

官方 [PDF Kit 简介](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/pdf-introduction) 明确支持 ARM 模拟器、不支持 x86 模拟器。本机文档取证使用：

```bash
devecocli docs read '开发指南/PDF_Kit_PDF服务/PDF_Kit简介/pdf-introduction'
devecocli docs read 'API参考/PDF_Kit_PDF服务/ArkTS_API/pdfService_PDF服务/pdf-arkts-pdfservice'
```

当前 Windows `Phone26 / 127.0.0.1:5555` 的隔离测试得到 `pdfService` 未提供；用户两份 PDF 的旧记录均为页数 0、预检阻止、有确认但没有云解析任务。没有将该限制归因于用户文件损坏。禁止为在 x86 上跑通而跳过预检、伪造页数或借用其他文件证据。

## 验收方式与证据

最终统一宿主回归 **196/196**，真实业务请求 0、私有文件读取 0，使用内存文件 / SQLite、SDK 与受控网络替身。新增 11 项覆盖工作线程成功 / 加密 / 页数 / SDK / 取消超时 / 释放失败、回执校验、旧预检恢复、摘要与持久化失败、提交拒绝抛异常、详情错误与 NoRequest 消息保留、仅本机重试和适配器真实调用链。成功任务的受控传输覆盖申请 → 上传 → 查询 → 结果接收，不能替代 MinerU 真实成功或 ARM 原生证明。

- 最终宿主：`.cache/test-logs/2026-10-27-pdfkit-native-final-host-5a2e058/`，cmd_exit=0，工作区指纹 `781962535f0376c12360555cedb4b02dfd1265ba5fb898dd008f076730667a20`。
- 最终独立检查：`.cache/test-logs/2026-10-27-pdfkit-native-final-check-5a2e058/`，原始 checker RC 1，仅四处既有 `BuildProfile` 导入诊断；本机驱动记录该限制后返回 0，不能将驱动 RC 0 写成 checker clean。
- 最终实际构建：`.cache/test-logs/2026-10-27-pdfkit-native-final-build-5a2e058/`，`CompileArkTS`、`SignHap` 与 build 均成功，工作区指纹 `f33b42f579a3169d8101e2f3ab8d90d8bc3a5dbe484ef34fa300dd86b2e2e163`。该轮是 build-only，未安装或触发设备业务；通过现有 `dev-run-support.cjs` 的所有权锁复用匹配签名缓存，结束时按字节恢复模板，不生成新签名或修改 Git 配置。
- signed HAP：12,182,859 字节，SHA-256 `f72d6feb7866374e84bebb69227f663955c6cd896de83656792b58f92e77b61b`。源码构建后未再修改，仅补本文验证记录。

本机最终构建复现：设置 `CAPTURE_HOST_ONLY=1`、`RUN_CMD='"/d/Huawei-DevEco-Studio/DevEco Studio/tools/node/node.exe" .cache/pdfkit-repair/verify.cjs build'` 后运行 `scripts/capture-test-log.sh pdfkit-native-final-build`。该 gitignore 本机驱动调用 `devecocli build --product default --modules entry`；ARM 上使用下方既有 macOS 启动脚本，无需依赖本机驱动。

独立 ArkTS 检查涉及详情页的导入闭包时，现有生成模块 `BuildProfile` 无法被检查器解析；本轮仅允许将这四处既有导入作为检查器限制记录，真实源码错误必须修复，最终由实际 `CompileArkTS` 验证。中间曾发现三处把 namespace 当对象使用的 ArkTS 错误，已移除该写法，不以 TypeScript 转译通过代替编译。

历史本机证据保留：

- `.cache/test-logs/2026-10-27-pdfkit-repair-host-5a2e058-2/`：191/191；受控传输最初缺少 removeLeases 替身，修正替身而未削弱业务约束。
- `.cache/test-logs/2026-10-27-pdfkit-repair-final-host-5a2e058/`、`pdfkit-native-delivery-host-5a2e058/`：194/194。
- `.cache/test-logs/2026-10-27-pdfkit-repair-native-build-5a2e058/`：初版构建与安装 RC 0，但该次日志未找到应用进程，log_exit=1，不冒报完整验收。
- `.cache/test-logs/2026-10-27-pdfkit-repair-native-probe-5a2e058/`：隔离诊断捕获 PDF 原生模块未提供，不是成功路径通过。
- `.cache/test-logs/2026-10-27-pdfkit-native-delivery-check-5a2e058/`：namespace 写法修正后，仅剩既有 BuildProfile 导入诊断。

宿主复现（Windows Git Bash；其他平台修改为本机 Node / SDK 路径）：

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
DEVECO_SDK_HOME='D:/Huawei-DevEco-Studio/DevEco Studio/sdk' \
RUN_CMD='"/d/Huawei-DevEco-Studio/DevEco Studio/tools/node/node.exe" entry/src/test/run-host-tests.cjs --unified-only' \
/c/Univ/Git/bin/bash.exe scripts/capture-test-log.sh pdfkit-native-final-host
```

## ARM 模拟器 / 真机验收步骤

1. 拉取 `dev/rag`，使用 Mac ARM 版 DevEco Studio、HarmonyOS SDK 与匹配 API 26 的 ARM 手机模拟器构建安装；不要使用 x86 镜像验证 PDFKit 成功路径。可使用现有 `scripts/dev-run-mac.sh --device '<serial>' --no-emulator`，继续遵守签名模板与缓存约定。
2. 「我的 → 高级诊断 → 本机能力诊断 → 隔离PDFKit预检（不联网）」。期望 `capability=1 direct=0 direct_pages=1 pages=1 passed=1 requests=0`；若显示 `expected_unavailable=1 passed=0`，停止云测试并核对设备能力。
3. 导入自制、非敏感、未加密且不超过 50 页的 PDF，或对旧阻止记录执行「仅重试本机PDF预检（不发送）」。期望真实页数、预检通过、旧错误清除；原件 hash / 大小不变，云任务数不增加。
4. 用户在应用内配置 MinerU，确认实际完整文件与免费资格后点击解析。观察申请、上传、解析、结果接收及自动本机入库，主页和详情正文 / 状态同步；向量增强状态单独判断。
5. 加密、坏签名、页数超限、取消、无凭据等路径应显示明确原因；不伪造成功、不新增未获准请求。已有云任务仅恢复原任务，避免重复申请。
6. 按 `scripts/capture-test-log.sh <scope> [窗口] '<serial>'` 留档并将结果补到本文，区分 ARM 模拟器、真机及云服务验证。

本轮曾获用户授权使用一份自制 1 页 PDF 进行最多 1 次申请、1 次上传、90 次查询、1 次结果下载，并接受可能费用；因当前环境不支持 PDFKit，实际请求仍为 0。最新安排由用户在 ARM 环境自行执行真实测试，不继承为自动发送其他资料的授权。
