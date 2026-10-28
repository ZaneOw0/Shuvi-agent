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
      Text('把你的问题发给 DeepSeek（deepseek-flash）。模型自己决定直接回答、读写文档或生成日程草稿；日程在你确认后才写入系统日历。')
        .fontSize(13).fontColor(Theme.muted).width('100%')
      Button(this.details ? '收起范围与费用 ▴' : '了解范围与费用 ▾').fontSize(Theme.noteSize).fontColor(Theme.accent)
        .backgroundColor(Color.Transparent).padding({ left: 0, right: 0 }).constraintSize({ minHeight: 32 })
        .id('runtime-chat-details').onClick((): void => { this.details = !this.details; })
      if (this.details) {
        Column({ space: 6 }) {
          Text('文档：可创建、读取、更新 txt/md，保存在系统文件管理器的 Download/com.example.shuvi/，其他应用也可能访问，请勿保存敏感资料。本次对话和模型选中的文档正文会发送到 DeepSeek；不联网搜索或读取已有日历。个人知识库默认关闭，另行授权后可按需查询。版本和执行记录保存在本机加密库。')
            .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
          Text('每次输入最多 500 字符；每轮模型最多连续 6 次请求、6 次文档工具调用、累计 2048 输出 tokens，最长 120 秒。每次启用最多 10 轮、累计 30 次模型请求，无自动重试。按已登记价格作每轮 USD 0.02 的本地估算检查，实际扣费以供应商账单为准。取消也可能计费，已保存的文档会保留。')
            .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
          Text('启用不发送模型请求，发送时才调用模型。离开助手页或退后台会结束会话并清除内存中的凭据和对话，不自动恢复任务；勾选记住后，Key 另存于本机系统安全存储，可随时删除。')
            .fontSize(Theme.noteSize).fontColor(Theme.muted).width('100%')
        }.width('100%').padding(10).backgroundColor(Theme.inputSurface).borderRadius(Theme.radius)
      }
      DeepSeekKeyField({ clearEpoch: this.clearEpoch, enableLabel: '同意并启用', idPrefix: 'runtime-chat', purpose: '真实对话',
        onKey: (key: Uint8Array): void => { this.onStart(key); } })
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      .backgroundColor(Theme.surface).borderRadius(Theme.cardRadius).border({ width: 1, color: Theme.line })
  }
}
