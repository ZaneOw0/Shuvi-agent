import { Theme } from './Theme';

/**
 * Tappable date/time field that opens a picker. A component rather than a by-value @Builder so the
 * shown value refreshes when the picker changes the owner's state.
 */
@Component
export struct CalendarFieldButton {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop fieldId: string = '';
  @Prop disabled: boolean = false;
  onTap: () => void = (): void => {};
  build() {
    Column({ space: 2 }) {
      Text(this.label).fontSize(Theme.noteSize).fontColor(Theme.muted)
      Text(this.value).fontSize(Theme.bodySize).fontColor(Theme.ink).maxLines(1)
    }.alignItems(HorizontalAlign.Start).width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .constraintSize({ minHeight: Theme.controlHeight }).backgroundColor(Theme.inputSurface)
      .border({ width: 1, color: Theme.line, radius: Theme.radius }).id(this.fieldId)
      .opacity(this.disabled ? 0.5 : 1).enabled(!this.disabled)
      .accessibilityText(`${this.label}：${this.value}，点击修改`).onClick((): void => { this.onTap(); })
  }
}
