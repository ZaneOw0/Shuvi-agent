import util from '@ohos.util';
import { Theme } from './Theme';

@Component
export struct RuntimeChatSetup {
  @Prop @Watch('clearInput') clearEpoch: number = 0;
  @State apiKey: string = '';
  onStart: (key: Uint8Array) => void = (_key: Uint8Array): void => {};
  private clearInput(): void { this.apiKey = ''; }
  aboutToDisappear(): void { this.apiKey = ''; }
  build() {
    Column({ space: 10 }) {
      Text('真实对话 · deepseek-flash').fontSize(16).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        Text('启用后，模型可按你的意图创建、读取和更新 txt/md 文档。创建和更新的文件保存在系统文件管理器的 Download/com.example.shuvi/，其他应用也可能访问，请勿保存敏感资料。本次会话的对话和模型选中的文档正文会发送到 DeepSeek（api.deepseek.com）；不读取知识库，不执行搜索或日程。版本和执行记录保存在应用内。')
        .fontSize(13).fontColor(Theme.muted).width('100%')
      Text('每次输入最多 500 字符；模型可连续调用工具再回答，每轮累计最多 1024 输出 tokens、6 次工具调用，最长 120 秒。每次启用最多 10 次模型请求，无自动重试。按已登记价格作 USD 0.01/轮的本地估算检查，实际扣费以供应商账单为准。取消也可能计费，已提交的文件写入会保留。')
        .fontSize(12).fontColor(Theme.muted).width('100%')
      TextInput({ text: this.apiKey, placeholder: 'DeepSeek API Key，仅本次会话' })
        .type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None).selectionMenuHidden(false)
        .enableAutoFill(false).enablePreviewText(false).maxLength(2048)
        .onChange((value: string): void => { this.apiKey = value; })
        .accessibilityText('真实对话 API Key，仅本次会话，允许粘贴').id('runtime-chat-key')
      Button('同意上述范围并启用').enabled(this.apiKey.trim().length > 0).constraintSize({ minHeight: 44 })
        .backgroundColor(Theme.accent).fontColor(Color.White).id('runtime-chat-enable')
        .onClick((): void => {
          const key = new util.TextEncoder().encodeInto(this.apiKey); this.apiKey = '';
          try { this.onStart(key); } catch { key.fill(0); }
        })
      Text('启用不发送模型请求；发送按钮才会调用模型。离开助手页或退后台后清除凭据，不自动恢复任务。')
        .fontSize(12).fontColor(Theme.muted).width('100%')
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      .backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
  }
}
