# 05 品牌配色与 Logo

> 状态：v0.4，已验收（限本轮视觉审核与模拟器人工检查，含最大字体）；2026-10-09。范围与反馈见 [功能 spec 第 6.6 节](../specs/01-创建日程并提醒.md)。真实能力与真机不在此次验收范围内。

## 1. 设计方向

从角色的紫色头发、黄色帽子与暖白背景提取色彩方向。界面保留浅色阅读底，莓紫用于主要操作与选中态，深紫用于文字，暖黄用于待确认和提示，避免大面积高饱和背景干扰对话内容。

打开 [配色与 Logo 预览](assets/brand/index.html) 可对比助手首页、日程待确认及圆形／圆角方形图标。该网页是静态视觉参考，不是模拟器截图；实际 ArkUI 代码使用同组颜色和图片。

## 2. 颜色与组件

| 用途 | Theme 字段 | 色值 |
|---|---|---|
| 奶油白页面背景 | paper | `#FFFBF5` |
| 白色卡片与操作区 | surface | `#FFFFFF` |
| 深紫正文 | ink | `#342638` |
| 灰紫辅助文字 | muted | `#796A76` |
| 莓紫按钮、字标与强调 | accent | `#793B68` |
| 淡紫选中底 | soft | `#F5ECF3` |
| 输入区 | inputSurface | `#FCF7FA` |
| 用户消息气泡 | bubble | `#F2E7F0` |
| 分隔与边框 | line | `#E8DCE4` |
| 暖黄提示背景／文字 | warning / amber | `#FFF2D4` / `#80551B` |
| 错误提示 | danger | `#AA344C` |

颜色集中于 `Theme.ets`，SVG 固定描边同步更新。已计算的文字对比度：按钮白字 7.96:1、正文与页面背景 13.76:1、辅助文字与输入背景 4.79:1、待确认文字与黄底 5.85:1。以上只验证这些颜色组合，不代表已完成全应用无障碍验收。

`BrandAvatar.ets` 用于角色图片，`AppIcon.ets` 用于功能线条图标。首页头像 80 vp、Shuvi 字标 36 fp；消息头像 28 vp，我的页头像 72 vp。原有导航、确认和失败恢复行为保持不变。当前仍为固定浅色主题，不提供主题切换。

## 3. Logo 来源与接入

- 来源：开发者在 2026-10-08 会话中提供的角色插画。使用 imagegen 制作面部为主的头像适配版；这是 AI 编辑衍生图，不是原文件的无损裁剪。2026-10-09，开发者确认配色与 Logo 审核符合预期。
- 当前 PNG：`entry/src/main/resources/base/media/shuvi_logo.png`，1254 × 1254，约 1.76 MiB。AppScope 同名资源为同一文件的副本；修改 Logo 时必须同步两处，避免 AppScope 合并资源覆盖产生差异。
- `AppScope/app.json5` 的应用 icon 与 `entry/src/main/module.json5` 的入口 icon 都引用 `$media:shuvi_logo`；启动页 `startWindowIcon` 独立引用 `$media:shuvi_start_icon`。
- 启动专用 PNG：`entry/src/main/resources/base/media/shuvi_start_icon.png`，256 × 256，由现有 Logo 等比缩小，不重新生成图案。更新 Logo 时需同步生成此资源，保持不超过 256 × 256 像素，满足 `@performance/start-window-icon-check`；该独立资源不在 AppScope 创建同名副本。
- 启动页 base / dark 背景均设为奶油白，与当前固定浅色应用界面一致。原模板图标资源保留，但不再作为上述入口的引用目标。
- 当前采用官方支持的单层图标用于原型展示；不是已验收的上架分层图标交付物。桌面图标与启动页列入本轮模拟器人工检查，最近任务显示未单独取得反馈。

配置依据：通过 DevEco CLI 读取华为官方 [配置应用图标和名称](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/layered-image)，文档标识为 `开发指南/开发基础知识/典型场景的开发指导/配置应用图标和名称/layered-image`。文档说明入口 UIAbility 与应用 icon 的优先级，以及 AppScope 同名资源会覆盖模块资源的行为。本轮没有新增系统接口、权限或依赖。

## 4. 验证与人工审核

- Code Linter 返回 0 个问题：`.local/brand-lint.json`。
- `CompileArkTS`、资源编译与 `assembleHap` 通过：`.local/brand-build.log`。仍保留 `TextAreaController` 系统能力警告和未配置签名提示。
- 品牌网页在 1100 px、375 px 宽度下，16 处图像引用均加载，无横向溢出：`.local/brand-preview-check.json`。
- 2026-10-09，开发者确认配色、Logo 和模拟器检查（含最大字体）均符合预期；记录来源为会话反馈，AI 未独立操作模拟器复验。未取得字体倍率和逐项截图，真机、Hypium 及本轮宿主测试未执行。

本轮审核范围：配色与角色 Logo；模拟器上的桌面图标、启动页、助手首页、对话头像及其他三个页面；日程确认卡片、文字与按钮；最大字体下的遮挡与截断。以上范围由开发者汇总确认符合预期，不扩展为其他设备、上架要求或真实业务能力已通过。

### 4.1 启动图标尺寸修复（2026-10-12）

- CI 报告 `@performance/start-window-icon-check`：启动图标 1254 × 1254 超过建议上限 256 × 256。现有门禁对非空问题报告均判失败，包含 suggestion；保留门禁规则。
- 经开发者确认，使用 Windows `System.Drawing` 高质量双三次插值将原 Logo 等比缩小，生成独立的 `shuvi_start_icon.png`（256 × 256，146,302 bytes，约 143 KiB）。仅修改 `startWindowIcon` 的资源引用，应用 icon 与页面头像继续使用原 Logo。
- 规则依据：本机 DevEco Studio 26.0.0.821 随附的 `plugins/codelinter/arkPerfCheck/docs/start-window-icon-check-cn.md`，说明启动图标过大会增加解码耗时，建议不超过 256 × 256。
- 验证改为项目根目录执行 `devecocli check lint --format json --output-path <报告路径>`，不再仅检查 `entry/src/main/ets`。修复前复现 1 条相同 suggestion（`.local/startup-icon-before-lint.json`），修复后错误、警告、建议均为 0（`.local/startup-icon-after-lint.json`）；CLI 退出码本身不能替代报告检查。
- 使用 API 26 SDK、IDE 配套 Node.js 与 JDK 21 执行 Hvigor `assembleHap --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon`，资源编译、`CompileArkTS` 与打包通过，退出码 0，日志 `.local/startup-icon-build.log`。保留既有 `TextAreaController` 能力警告与未配置签名提示，产物为未签名 HAP；本地结果不替代远程 CI。
- 开发者针对本轮模拟器冷启动检查反馈「结果符合预期」：启动图标正常、无拉伸，并能进入首页。此项为开发者人工反馈，AI 未独立操作模拟器；未执行真机验收，也未重跑未修改的 Mock 业务或悬浮位置测试。
