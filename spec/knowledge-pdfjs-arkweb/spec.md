# PDF.js + ArkWeb 实验

日期：2026-10-27。分支 `refactor/rag-pdf`，基线 `dev/rag` / `86ca813`。用户已明确授权 PDF.js + ArkWeb 试验及新分支，新增依赖仅为离线 PDF.js 6.4.299；不增权限、服务或 Native 库。

## 用户流程

Windows x86 模拟器导入 PDF → 本机 PDF.js 检查真实字节、加密与 1–50 页 → 当前文件明确确认 → 原 MinerU 上传 / 解析 / 结果接收 → 统一正文发布 → 获准正文向量生成与完整读回 → 同一份原件 PDF.js 预览。旧资料不自动重新上传或重嵌入。

## 页面事项

资料详情新增「查看 PDF 原件」；本机重试预检和确认解析保留。预览使用持久 ArkWeb 页面，同一引擎读取原字节并渲染 Canvas，显示原件页码、上下页及关闭；不将服务生成的 PDF 或 Markdown 冒作原件。

2026-10-28 高清屏增量：CSS 显示尺寸与 Canvas 位图尺寸分离，以 `devicePixelRatio` 及捏合缩放倍率计算实际渲染密度；屏幕密度 / 视口变化合并重绘，单画布仍限 8MP。取消任务完成后才复用画布，重绘保留用户正在请求的页码。依据为 [PDF.js 高清屏示例](https://mozilla.github.io/pdf.js/examples/)、[devicePixelRatio](https://developer.mozilla.org/en-US/docs/Web/API/Window/devicePixelRatio) 与 [VisualViewport.scale](https://developer.mozilla.org/en-US/docs/Web/API/VisualViewport/scale)。验证见 [高清屏验证记录](hidpi-verification.md)。

## 业务与 Agent 事项

原件桥接前复核大小与 SHA-256，分块传送受限输入，不把文件路径或凭据暴露给网页。RPC 回执做字段 / 版本 / 身份 / 输入字节数与页数校验；取消、引擎重建与超时失败保留原件。预览持有现有原件保护，关闭后释放。三库、旧快照 / wire / 向量空间与外发守卫不变。

## 平台能力

使用 API 26 ArkWeb 的 Web、WebviewController.runJavaScript 和 onInterceptRequest / WebResourceResponse。依据为本机官方「使用 Web 组件加载页面」「ArkWeb 本地资源跨域问题和解决方案」及已安装 SDK 声明；异步 PDF.js 结果通过有界轮询读取。静态资源仅本机虚拟同源映射，禁止外部网页、脚本、跨域资源和 PDF 脚本执行。不依赖 x86 缺失的 PDF Kit。

## 验收方式

真实验证只使用自制非敏感 1 页 PDF。已有明确授权包括 MinerU 最多 1 次申请 / 1 次上传 / 90 次查询 / 1 次 ZIP，接受可能费用；用户在本轮再次明确确认「有本次免费额度，继续测试」。本轮目标进一步明确包含向量化。语料嵌入仅限该自制文档，最多 4 块，不发送其他用户资料；不测试问题向量或视觉模型。若实际分块超限则停止并记录。

分报源码回归、独立 ArkTS 检查、实际构建、Windows 模拟器本机预检与原页、真实 MinerU 回执、真实数值向量与 Synced 读回。正常、坏包 / 超限、拒绝外发 / 加密、服务失败分别验证。所有执行经 capture 保存日志，尚未执行的项目不标成功。

2026-10-28 本轮只验高清屏参数、重绘调度和既有后端受控链路；按用户要求不调用模拟器接口、不部署、不截图，不继承上一轮授权重新发送样本或调用模型。用户此前反馈的 PDF 完整链路实测保持为用户验收记录，不冒称本轮 Agent 重新执行了真实云端验证。
