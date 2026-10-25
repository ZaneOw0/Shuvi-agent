import { Theme } from './Theme';
import { DirectModelCheckService } from '../services/model/DirectModelCheckService';
import { DirectModelCheckState } from '../services/model/DirectModelCheckSession';

@Component
export struct DirectModelCheck {
  @State modelId: string = '';
  @State apiKey: string = '';
  @State result: DirectModelCheckState = new DirectModelCheckState();

  aboutToAppear(): void {
    DirectModelCheckService.session.attach((state: DirectModelCheckState): void => {
      this.apiKey = '';
      this.result = state;
    });
  }

  aboutToDisappear(): void {
    this.apiKey = '';
    DirectModelCheckService.session.detach();
  }

  build() {
    Column({ space: 12 }) {
      Text('模型直连 · 调试').fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
      Text('直接连接 DeepSeek，无需启动电脑网关。测试仅发送“Reply with exactly OK.”，最多输出 64 tokens，会按供应商规则计费。')
        .fontSize(13).fontColor(Theme.muted).width('100%')
      TextInput({ text: this.modelId, placeholder: '控制台中的准确模型标识' })
        .maxLength(128).enabled(!this.result.busy).onChange((value: string): void => { this.modelId = value; })
        .accessibilityText('DeepSeek 模型标识').id('direct-model-id')
      TextInput({ text: this.apiKey, placeholder: '个人 API Key，仅本次请求使用' })
        .type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None)
        .selectionMenuHidden(false).enableAutoFill(false).enablePreviewText(false)
        .maxLength(2048).enabled(!this.result.busy)
        .onChange((value: string): void => { this.apiKey = value; })
        .accessibilityText('DeepSeek API Key，密码输入').id('direct-model-key')
      Text('Key 不保存到文件；提交、离开页面或进入后台时清空输入。请勿截图或分享凭据。')
        .fontSize(12).fontColor(Theme.muted).width('100%')
      Text(this.result.message).fontSize(13).fontColor(Theme.ink).width('100%')
        .accessibilityText(this.result.message).id('direct-model-status')
      if (this.result.busy) {
        Button('停止请求').backgroundColor(Theme.soft).fontColor(Theme.accent)
          .constraintSize({ minHeight: 44 }).onClick(() => DirectModelCheckService.session.cancel())
      } else {
        Button('同意发送一次测试').backgroundColor(Theme.accent).fontColor(Color.White)
          .constraintSize({ minHeight: 44 }).enabled(this.modelId.trim().length > 0 && this.apiKey.length > 0)
          .onClick(() => {
            const key: string = this.apiKey;
            this.apiKey = '';
            DirectModelCheckService.session.run(this.modelId.trim(), key);
          })
          .id('direct-model-start')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
      .backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
  }
}
