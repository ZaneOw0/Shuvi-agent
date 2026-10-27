import util from '@ohos.util';
import { Theme } from './Theme';
import { DeepSeekKeyService, DeepSeekKeyStatus } from '../services/model/DeepSeekCredentialStore';

/**
 * DeepSeek key entry shared by the assistant and search setups. Remembering is opt-in per save and the key goes only to
 * the device Asset Store; every session start still needs an explicit tap, and the session itself keeps the key in memory.
 */
@Component
export struct DeepSeekKeyField {
  @Prop @Watch('clearInput') clearEpoch: number = 0;
  @Prop enableLabel: string = '同意上述范围并启用';
  @Prop idPrefix: string = 'runtime-chat';
  @Prop purpose: string = '真实对话';
  @State apiKey: string = '';
  @State remember: boolean = false;
  @State status: DeepSeekKeyStatus = DeepSeekKeyStatus.Checking;
  @State busy: boolean = false;
  @State note: string = '';
  @State otherKey: boolean = false;
  onKey: (key: Uint8Array) => void = (_key: Uint8Array): void => {};

  aboutToAppear(): void { void this.refresh(); }
  aboutToDisappear(): void { this.apiKey = ''; }
  private clearInput(): void { this.apiKey = ''; void this.refresh(); }
  private async refresh(): Promise<void> { this.status = await DeepSeekKeyService.store.status(); }
  private handOff(key: Uint8Array): void { try { this.onKey(key); } catch { key.fill(0); } }

  private async enableTyped(): Promise<void> {
    if (this.busy || this.apiKey.trim().length === 0) { return; }
    const key: Uint8Array = new util.TextEncoder().encodeInto(this.apiKey); this.apiKey = '';
    this.busy = true; this.note = '';
    try {
      if (this.remember) {
        this.remember = false;
        try { await DeepSeekKeyService.store.save(key); this.note = '已记住 Key：只保存在本机系统安全存储，不同步，可随时删除。'; }
        catch { this.note = '未能记住 Key（格式不符或本机存储失败），本次仍只用于当前会话。'; }
        await this.refresh();
      }
      this.handOff(key);
    } finally { this.busy = false; }
  }
  private async enableSaved(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.note = '';
    try {
      const key: Uint8Array | undefined = await DeepSeekKeyService.store.load();
      if (key === undefined) { this.note = '已记住的 Key 不可用，请重新输入。'; await this.refresh(); return; }
      this.handOff(key);
    } catch {
      this.note = '读取已记住的 Key 失败，请重新输入。'; await this.refresh();
    } finally { this.busy = false; }
  }
  private confirmRemove(): void {
    this.getUIContext().showAlertDialog({
      title: '删除已记住的 DeepSeek Key？',
      message: '删除后，下次启用需要重新输入 Key。已启用的会话不受影响，直到它停止。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除 Key', action: (): void => { void this.remove(); } }
    });
  }
  private async remove(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try { await DeepSeekKeyService.store.remove(); this.note = '已删除本机记住的 Key。'; }
    catch { this.note = '删除未确认，请稍后重试。'; }
    finally { await this.refresh(); this.busy = false; }
  }

  build() {
    Column({ space: 10 }) {
      if (this.status === DeepSeekKeyStatus.Saved) {
        Button(this.enableLabel).enabled(!this.busy).width('100%').constraintSize({ minHeight: Theme.controlHeight })
          .backgroundColor(Theme.accent).fontColor(Color.White).borderRadius(Theme.radius).id(`${this.idPrefix}-enable-saved`)
          .accessibilityText(`${this.purpose}，同意范围并使用本机已记住的 DeepSeek Key 启用`)
          .onClick((): void => { void this.enableSaved(); })
        Row({ space: 4 }) {
          Text('使用本机记住的 Key').fontSize(Theme.noteSize).fontColor(Theme.muted)
          Button('删除').fontSize(Theme.noteSize).fontColor(Theme.accent).backgroundColor(Color.Transparent)
            .enabled(!this.busy).constraintSize({ minHeight: 32 }).padding({ left: 6, right: 6 })
            .id(`${this.idPrefix}-forget-key`).accessibilityText('删除本机记住的 DeepSeek Key')
            .onClick((): void => { this.confirmRemove(); })
          Blank()
          Button(this.otherKey ? '收起' : '使用其他 Key').fontSize(Theme.noteSize).fontColor(Theme.accent)
            .backgroundColor(Color.Transparent).constraintSize({ minHeight: 32 }).padding({ left: 6, right: 6 })
            .id(`${this.idPrefix}-other-key`).onClick((): void => { this.otherKey = !this.otherKey; this.apiKey = ''; })
        }.width('100%')
      }
      if (this.status !== DeepSeekKeyStatus.Saved || this.otherKey) {
        TextInput({ text: this.apiKey, placeholder: this.status === DeepSeekKeyStatus.Saved ? '输入其他 Key' : 'DeepSeek API Key' })
          .type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None).selectionMenuHidden(false)
          .enableAutoFill(false).enablePreviewText(false).maxLength(2048).borderRadius(Theme.radius)
          .constraintSize({ minHeight: Theme.controlHeight })
          .onChange((value: string): void => { this.apiKey = value; })
          .accessibilityText(`${this.purpose}使用的 DeepSeek API Key，允许粘贴`).id(`${this.idPrefix}-key`)
        Row({ space: 8 }) {
          Checkbox().selectedColor(Theme.accent).select(this.remember).id(`${this.idPrefix}-remember-key`)
            .onChange((checked: boolean): void => { this.remember = checked; })
          Text(this.status === DeepSeekKeyStatus.Saved ? '用这个 Key 替换已记住的 Key' : '记住 Key（只保存在本机系统安全存储，不同步，可随时删除）')
            .fontSize(Theme.noteSize).fontColor(Theme.ink).layoutWeight(1)
        }.width('100%')
        Button(this.enableLabel).enabled(!this.busy && this.apiKey.trim().length > 0).width('100%')
          .constraintSize({ minHeight: Theme.controlHeight }).borderRadius(Theme.radius)
          .backgroundColor(this.status === DeepSeekKeyStatus.Saved ? Theme.soft : Theme.accent)
          .fontColor(this.status === DeepSeekKeyStatus.Saved ? Theme.accent : Color.White).id(`${this.idPrefix}-enable`)
          .onClick((): void => { void this.enableTyped(); })
      }
      if (this.status === DeepSeekKeyStatus.Unavailable) {
        Text('本机安全存储暂不可用，本次请直接输入 Key。').fontSize(12).fontColor(Theme.muted).width('100%')
      }
      if (this.note.length > 0) { Text(this.note).fontSize(12).fontColor(Theme.muted).width('100%') }
    }.width('100%')
  }
}
