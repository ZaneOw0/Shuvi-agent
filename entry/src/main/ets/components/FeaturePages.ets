import { Theme } from './Theme';
import { AppIcon } from './AppIcon';
import { BrandAvatar } from './BrandAvatar';

interface FeatureRowOptions {
  id?: string;
  available?: boolean;
  title: string;
  description: string;
  icon: Resource;
  onOpen: () => void;
}

interface NoticePageOptions {
  onNotice: (title: string, message: string) => void;
}

interface ProfilePageOptions extends NoticePageOptions {
  onApiKeys: () => void;
  onVisionSettings: () => void;
  onParseSettings: () => void;
  onEmbeddingSettings: () => void;
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
  }.width('100%').backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line, radius: 16 })
  .clip(true).enabled($$.available ?? true).id($$.id ?? 'feature-' + $$.title).onClick($$.onOpen).accessibilityText(`${$$.title}，${$$.description}`)
}

@Builder
export function ProfilePage($$: ProfilePageOptions) {
  Column({ space: 12 }) {
    Column({ space: 12 }) {
      BrandAvatar({ size: 72 })
      Text('属于你的休比').fontSize(24).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      Text('资料和 API Key 只保存在本机').fontSize(13).fontColor(Theme.muted)
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
    FeatureRow({ title: 'API Key 管理', description: 'DeepSeek、硅基流动、MinerU', icon: $r('app.media.ui_key'),
      id: 'profile-api-keys', onOpen: $$.onApiKeys })
    FeatureRow({ title: '解析引擎', description: 'PDF、Word 与图片的文字识别', icon: $r('app.media.ui_document'), onOpen: $$.onParseSettings })
    FeatureRow({ title: '图片理解', description: '图片描述、标签与自动处理', icon: $r('app.media.chat_book'), id: 'upd-profile-vision', onOpen: $$.onVisionSettings })
    FeatureRow({ title: '嵌入模型', description: '让资料支持按意思搜索', icon: $r('app.media.ui_search'), onOpen: $$.onEmbeddingSettings })
    FeatureRow({ title: '关于 Shuvi', description: '让想法，成为行动', icon: $r('app.media.chat_info'),
      onOpen: () => $$.onNotice('关于 Shuvi', '休比是运行在鸿蒙上的个人助理：可以直接对话、安排日程、读写文档，也能依据你导入的资料回答。日程写入系统日历前都会请你确认；资料和 Key 只保存在本机。') })
  }.width('100%').padding({ bottom: 24 })
}
