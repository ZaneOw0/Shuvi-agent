import { Theme } from './Theme';
import { DeepSeekKeyField } from './DeepSeekKeyField';

@Component
export struct RuntimeChatSetup {
  @Prop clearEpoch: number = 0;
  @State details: boolean = false;
  onStart: (key: Uint8Array) => void = (_key: Uint8Array): void => {};
  build() {
    Column({ space: 10 }) {
      Text('启用真实对话').fontSize(Theme.titleSize).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
      Text('把你的问题或日程描述发给 DeepSeek（deepseek-flash）处理；日程在你确认后才写入系统日历。')
        .fontSize(13).fontColor(Theme.muted).width('100%')
      Button(this.details ? '收起范围与费用 ▴' : '了解范围与费用 ▾').fontSize(Theme.noteSize).fontColor(Theme.accent)
        .backgroundColor(Color.Transparent).padding({ left: 0, right: 0 }).constraintSize({ minHeight: 32 })
        .id('runtime-chat-details').onClick((): void => { this.details = !this.details; })
      if (this.details) {
        Column({ space: 6 }) {
          Text('补充日程信息时会携带尚未完成的描述，可能含个人信息；不会读取历史日历或知识库。问题和结果保存在本机加密库。')
            .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
          Text('单次最多 500 字符、1024 输出 tokens，30 秒请求超时；每次启用最多 10 次请求，无自动重试。按峰时价作 USD 0.01/次的本地估算检查，实际扣费以供应商账单为准。取消也可能计费。')
            .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
          Text('启用不发送模型请求，发送时才调用模型。离开助手页或退后台会结束会话并清除内存中的凭据，不自动恢复任务；勾选记住后，Key 另存于本机系统安全存储，可随时删除。')
            .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
        }.width('100%').padding(10).backgroundColor(Theme.inputSurface).borderRadius(Theme.radius)
      }
      DeepSeekKeyField({ clearEpoch: this.clearEpoch, enableLabel: '同意并启用', idPrefix: 'runtime-chat', purpose: '真实对话',
        onKey: (key: Uint8Array): void => { this.onStart(key); } })
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      .backgroundColor(Theme.surface).borderRadius(Theme.cardRadius).border({ width: 1, color: Theme.line })
  }
}
