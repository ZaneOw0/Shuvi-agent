# main 界面合并与知识库风格验收

日期：2026-10-22–23。开发分支 `dev/rag`；合并前基线 `5e8886e`，合并目标为远端最新 `origin/main` / `bfb5718`。用户明确授权本次 merge；不推送远端、不修改 main 分支。状态：已实现待验收；本文列举的模拟器主流程通过，真机及知识库新页面最大字体未验收。

## 用户流程

从新版侧栏进入知识库，在首页导入文件或搜索已入库资料；「我的资料」按文件管理，打开单份资料阅读正文、查看图片与处理进度。部分入库仍能逐任务重试，发送文件和语义问题仍保留原有范围、费用及持久授权校验。个人页统一进入解析、图片理解与嵌入设置，悬浮头像可返回助手。

## 页面事项

- 采用 main 的奶油白底、莓紫主操作、深紫正文、淡紫输入区与白色描边卡片，复用 Theme、AppIcon 和 FeatureRow，不新建图标或依赖。
- 搜索首页使用主知识库的「让知识，有处可寻」标题及导入/搜索/资料入口，接真实服务，不呈现样例文件或待接入占位。
- 搜索后收起首页介绍与导入区，切换为紧凑搜索布局；编辑关键词时保持布局，可明确返回首页。搜索结果使用统一卡片、命中依据、来源与分页；问题外发仍单次明确确认，翻页不增加问题向量请求。
- 文件类型选择和资料列表采用统一图标行，详情正文独立成卡。默认优先展示最多 3 个未完成任务，已完成任务折叠；可展开全部并单独重试。
- 图片详情、图片理解、嵌入与 MinerU 页面使用同一配色、输入框和按钮规范；旧手动检测提示收进相应流程，MinerU 转发能力说明折叠，避免与真实统一入库状态混淆；后台任务、模型发现/检测、任务与结果技术记录可展开。
- 工作台「文件管理」接入真实「我的资料」，不再提示待接入。个人设置取消重复按钮，调试入口收进高级诊断。知识库顶部明确本机资料未同步；演示场景与新对话按钮只在助手显示。保留 main 的侧栏、品牌素材、启动图标与可拖动悬浮入口。
- 资料库打开状态使用独立可观察字段；同次初始化共用一个 Promise，加载中禁止重复打开，失败保留资料并给出重试。

## 业务与 Agent 事项

- 冲突为 `Index.ets`、`FeaturePages.ets`、`specs/README.md`。手动合并新版外壳与知识库服务组装，保留 dev/rag 的 INTERNET 权限和已有设备类型，不引入新权限/服务。
- ParsedDocument、正文/OCR、图像标注与向量、自动队列、原任务恢复和数据库契约保持原实现。服务及原生资源仍以普通引用传递，不改为 @Prop 或 @State 包装。
- 修复重试标记作为失败原因展示：Pending/Running/Complete 不展示旧 failure；旧 401/403 在展示层明确为鉴权失败/服务拒绝，不重写历史任务或自动重发。
- 本次没有实现鉴权失败全局阻断、传输错误码采集或调整网络超时；专项诊断中的这些后续工作仍保留。
- 不清空数据库、不卸载、不删除现有资料、不更改 Key 或自动处理开关，不人工重试用户图片。

## 平台能力

沿用 API 26 的 ArkUI、既有系统文件选择器和服务适配器。UI 规范按本机 `hmos-arkui-develop-skill` 及其状态、渲染、组件签名与样式参考核对；本轮无新增系统能力。

## 验收方式与结果

- ArkTS 检查：修复一次误加的页面回调参数后通过；初始化展示修改后检查亦通过。
- 统一知识库 host：174/174，业务网络请求 0、私有文件读取 0。新增处理中授权标记隐藏与未完成任务优先展示回归；同步原入口移动后的定位检查，不减少原业务用例。
- 悬浮入口 host：9/9。首次未提供 DEVECO_SDK_HOME 导致 runner 启动失败，设置本机 SDK 路径后通过。
- 构建、保数据安装：已通过，签名缓存复用，build-profile 模板恢复。
- 模拟器视觉与交互：已验证新版侧栏知识库入口、首页真实导入/类型选择、PDF 系统选择器打开与取消、列表筛选/显示归档、文件详情、默认折叠完成任务、本机标签召回、个人页三类设置入口。紧凑搜索首屏可见图片命中、标签及来源按钮；工作台入口实际进入资料列表。图片结果可打开原图、描述与标签。不将上述 host 或构建当作设备验收。
- 本轮没有人工提交新的 MinerU/视觉/嵌入模型验收请求，也未点击语义发送确认或失败重试；启动应用按用户已启用的设置恢复有资格的自动队列，未更改自动设置；没有真机验收，不将已有数据的完成状态当作本轮新请求成功。

## 本机证据

- ArkTS：`.cache/test-logs/2026-10-22-knowledge-main-ui-check-5e8886e/`（首轮失败）；`knowledge-main-ui-check-final-5e8886e/`、`knowledge-main-ui-loading-check-5e8886e/`（通过）。实际输出在 `.cache/knowledge-mobile/ui-main-*-check*.log`。
- 统一 host：`.cache/test-logs/2026-10-22-knowledge-main-ui-host-final-5e8886e/`；`.cache/knowledge-mobile/ui-main-unified-tests-final.log`。首轮旧入口定位断言失败记录保留。
- 悬浮 host：`.cache/test-logs/2026-10-22-knowledge-main-floating-host-final-5e8886e/`；`.cache/knowledge-mobile/ui-main-floating-tests-final.log`。
- 构建/安装：`.cache/test-logs/2026-10-22-knowledge-main-ui-build-5e8886e/`、`knowledge-main-ui-build-final-5e8886e/`，含设备日志与工作区指纹。
- 侧栏打开记录：`.cache/test-logs/2026-10-22-knowledge-main-ui-open-5e8886e/`；后续设备验收追加。

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='/Applications/DevEco-Studio.app/Contents/tools/node/bin/node entry/src/test/run-host-tests.cjs --unified-only' \
/bin/bash scripts/capture-test-log.sh knowledge-main-ui-host

