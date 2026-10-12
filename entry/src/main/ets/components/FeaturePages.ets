import { Theme } from './Theme';
import { AppIcon } from './AppIcon';
import { BrandAvatar } from './BrandAvatar';

interface FeatureRowOptions {
  title: string;
  description: string;
  icon: Resource;
  onOpen: () => void;
}

interface WorkbenchPageOptions {
  recordCount: number;
  onCalendar: () => void;
  onNotice: (title: string, message: string) => void;
}

interface NoticePageOptions {
  onNotice: (title: string, message: string) => void;
}

interface ProfilePageOptions extends NoticePageOptions {
  floatingAssistantEnabled: boolean;
  onFloatingAssistantChange: (enabled: boolean) => void;
}

@Builder
export function FeatureRow($$: FeatureRowOptions) {
  Button({ type: ButtonType.Normal }) {
    Row({ space: 14 }) {
      Stack() {
        AppIcon({ source: $$.icon, size: 22 })
      }.width(42).height(42).backgroundColor(Theme.soft).borderRadius(12)
      Column({ space: 5 }) {
        Text($$.title).fontSize(16).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        Text($$.description).fontSize(12).fontColor(Theme.muted)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      AppIcon({ source: $r('app.media.ui_chevron_right'), size: 18 })
    }.width('100%').padding(16)
  }.width('100%').backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
  .onClick($$.onOpen).accessibilityText(`${$$.title}，${$$.description}`)
}

// 使用 $$ 按引用传参，让演示日程数量随父页面状态更新。
@Builder
export function WorkbenchPage($$: WorkbenchPageOptions) {
  Column({ space: 12 }) {
    Column({ space: 10 }) {
      Text('把琐事安放好').fontSize(26).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      Text('从一件小事开始，让生活更有条理。').fontSize(14).fontColor(Theme.muted)
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 12, bottom: 16 })
    FeatureRow({ title: '日历日程', description: `${$$.recordCount} 条演示日程 · 查看与安排`, icon: $r('app.media.chat_calendar'),
      onOpen: $$.onCalendar })
    FeatureRow({ title: '文件管理', description: '整理文件与资料 · 待接入', icon: $r('app.media.ui_folder'),
      onOpen: () => $$.onNotice('文件管理', '文件浏览与分类待接入，本次不会读取设备文件。') })
    FeatureRow({ title: '联网搜索', description: '寻找信息与答案 · 待接入', icon: $r('app.media.chat_globe'),
      onOpen: () => $$.onNotice('联网搜索', '联网检索待接入，本次不会发送搜索请求。') })
    FeatureRow({ title: '长语音转写', description: '留下原文，提炼重点 · 待接入', icon: $r('app.media.ui_microphone'),
      onOpen: () => $$.onNotice('长语音转写', '录音、音频上传和摘要待接入，本次不会开启麦克风。') })
    FeatureRow({ title: '跨设备协同', description: '让任务随你流转 · 待接入', icon: $r('app.media.ui_devices'),
      onOpen: () => $$.onNotice('跨设备协同', '设备连接与任务流转待平台验证，本次没有连接其他设备。') })
  }.width('100%').padding({ bottom: 24 })
}

