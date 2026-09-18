import { Theme } from './Theme';

interface FeatureRowOptions {
  title: string;
  description: string;
  mark: string;
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

@Builder
export function FeatureRow($$: FeatureRowOptions) {
  Button({ type: ButtonType.Normal }) {
    Row({ space: 14 }) {
      Text($$.mark).fontSize(18).fontWeight(FontWeight.Medium).fontColor(Theme.accent)
        .width(42).height(42).textAlign(TextAlign.Center).backgroundColor(Theme.soft).borderRadius(12)
      Column({ space: 5 }) {
        Text($$.title).fontSize(16).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        Text($$.description).fontSize(12).fontColor(Theme.muted)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('›').fontSize(24).fontColor(Theme.muted)
    }.width('100%').padding(16)
  }.width('100%').backgroundColor(Theme.surface).borderRadius(16)
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
    FeatureRow({ title: '日历日程', description: `${$$.recordCount} 条演示日程 · 查看与安排`, mark: '日',
      onOpen: $$.onCalendar })
    FeatureRow({ title: '文件管理', description: '整理文件与资料 · 待接入', mark: '文',
      onOpen: () => $$.onNotice('文件管理', '文件浏览与分类待接入，本次不会读取设备文件。') })
    FeatureRow({ title: '联网搜索', description: '寻找信息与答案 · 待接入', mark: '搜',
      onOpen: () => $$.onNotice('联网搜索', '联网检索待接入，本次不会发送搜索请求。') })
    FeatureRow({ title: '长语音转写', description: '留下原文，提炼重点 · 待接入', mark: '录',
      onOpen: () => $$.onNotice('长语音转写', '录音、音频上传和摘要待接入，本次不会开启麦克风。') })
    FeatureRow({ title: '跨设备协同', description: '让任务随你流转 · 待接入', mark: '连',
      onOpen: () => $$.onNotice('跨设备协同', '设备连接与任务流转待平台验证，本次没有连接其他设备。') })
  }.width('100%').padding({ bottom: 24 })
}

@Builder
export function KnowledgePage($$: NoticePageOptions) {
  Column({ space: 16 }) {
    Column({ space: 12 }) {
      Text('让知识，有处可寻').fontSize(26).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      Text('汇集你的资料，在需要时找回灵感。').fontSize(14).fontColor(Theme.muted)
      Button('导入文档', { type: ButtonType.Normal }).fontSize(14).fontColor(Color.White)
        .backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 })
        .onClick(() => $$.onNotice('导入文档', '文档导入待接入。下方仅为样例，没有读取你的文件。'))
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 8 })
    Button({ type: ButtonType.Normal }) {
      Row() {
        Text('搜索资料或向知识库提问').fontSize(14).fontColor(Theme.muted).layoutWeight(1)
        Text('⌕').fontSize(24).fontColor(Theme.accent)
      }.padding(16).width('100%')
    }.width('100%').backgroundColor(Theme.surface).borderRadius(14)
      .onClick(() => $$.onNotice('知识库检索与问答', '个人知识库检索与问答待接入，目前没有真实检索结果。'))
    Row() {
      Text('资料预览').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Theme.ink).layoutWeight(1)
      Text('样例文档').fontSize(12).fontColor(Theme.amber)
    }.width('100%').margin({ top: 12 })
    FeatureRow({ title: '项目灵感笔记', description: '样例 · Markdown · 未导入', mark: '记',
      onOpen: () => $$.onNotice('项目灵感笔记 · 样例', '演示摘要：用自然语言安排日程，让资料成为随时可查的个人知识。此内容为固定样例。') })
    FeatureRow({ title: '阅读摘录', description: '样例 · PDF · 未导入', mark: '书',
      onOpen: () => $$.onNotice('阅读摘录 · 样例', '演示摘要：收集阅读中的想法，记录来源，留待回顾。此内容不来自真实 PDF。') })
    Text('这里展示的是未来资料库的样子。文档导入、索引和问答将在后续接入。')
      .fontSize(12).fontColor(Theme.muted).lineHeight(20).width('100%')
  }.width('100%').padding({ bottom: 24 })
}

@Builder
export function ProfilePage($$: NoticePageOptions) {
  Column({ space: 12 }) {
    Column({ space: 12 }) {
      Text('休').fontSize(30).fontColor(Theme.accent).fontWeight(FontWeight.Bold)
        .width(72).height(72).textAlign(TextAlign.Center).backgroundColor(Theme.soft).borderRadius(24)
      Text('属于你的休比').fontSize(24).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      Text('未登录 · 当前为本地演示').fontSize(13).fontColor(Theme.muted)
      Button('登录 / 注册', { type: ButtonType.Normal }).fontColor(Color.White).fontSize(14)
        .backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 })
        .onClick(() => $$.onNotice('登录与注册', '账号服务待接入。本次不会收集账号信息。'))
    }.width('100%').padding({ top: 20, bottom: 24 })
    FeatureRow({ title: '我的设备', description: '多设备管理 · 待接入', mark: '设',
      onOpen: () => $$.onNotice('我的设备', '设备管理待接入，没有设备已绑定或同步。') })
    FeatureRow({ title: '主题与外观', description: '当前：纸白与松绿 · 切换待接入', mark: '色',
      onOpen: () => $$.onNotice('主题与外观', '初稿采用纸白与松绿配色。主题切换和自定义将在后续实现。') })
    FeatureRow({ title: '关于 Shuvi', description: '让想法，成为行动', mark: '休',
      onOpen: () => $$.onNotice('关于 Shuvi', '休比是你的个人助理。这是前端演示初稿：数据仅保留在当前页面实例中，退出重启后重置，不会产生真实提醒。') })
  }.width('100%').padding({ bottom: 24 })
}