CAPTURE_HOST_ONLY=1 \
RUN_CMD='DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk /Applications/DevEco-Studio.app/Contents/tools/node/bin/node entry/src/test/run-floating-placement-tests.cjs' \
/bin/bash scripts/capture-test-log.sh knowledge-main-floating-host

RUN_CMD='/bin/bash scripts/dev-run-mac.sh --no-emulator --device 127.0.0.1:5555' \
/bin/bash scripts/capture-test-log.sh knowledge-main-ui-build 10m 127.0.0.1:5555
```

## 模拟器补充证据

- `.cache/test-logs/2026-10-22-knowledge-main-ui-home-import-ready-5e8886e/`：首页和四类型导入入口；`knowledge-main-ui-picker-5e8886e/` 为系统选择器（未选文件）。
- `knowledge-main-ui-library-5e8886e/`、`knowledge-main-ui-file-detail-5e8886e/`：文件名筛选、既有自制图片详情、归档显示。
- `knowledge-main-ui-preview-switch-5e8886e/`：已有归档自制 `shuvi-interrupt-A.txt` → B → A，首屏分别为 `SHUVI_SWITCH_A_20261022` / B / A 的第 01 段，无翻页；未恢复归档，未改正文。
- `knowledge-main-ui-local-search-5e8886e/`：本机查询「OCR验证」召回自制图与「本机标签」理由，未发送语义问题。
- `knowledge-main-ui-profile-5e8886e/`、`knowledge-main-ui-settings-5e8886e/`、`knowledge-main-ui-mineru-5e8886e/`：个人页及三类设置，仅查看，Key 输入均为空。
- 布局文本及截图：`.cache/knowledge-mobile/main-ui-final/`。`home.png`、`import.png`、`file-detail.png`、`preview-a.png`、`preview-b.png`、`local-search.png`、`profile.png`、`vision-settings.png`、`embedding-settings.png`、`mineru-settings.png` 为相应实测时点，不把较早截图当作后续代码的新证据。
- 首次截图复用既有路径被 CLI 拒绝（`knowledge-main-ui-home-import-5e8886e/`）；改用新路径后通过。筛选词首次被 CLI 追加形成无结果，使用系统「全选」替换后完成验证，相关记录保留。
- 搜索紧凑布局与设置提示收口检查：`knowledge-main-ui-search-compact-check-5e8886e/`、`knowledge-main-ui-delivery-check-5e8886e/`、`knowledge-main-ui-mineru-copy-check-5e8886e/` 均通过。`knowledge-main-ui-delivery-host-5e8886e/` 再次 174/174。

## 最终收口

- 视觉最终版设备证据：`knowledge-main-ui-final-workbench-5e8886e/`、`knowledge-main-ui-search-compact-5e8886e/`、`knowledge-main-ui-image-source-5e8886e/`。`main-ui-final/search-compact.png` 显示结果及来源按钮均在首屏，`image-source.png` 为已存自制图片描述；未点击语义发送或编辑保存。
- Linter 首轮 2 条 await-thenable 错误，修正后 **0 错误、5 条性能警告**。复查日志 `knowledge-main-ui-lint-delivery-5e8886e/`，JSON `.cache/knowledge-mobile/ui-main-lint-delivery.json`；未关闭规则。共享初始化分支使用 async 返回已有 Promise，清理回调补充明确 Promise 局部类型，实际等待契约保留。
- 最终类型检查：`knowledge-main-ui-final-check-5e8886e/`；最后一次 UI 文案收口及打包为 `knowledge-main-ui-final-package-5e8886e/`。其后仅异步表达方式/类型收口，最终制品以 `knowledge-main-ui-merge-final-build-5e8886e/` 为准。
- 最终统一 host：`knowledge-main-ui-final-host-5e8886e/`，174/174、requests=0、private_files=0。警告不冒称消除；未做真机、最大字体、服务故障注入或新付费服务质量验收。
- 现有 13 份统一文档、533 个正文块的只读计数在设备检查中可读；本轮没有清库/卸载/恢复归档，也未修改原件。最终统计快照另附，不将初始化自动队列当作人工新验收调用。

- 最终安装包：8,834,383 字节，SHA-256 `a9ee98454010dd157288f39875eb72758f1a87f451f46f10affa0f98ecf09397`；最终构建工作区指纹 `7332ce8ceb638f848e062d857a9f95fbe2ea153a26d2c5772ccddefd4924acbc`，build-profile=template、构建/安装退出码 0。
- 最终包回读：`knowledge-main-ui-final-package-open-5e8886e/`、`knowledge-main-ui-final-preservation-5e8886e/`；从工作台打开资料列表成功。前后计数均为 documents=13、chunks=533、attempts=580；Embedding revision=1 / credentialRevision=1、Vision revision=4 / credentialRevision=2，均 enabled=true / paused=false，未修改设置。该计数比较覆盖记录的 UI 验收区间，不外推未采样时段。
- 合并提交前最终回归：`knowledge-main-ui-merge-gate-host-5e8886e/`，174/174、requests=0、private_files=0。最终构建后仅补充本文证据与 Git 合并记录，未再修改运行源码。
