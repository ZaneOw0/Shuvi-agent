# PDF 高清屏渲染验证

日期：2026-10-28。分支：`refactor/rag-pdf`。基线：`8c9cf6a`（本轮先将既有 PDF.js 重构提交，再开始高清屏修改）。

## 用户流程

继续用已有资料打开原件预览；高清屏和捏合放大按实际像素密度重新渲染，显示尺寸及文件身份不变，无需重新解析、上传或生成向量。

## 页面事项

- Canvas CSS 宽高沿用适配页面的 viewport，位图宽高乘以屏幕密度与缩放倍率，并通过渲染矩阵同步缩放。
- 单画布保留 8MP 上限；倍率超出预算时限制实际像素密度，避免无界分配。
- 监听视口及分辨率变化，100ms 合并重绘；相同几何不重复绘制。
- 等待取消任务完成后再复用画布；翻页过程中重绘保持目标页，关闭后取消待执行重绘。

## 业务与 Agent 事项

只调整离线页面的渲染参数和调度，不修改 PDF 输入校验、协议、MinerU 或向量化实现。首次提交已排除 6 个锁文件的行尾差异；既有 CI 未跟踪文件未纳入。高清屏增量最初留在工作区，随后按用户明确要求单独提交；本轮不执行合并或推送。

## 平台能力

使用标准 Web API：`devicePixelRatio`、`visualViewport.scale`、`ResizeObserver`、`matchMedia`；不新增 ArkTS 系统 API、权限、依赖或服务。未提供有效密度信息时按 1 倍绘制。扫描图片本身的分辨率仍是清晰度上限。

## 验收方式与记录

使用实际 bridge.mjs 的 VM 执行与受控 PDF.js / DOM 端口，验证真实生产渲染代码传给 PDF.js 的 Canvas、viewport 和 transform；此层不是实机截图或真实浏览器光栅质量结论。

- 渲染专项 11/11：`.cache/test-logs/2026-10-27-pdfjs-hidpi-render-host-8c9cf6a/`。
- 完整宿主及后端受控链路 201/201：`.cache/test-logs/2026-10-27-pdfjs-hidpi-full-host-8c9cf6a/`。覆盖已有预检恢复、确认与拒绝、上传 / 查询 / 结果接收、统一内容发布、向量读回和中断恢复；SDK、文件及网络使用受控端口，真实业务请求 / 私有文件读取为 0，不等于本轮实云复验。完整回归内再次执行了渲染专项 11 项及既有加密 / 坏包 / 超限桥接检查。
- 本地构建 RC 0：`.cache/test-logs/2026-10-27-pdfjs-hidpi-build-only-8c9cf6a/`。仅执行 `devecocli build --product default --modules entry`；未使用签名缓存，工程模板字节不变。产物为 unsigned HAP，19,220,887 字节，SHA-256 `cce737777af298997cb45f30180a4c680ec68b8ada3ba31d2959b62fc4c591b0`。
- 宿主回归及构建记录的公开特性工作区指纹均为 `e734b2392041c1be4a6a2f91a6bcee7ad409b6c71f099d45822d7b0deffa7ae4`；此后只补本文结果并还原构建重新生成的 6 个锁文件行尾。

按用户指示，本轮模拟器接口、部署、实机演示、截图和真实云端请求均为 0。目录日期使用 UTC，本文日期按 Asia/Shanghai。

复现（Git Bash，使用现有 Node 与 SDK，不安装依赖）：

```bash
CAPTURE_HOST_ONLY=1 CAPTURE_SAFE_HOST=1 \
RUN_CMD='"/d/Huawei-DevEco-Studio/DevEco Studio/tools/node/node.exe" --experimental-vm-modules entry/src/test/pdfjs-render-host-cases.cjs' \
/c/Univ/Git/bin/bash.exe scripts/capture-test-log.sh pdfjs-hidpi-render-host

CAPTURE_HOST_ONLY=1 CAPTURE_SAFE_HOST=1 \
DEVECO_SDK_HOME='D:/Huawei-DevEco-Studio/DevEco Studio/sdk' \
RUN_CMD='"/d/Huawei-DevEco-Studio/DevEco Studio/tools/node/node.exe" entry/src/test/run-host-tests.cjs --unified-only' \
/c/Univ/Git/bin/bash.exe scripts/capture-test-log.sh pdfjs-hidpi-full-host
```

构建日志驱动保存在忽略目录 `.cache/pdfjs-hidpi/build.cjs`，只包装现有 CLI 的本地 build，原始工具输出留在 `.local/pdfjs-hidpi/`，公开输出仅 RC、模板一致性及产物摘要；capture 使用 `CAPTURE_HOST_ONLY=1`，不采集设备日志。

## 原生 PDF Kit 与后续收口

新文件的正式装配已由 `DocumentParseAssembly` 选择 `PdfJsPreflight`，新资料详情通过 `PdfJsRuntime` / `PdfJsSurface` 预览；不是按平台自动切换的双引擎方案。`DocumentPdfPreflight` / `DocumentPdfWorker` 保留为原生诊断与对照测试；`PdfPageAdapter` / `PdfSourceView` / `PdfSourceSession` 仍被旧版 PDF 检索来源入口及原生映射样例引用，不是可直接删除的死代码。

后续应明确旧来源入口的跨平台迁移或保留策略，保留旧页码 / 区域证据语义；补充预览加载中返回、后台切换和来源释放的生命周期验证，以及多页、中文字体、扫描件、旋转裁切页和较大文件的样本矩阵。高清屏视觉及 ARM / 真机结果未在本轮重新验收，不能将宿主参数测试当作这些项目已通过。
