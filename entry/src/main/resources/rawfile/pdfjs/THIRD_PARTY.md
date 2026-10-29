# PDF.js 离线实验资源

- 上游：Mozilla PDF.js / pdfjs-dist，https://github.com/mozilla/pdf.js
- 固定版本：6.4.299，Apache-2.0；LICENSE 及字体、CMap、WASM 子许可保存在 vendor 各目录。
- 官方发行包：https://registry.npmjs.org/pdfjs-dist/-/pdfjs-dist-6.4.299.tgz
- 发行包校验：sha512-AVl138zALtfaAPvADulE0PZThbYzCBS79nL4pOSL/6Sm/4AH5A21BD9VHt97OlCuzJuCpmeZtAtkinisF4Vb1g==
- 取用 legacy/build/pdf.mjs、legacy/build/pdf.worker.mjs、cmaps、standard_fonts、wasm、iccs；未修改上游文件。
- 页面和库从应用 rawfile 离线加载。https://shuvi-pdf.invalid/ 为 ArkWeb 请求拦截器内部映射的虚拟同源地址，不提供网络服务。外部地址一律返回阻断响应，原件通过受限分块桥接传递。

同页执行的 PDF.js worker handler 仍使用真实 PDF.js 解析器，属于固定版本的内部适配点，不是 Mock 解析。升级必须同时验证桥接、加密拒绝、页数、渲染及上述静态资源。
