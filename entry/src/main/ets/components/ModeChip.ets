import { AppIcon } from './AppIcon';
import { Theme } from './Theme';

/**
 * Composer mode toggle (search / knowledge). A component rather than a by-value @Builder so the
 * on-state, label and enabled state refresh when the page state changes.
 */
@Component
export struct ModeChip {
  @Prop label: string = '';
  @Prop on: boolean = false;
  @Prop disabled: boolean = false;
  @Prop chipId: string = '';
  @Prop a11y: string = '';
  icon: Resource = $r('app.media.chat_globe');
  onTap: () => void = (): void => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 4 }) {
        AppIcon({ source: this.icon, size: 16 })
        Text(this.label).fontSize(13).fontColor(this.on ? Theme.accent : Theme.muted)
      }.padding({ left: 12, right: 12 })
    }.height(Theme.controlHeight).backgroundColor(this.on ? Theme.soft : Color.Transparent)
      .border({ width: 1, color: this.on ? Theme.accent : Theme.line, radius: Theme.controlHeight / 2 })
      .enabled(!this.disabled).id(this.chipId).accessibilityText(this.a11y).onClick((): void => this.onTap())
  }
}
