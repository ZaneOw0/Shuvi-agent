import { Theme } from './Theme';
import { AppIcon } from './AppIcon';
import { VoiceClip } from '../services/speech/VoiceAudio';

@Component
export struct VoiceMessageBubble {
  @Prop recording: VoiceClip | undefined = undefined;
  @Prop playingId: string = '';
  onPlay: (clip: VoiceClip) => void = (_clip: VoiceClip): void => {};

  build() {
    Button() {
      Row({ space: 10 }) {
        AppIcon({ source: $r('app.media.chat_wave'), size: 24 })
        Text(this.playingId === this.recording?.id ? '停止播放' : '播放语音').fontSize(15).fontColor(Theme.ink)
        Text(`${Math.max(1, Math.ceil((this.recording?.durationMs ?? 0) / 1000))} 秒`).fontSize(13).fontColor(Theme.muted)
      }.padding({ left: 14, right: 14, top: 12, bottom: 12 })
    }.constraintSize({ minHeight: 48 }).backgroundColor(Theme.bubble)
      .borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 })
      .id(`voice-play-${this.recording?.id ?? ''}`)
      .accessibilityText(`${this.playingId === this.recording?.id ? '停止' : '播放'}语音，${Math.max(1, Math.ceil((this.recording?.durationMs ?? 0) / 1000))} 秒`)
      .onClick((): void => { const clip = this.recording; if (clip !== undefined) this.onPlay(clip); })
  }
}
