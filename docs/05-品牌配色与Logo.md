# 05 品牌配色与 Logo

> 状态：当前固定浅色品牌规范；完整无障碍与上架图标仍需验收。

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

- 来源：开发者提供的角色插画，经 AI 编辑生成头像适配版；保留素材来源与衍生关系。
- 当前 PNG：`entry/src/main/resources/base/media/shuvi_logo.png`，1254 × 1254，约 1.76 MiB。AppScope 同名资源为同一文件的副本；修改 Logo 时必须同步两处，避免 AppScope 合并资源覆盖产生差异。
- `AppScope/app.json5` 的应用 icon 与 `entry/src/main/module.json5` 的入口 icon 都引用 `$media:shuvi_logo`；启动页 `startWindowIcon` 独立引用 `$media:shuvi_start_icon`。
- 启动专用 PNG：`entry/src/main/resources/base/media/shuvi_start_icon.png`，256 × 256，由现有 Logo 等比缩小，不重新生成图案。更新 Logo 时需同步生成此资源，保持不超过 256 × 256 像素，满足 `@performance/start-window-icon-check`；该独立资源不在 AppScope 创建同名副本。
- 启动页 base / dark 背景均设为奶油白，与当前固定浅色应用界面一致。原模板图标资源保留，但不再作为上述入口的引用目标。
- 当前采用官方支持的单层图标用于原型展示；不是已验收的上架分层图标交付物。桌面图标与启动页列入设备检查范围，最近任务显示仍需单独验证。

配置依据：通过 DevEco CLI 读取华为官方 [配置应用图标和名称](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/layered-image)，文档标识为 `开发指南/开发基础知识/典型场景的开发指导/配置应用图标和名称/layered-image`。文档说明入口 UIAbility 与应用 icon 的优先级，以及 AppScope 同名资源会覆盖模块资源的行为。当前没有新增系统接口、权限或依赖。