@Builder
export function KnowledgePage($$: NoticePageOptions) {
  Column({ space: 16 }) {
    Column({ space: 12 }) {
      Text('让知识，有处可寻').fontSize(26).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      Text('汇集你的资料，在需要时找回灵感。').fontSize(14).fontColor(Theme.muted)
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          AppIcon({ source: $r('app.media.ui_import'), size: 18 })
          Text('导入文档').fontSize(14).fontColor(Color.White)
        }.padding({ left: 16, right: 16, top: 10, bottom: 10 })
      }.backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 })
        .accessibilityText('导入文档，待接入')
        .onClick(() => $$.onNotice('导入文档', '文档导入待接入。下方仅为样例，没有读取你的文件。'))
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 8 })
    Button({ type: ButtonType.Normal }) {
      Row({ space: 10 }) {
        AppIcon({ source: $r('app.media.ui_search'), size: 20 })
        Text('搜索资料或向知识库提问').fontSize(14).fontColor(Theme.muted).layoutWeight(1)
      }.padding(16).width('100%')
    }.width('100%').backgroundColor(Theme.surface).borderRadius(14)
      .accessibilityText('搜索资料或向知识库提问，待接入')
      .onClick(() => $$.onNotice('知识库检索与问答', '个人知识库检索与问答待接入，目前没有真实检索结果。'))
    Row() {
      Text('资料预览').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Theme.ink).layoutWeight(1)
      Text('样例文档').fontSize(12).fontColor(Theme.amber)
    }.width('100%').margin({ top: 12 })
    FeatureRow({ title: '项目灵感笔记', description: '样例 · Markdown · 未导入', icon: $r('app.media.ui_document'),
      onOpen: () => $$.onNotice('项目灵感笔记 · 样例', '演示摘要：用自然语言安排日程，让资料成为随时可查的个人知识。此内容为固定样例。') })
    FeatureRow({ title: '阅读摘录', description: '样例 · PDF · 未导入', icon: $r('app.media.chat_book'),
      onOpen: () => $$.onNotice('阅读摘录 · 样例', '演示摘要：收集阅读中的想法，记录来源，留待回顾。此内容不来自真实 PDF。') })
    Text('这里展示的是未来资料库的样子。文档导入、索引和问答将在后续接入。')
      .fontSize(12).fontColor(Theme.muted).lineHeight(20).width('100%')
  }.width('100%').padding({ bottom: 24 })
}

@Builder
export function ProfilePage($$: ProfilePageOptions) {
  Column({ space: 12 }) {
    Column({ space: 12 }) {
      BrandAvatar({ size: 72 })
      Text('属于你的休比').fontSize(24).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      Text('未登录 · 当前为本地演示').fontSize(13).fontColor(Theme.muted)
      Button('登录 / 注册', { type: ButtonType.Normal }).fontColor(Color.White).fontSize(14)
        .backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 })
        .onClick(() => $$.onNotice('登录与注册', '账号服务待接入。本次不会收集账号信息。'))
    }.width('100%').padding({ top: 20, bottom: 24 })
    Row({ space: 16 }) {
      Text('悬浮助手入口').fontSize(16).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        .layoutWeight(1).accessibilityLevel('no')
      Stack() {
        Toggle({ type: ToggleType.Switch, isOn: $$.floatingAssistantEnabled })
          .width(60).height(32).selectedColor(Theme.accent)
          .responseRegion({ x: 0, y: -8, width: 60, height: 48 })
          .accessibilityText('悬浮助手入口')
          .accessibilityDescription('控制其他页面的助手头像按钮，仅本次运行有效。关闭后仍可通过左上角菜单进入助手。')
          .id('floating-assistant-toggle').onChange($$.onFloatingAssistantChange)
      }.width(60).height(48)
    }.width('100%').padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
    FeatureRow({ title: '我的设备', description: '多设备管理 · 待接入', icon: $r('app.media.ui_devices'),
      onOpen: () => $$.onNotice('我的设备', '设备管理待接入，没有设备已绑定或同步。') })
    FeatureRow({ title: '主题与外观', description: '当前：奶油白与莓紫 · 切换待接入', icon: $r('app.media.ui_palette'),
      onOpen: () => $$.onNotice('主题与外观', '界面采用角色形象中的莓紫、深紫和奶油黄。主题切换和自定义将在后续实现。') })
    FeatureRow({ title: '关于 Shuvi', description: '让想法，成为行动', icon: $r('app.media.chat_info'),
      onOpen: () => $$.onNotice('关于 Shuvi', '休比是你的个人助理。这是前端演示初稿：数据仅保留在当前页面实例中，退出重启后重置，不会产生真实提醒。') })
  }.width('100%').padding({ bottom: 24 })
}
