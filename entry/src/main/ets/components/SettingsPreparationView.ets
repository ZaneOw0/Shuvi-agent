import { Theme } from './Theme';
import { AppIcon } from './AppIcon';
import { SettingsPreparationPhase, SettingsPreparationState } from './SettingsPreparationModels';

@Component
export struct SettingsPreparationView {
  @Prop title: string = '';
  @Prop preparation: SettingsPreparationState = new SettingsPreparationState();
  onBack: () => void = (): void => {};
  onRetry: () => void = (): void => {};

  private failed(): boolean { return this.preparation.phase === SettingsPreparationPhase.Failed; }

  build() {
    Column({ space: 24 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Circle }) {
          Text('‹').fontSize(28).fontColor(Theme.accent).translate({ y: -2 })
        }.width(44).height(44).backgroundColor(Theme.soft).accessibilityText('返回我的')
          .id('settings-preparation-back').onClick(this.onBack)
        Text(this.title).fontSize(22).fontWeight(FontWeight.Medium).fontColor(Theme.ink).layoutWeight(1)
      }.width('100%')
      Column({ space: 16 }) {
        if (this.failed()) {
          AppIcon({ source: $r('app.media.chat_info'), size: 32 })
        } else {
          LoadingProgress().width(36).height(36).color(Theme.accent).id('settings-preparation-spinner')
        }
        Text(this.failed() ? '暂时无法打开设置' : '正在准备设置').fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink).textAlign(TextAlign.Center).width('100%').id('settings-preparation-status')
        Text(this.failed() ? '本机服务准备未完成，已有资料与设置保留。请稍后重新加载。' :
          (this.preparation.slow ? '本机资料恢复耗时较长。你可以先返回，稍后再打开，准备过程会继续。' : '正在恢复本机资料并读取设置，请稍候…'))
          .fontSize(14).fontColor(Theme.muted).lineHeight(22).textAlign(TextAlign.Center).width('100%')
          .id('settings-preparation-message')
        if (this.failed()) {
          Button('重新加载').fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent)
            .borderRadius(Theme.radius).constraintSize({ minHeight: Theme.controlHeight }).width('100%')
            .id('settings-preparation-retry').onClick(this.onRetry)
        }
        Button('返回我的').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft)
          .borderRadius(Theme.radius).constraintSize({ minHeight: Theme.controlHeight }).width('100%')
          .id('settings-preparation-return').onClick(this.onBack)
      }.width('100%').padding(24).backgroundColor(Theme.surface).borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line }).id('settings-preparation-card')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 24 })
  }
}
