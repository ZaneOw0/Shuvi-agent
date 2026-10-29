# PDF 入口与生命周期收口

日期：2026-10-28。分支 `refactor/rag-pdf`，基线 `cc97379`。状态：已实现，本轮约定的宿主测试与本地构建完成；设备 / 样本验证按用户要求排除。

## 用户流程

本轮用户明确限定 Windows x86 模拟器使用场景，不考虑 ARM / 真机；不做样本回归、模拟器接口操作、实机复验或云端请求。资料详情及旧检索 PDF 来源均进入同一个离线 PDF.js 原件预览器。

导入保存原件 → 用户确认外发 → MinerU 原任务 → 统一正文 / 向量链路不再依赖 PDF 本机预检。删除 PDF 预检按钮、重试动作、预检端口、PDF.js / 原生 PDFKit 预检实现及对应诊断用例；不调用预览引擎来决定能否上传。不再在提交前核定 1–50 页或加密状态；无效 / 加密 PDF 的云端处理结果通过已有错误路径返回。大小 / SHA-256 / 身份、费用及外发确认、远端占用、请求次数及结果接收资源限制继续生效。图片与 DOCX 的格式校验不变。

## 页面事项

- 详情预览与旧检索来源共享加载遮罩、关闭按钮、原页翻页和高清屏渲染；加载期间返回可取消。
- 旧检索来源仍要求审核通过的原页依据、当前 generation / snapshot / 原件版本，并跳至已核对页码；实际 PDF 页数须与旧证据一致。新预览只显示原页，不迁移原生区域高亮；旧区域证据与快照保留，不生成未经核对的区域框。
- 删除 PDF 的预检状态回显，历史预检失败不再阻止提交，也不伪写 Passed 或虚构页数。旧库中的预检列保持兼容读取，图片 / DOCX 仍使用原列。

## 业务与 Agent 事项

- 取得原件锁或旧来源租约之前，先建立可取消的预览会话；排队期间关闭后，不再读取原件。
- 原件分块传输、哈希计算、桥接结果读取均检查取消及引擎世代；连续打开取消前次，旧任务不能隐藏或覆盖新会话。
- 关闭取消渲染，等待 RenderTask 完成后才销毁 LoadingTask 及 worker、清空文档数据并将 Canvas 位图宽高归零。销毁异常或 5 秒内未确认释放会明确报错，并阻止直接复用未释放的引擎。
- 原件保护覆盖整个打开到关闭过程；旧来源以持久读租约保护，释放失败登记原有 source_release 表供现有重试入口处理。知识库会话关闭先等待 PDF 动作退出，再关闭原件库 / 知识库。
- 后台关闭当前预览；回前台不自动重开、不重新上传。页面离开 / 系统返回 / Ability 销毁取消当前任务；Web 页面重载或渲染进程退出使旧回执失效。引擎退出尝试刷新离线页面，显示需重开原件的异常。进程被系统终止后不自动恢复预览；沿用已有持久租约与会话恢复机制。

## 平台能力

沿用 API 26 ArkWeb；新使用 Web `onPageBegin` / `onPageEnd` / `onRenderExited`，`WebviewController.refresh()` 自 API 9 可用，无新增权限、依赖或服务。依据为本机官方 FAQ `FAQ/Web框架/Web开发_ArkWeb/如何避免多个页面同时触发onRenderExited回调/faqs-arkweb-187` 与安装 SDK 的 `component/web.d.ts`、`api/@ohos.web.webview.d.ts`。不改变应用全局 Web 渲染进程模式。

原生 `PdfPageAdapter` / `PdfSourceView` / 几何映射代码只保留给历史隔离诊断及对照用例，正式详情与检索来源不再实例化 PDFKit 控制器；本轮不扩展这些诊断在 ARM 上的能力。PDF 预检实现已删除。

## 验收方式

仅运行受控端口机制测试和本地构建；不读取用户 PDF、不跑文档样本矩阵、不访问模拟器 / 设备 / 业务云。宿主测试不能作为 ArkWeb 实际光栅质量或真实 MinerU / 向量服务验收。测试与构建日志及复现命令在完成后追加下方。

