import { Theme } from './Theme';
import { AppIcon } from './AppIcon';
import { SettingsPreparationPhase, SettingsPreparationState } from './SettingsPreparationModels';

@Component
export struct SettingsPreparationView {
  @Prop title: string = '';
  @Prop loadingTitle: string = '正在准备设置';
  @Prop failedTitle: string = '暂时无法打开设置';
  @Prop loadingMessage: string = '正在恢复本机资料并读取设置，请稍候…';
  @Prop slowMessage: string = '本机资料恢复耗时较长。你可以先返回，稍后再打开，准备过程会继续。';
  @Prop failedMessage: string = '本机服务准备未完成，已有资料与设置保留。请稍后重新加载。';
  @Prop returnLabel: string = '返回我的';
  @Prop retryLabel: string = '重新加载';
  @Prop preparation: SettingsPreparationState = new SettingsPreparationState();
  onBack: () => void = (): void => {};
  onRetry: () => void = (): void => {};

  private failed(): boolean { return this.preparation.phase === SettingsPreparationPhase.Failed; }

  build() {
    Column({ space: 24 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Circle }) {
          Text('‹').fontSize(28).fontColor(Theme.accent).translate({ y: -2 })
        }.width(44).height(44).backgroundColor(Theme.soft).accessibilityText(this.returnLabel)
          .id('settings-preparation-back').onClick(this.onBack)
        Text(this.title).fontSize(22).fontWeight(FontWeight.Medium).fontColor(Theme.ink).layoutWeight(1)
      }.width('100%')
      Column({ space: 16 }) {
        if (this.failed()) {
          AppIcon({ source: $r('app.media.chat_info'), size: 32 })
        } else {
          LoadingProgress().width(36).height(36).color(Theme.accent).id('settings-preparation-spinner')
        }
        Text(this.failed() ? this.failedTitle : this.loadingTitle).fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink).textAlign(TextAlign.Center).width('100%').id('settings-preparation-status')
        Text(this.failed() ? this.failedMessage : (this.preparation.slow ? this.slowMessage : this.loadingMessage))
          .fontSize(14).fontColor(Theme.muted).lineHeight(22).textAlign(TextAlign.Center).width('100%')
          .id('settings-preparation-message')
        if (this.failed()) {
          Button(this.retryLabel).fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent)
            .borderRadius(Theme.radius).constraintSize({ minHeight: Theme.controlHeight }).width('100%')
            .id('settings-preparation-retry').onClick(this.onRetry)
        }
        Button(this.returnLabel).fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft)
          .borderRadius(Theme.radius).constraintSize({ minHeight: Theme.controlHeight }).width('100%')
          .id('settings-preparation-return').onClick(this.onBack)
      }.width('100%').padding(24).backgroundColor(Theme.surface).borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line }).id('settings-preparation-card')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 24 })
  }
}
