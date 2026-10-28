import { audio } from '@kit.AudioKit';
import { VoiceClip } from './VoiceAudio';
import { VoiceArchive } from './VoiceArchive';

export class VoicePlayback {
  private archive: VoiceArchive;
  private renderer: audio.AudioRenderer | undefined = undefined;
  private epoch: number = 0;
  private timer: number = -1;
  private active: string = '';
  private stopping: Promise<void> | undefined = undefined;
  private listener: ((id: string, message: string) => void) | undefined = undefined;

  constructor(archive: VoiceArchive) { this.archive = archive; }
  attach(listener: (id: string, message: string) => void): void { this.listener = listener; }
  detach(): void { this.listener = undefined; void this.stop(); }

  async play(clip: VoiceClip): Promise<void> {
    const same = this.active === clip.id;
    await this.stop();
    if (same) return;
    const token = ++this.epoch;
    try {
      const pcm = this.archive.read(clip);
      const options: audio.AudioRendererOptions = {
        streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
        rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_VOICE_MESSAGE, rendererFlags: 0 }
      };
      const renderer = await audio.createAudioRenderer(options);
      if (token !== this.epoch) { await renderer.release(); return; }
      this.renderer = renderer; this.active = clip.id;
      let offset: number = 0; let draining: boolean = false;
      renderer.on('writeData', (buffer: ArrayBuffer): audio.AudioDataCallbackResult => {
        if (token !== this.epoch) return audio.AudioDataCallbackResult.INVALID;
        const output = new Uint8Array(buffer); output.fill(0);
        const count = Math.min(output.length, pcm.length - offset);
        output.set(pcm.subarray(offset, offset + count)); offset += count;
        if (offset === pcm.length && !draining) {
          draining = true;
          this.timer = setTimeout((): void => { if (token === this.epoch) void this.stop(); },
            Math.ceil(buffer.byteLength / 32) + 100);
        }
        return audio.AudioDataCallbackResult.VALID;
      });
      await renderer.start();
      if (token === this.epoch) this.listener?.(clip.id, '');
    } catch (_) {
      if (token !== this.epoch) return;
      await this.stop(); this.listener?.('', '录音播放失败，请检查文件与音频设备。');
    }
  }

  async stop(): Promise<void> {
    ++this.epoch;
    if (this.timer !== -1) clearTimeout(this.timer); this.timer = -1;
    if (this.stopping !== undefined) return this.stopping;
    const pending = this.stopNow(); this.stopping = pending;
    try { await pending; } finally { if (this.stopping === pending) this.stopping = undefined; }
  }

  private async stopNow(): Promise<void> {
    const renderer = this.renderer;
    if (renderer !== undefined) {
      try { if (renderer.state === audio.AudioState.STATE_RUNNING) await renderer.stop(); }
      finally { renderer.off('writeData'); await renderer.release(); if (this.renderer === renderer) this.renderer = undefined; }
    }
    this.active = ''; this.listener?.('', '');
  }
}