- 统一链路最终宿主 **204/204**，真实业务请求 / 私有文件读取均为 0：`.cache/test-logs/2026-10-28-pdfjs-unify-host-cc97379-4/`。其中执行真实生产桥接与调度代码的受控 VM 渲染 11/11、桥接 / 释放 11/11；SDK、文件与传输均为受控端口，非真实浏览器 / 云端证据。
- 解析策略与服务定向宿主 **72/72**：`.cache/test-logs/2026-10-28-pdfjs-unify-parse-policy-cc97379-3/`（命令 RC 0，测试原始输出留在本机忽略目录 `.local/pdf-unify-policy/`，公共日志过滤涉及凭据的用例名）。覆盖 PDF 历史失败 / 未知页数不阻提交、未同意 / 凭据 / 预算仍阻断、上传前摘要校验，以及既有上传 / 查询 / 接收 / 恢复。同步修正两项旧测试对 PDF 提交前可见异常的过时预期，不改变生产异常约束。
- ArkTS 独立检查：`.cache/test-logs/2026-10-28-pdfjs-unify-check-cc97379-4/`，RC 1，仅剩 5 处工程 `BuildProfile` 虚拟生成模块无法单独解析的既有限制，未伪造替代模块；不能记录为独立检查通过。初次检查还发现一处任意类型重抛，已修复。
- 最终完整构建 **RC 0**（含 CompileArkTS）：`.cache/test-logs/2026-10-28-pdfjs-unify-build-only-cc97379-2/`。只执行 `devecocli build --product default --modules entry`，工程模板字节不变；unsigned HAP **19,186,681 字节**，SHA-256 `ea8d37f611a0bfb8d67df88929255f617d5da929e2814d94e236d6cd0d7a3082`。使用忽略目录 `.cache/pdfjs-hidpi/build.cjs` 包装本地 build，未读取签名缓存、未调用 run / device / emulator。
- 最终统一宿主与构建的公开工作区指纹一致：`e8728db4c4bebfc15e95e119979af945a9eb929594882ea6332200920fd46b04`。此后仅补充本文结果及还原 6 个锁文件行尾；既有未跟踪 CI 交接文件保持原样。本轮不执行 commit / merge / push。
- 保留首轮失败记录：统一宿主首轮 200/202，修正受控上传租约 ID 必须有 `lease-` 前缀、来源测试租约字段后通过；解析定向前两轮因旧测试未断言已存在的提交异常而失败，修正测试后 72/72。没有放宽业务校验以通过测试。

复现（Git Bash；使用现有工具，不安装依赖）：

```bash
CAPTURE_HOST_ONLY=1 CAPTURE_SAFE_HOST=1 \
DEVECO_SDK_HOME='D:/Huawei-DevEco-Studio/DevEco Studio/sdk' \
RUN_CMD='"/d/Huawei-DevEco-Studio/DevEco Studio/tools/node/node.exe" entry/src/test/run-host-tests.cjs --unified-only' \
/c/Univ/Git/bin/bash.exe scripts/capture-test-log.sh pdfjs-unify-host

CAPTURE_HOST_ONLY=1 CAPTURE_SAFE_HOST=1 \
DEVECO_SDK_HOME='D:/Huawei-DevEco-Studio/DevEco Studio/sdk' \
RUN_CMD='"/d/Huawei-DevEco-Studio/DevEco Studio/tools/node/node.exe" --test --test-name-pattern=DocumentParse entry/src/test/run-host-tests.cjs' \
/c/Univ/Git/bin/bash.exe scripts/capture-test-log.sh pdfjs-unify-parse-policy
```

定向测试原始 reporter 的用例名含敏感词会触发公共日志整体过滤；本次实际通过忽略目录 `.cache/pdf-unify-policy.cjs` 包装同一命令，将原始输出私有化，仅公开退出码和去敏诊断。检查包装器 `.cache/pdf-unify-check.cjs` 执行 `devecocli check arkts --project <repo> <本轮 ETS 清单>`。所有 capture 均设置 `CAPTURE_HOST_ONLY=1`，设备日志未运行。

## 2026-10-28 关闭预览后的释放误报修复

用户随后反馈：每次查看 PDF 原件后都出现「PDF预览资源释放未确认，请重新打开页面」。根因是本轮新增释放轮询将 ArkWeb 的返回结果直接与裸字符串 `Released` / `Releasing` 比较；实际字符串按 JSON 编码传回，带有引号，导致成功与进行中回执都进入错误分支。依据为 [OpenHarmony WebviewController.runJavaScript 官方说明](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkweb/arkts-apis-webview-WebviewController.md#runjavascript-1)：前端传回的 string 需要 JSON 反序列化。此前宿主控制器桩直接返回裸字符串，未模拟此编码差异，因此漏检。

修复在网页内严格比较已知状态，再跨桥接返回数字：1=确认释放，0=等待，-1=实际失败，-2=未知状态。保留原 5 秒等待及真实失败 / 未知回执阻断，没有将错误吞掉或取消释放校验；所有相关宿主控制器桩改成 JSON 编码结果。对正常关闭后再次打开、进行中转成功、未知状态拒绝补充断言。

- RED 证据：`.cache/test-logs/2026-10-28-pdfjs-release-encoding-red-cc97379/`，在符合官方规则的编码桩下复现相同错误。
- 修复后统一宿主 **206/206**，业务请求与私有文件读取均为 0：`.cache/test-logs/2026-10-28-pdfjs-release-encoding-host-cc97379/`。
- 独立检查：`.cache/test-logs/2026-10-28-pdfjs-release-encoding-check-cc97379/`，仍仅有上述 5 处既有 BuildProfile 生成模块问题，不冒称通过。
- 完整构建 **RC 0**：`.cache/test-logs/2026-10-28-pdfjs-release-encoding-build-cc97379/`，模板字节不变。unsigned HAP 19,186,817 字节，SHA-256 `4b873b1ee786e3a1a7a54d6c03baeff2435da7f047f8ecdd366423bac6b25aec`；仅构建，未安装。
- 本轮未调用设备接口或部署；以上是代码和宿主复现，不冒称已在用户截图对应模拟器复验。

复现沿用上方统一宿主命令，将 scope 改为 `pdfjs-release-encoding-host`。
