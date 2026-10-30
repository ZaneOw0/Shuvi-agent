import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { audio } from '@kit.AudioKit';
import { SpeechEvents, SpeechHandle, SpeechPort } from './SpeechSession';
import { VoiceClip, VoicePcmBuffer } from './VoiceAudio';
import { VoiceArchive } from './VoiceArchive';

/** Core Speech Kit rejected an audio packet ("Write audio failed because the start listening is failed"). */
const WRITE_AUDIO_REJECTED: number = 1002200010;
/** Feed ticks (20 ms each) to wait after the last audio packet before finish, so finish does not overtake it. */
const FINISH_QUIET_TICKS: number = 3;

class RecordedSpeechHandle implements SpeechHandle {
  private engine: speechRecognizer.SpeechRecognitionEngine;
  private id: string;
  private events: SpeechEvents;
  private archive: VoiceArchive;
  private buffer: VoicePcmBuffer = new VoicePcmBuffer();
  private recorder: audio.AudioCapturer | undefined = undefined;
  private opening: Promise<void> = Promise.resolve();
  private stopping: Promise<void> | undefined = undefined;
  private timer: number = -1;
  private cancelled: boolean = false;
  private finishing: boolean = false;
  private finishSent: boolean = false;
  private quietTicks: number = 0;
  private ended: boolean = false;
  private engineClosed: boolean = false;
  private saved: VoiceClip | undefined = undefined;
  private initializationFailed: boolean = false;

  constructor(engine: speechRecognizer.SpeechRecognitionEngine, id: string, events: SpeechEvents, archive: VoiceArchive) {
    this.engine = engine; this.id = id; this.events = events; this.archive = archive;
  }

  install(): void {
    const listener: speechRecognizer.RecognitionListener = {
      onStart: (id: string, _message: string): void => {
        if (id === this.id && !this.cancelled) {
          this.opening = this.openRecorder().catch((): void => {
            if (!this.cancelled) this.events.failed('麦克风录音启动失败，请检查权限与设备。');
          });
        }
      },
      onEvent: (_id: string, _code: number, _message: string): void => {},
      onResult: (id: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        if (id === this.id && !this.cancelled) this.events.result(result.result, result.isFinal, result.isLast);
      },
      onComplete: (id: string, _message: string): void => { if (id === this.id) void this.complete(''); },
      onError: (id: string, code: number, _message: string): void => {
        if (id !== this.id) return;
        // After finish the engine can report a rejected packet (emulator: 1002200010 / 610 "write audio ignore with no
        // preceding start listen") and still deliver the result and onComplete right after. Wait for those instead of
        // dropping the recognition; SpeechSession's finish timeout still bounds the wait.
        if (code === WRITE_AUDIO_REJECTED && this.finishSent) return;
        void this.complete(`录音已保留，但后台识别失败（${code}），本次未发送。`);
      }
    };
    try { this.engine.setListener(listener); } catch (_) { this.initializationFailed = true; }
  }

  start(): void {
    if (this.initializationFailed) throw new Error('语音识别初始化失败，请重试。');
    const params: speechRecognizer.StartParams = {
      sessionId: this.id,
      audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 },
      extraParams: { recognitionMode: 1, maxAudioDuration: 60000 }
    };
    this.engine.startListening(params);
  }

  private async openRecorder(): Promise<void> {
    const options: audio.AudioCapturerOptions = {
      streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000, channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION, capturerFlags: 0 }
    };
    const recorder = await audio.createAudioCapturer(options); this.recorder = recorder;
    if (this.cancelled || this.finishing) return;
    recorder.on('readData', (data: ArrayBuffer): void => {
      if (!this.cancelled && !this.finishing && !this.ended && this.buffer.append(data)) this.finish();
    });
    await recorder.start();
    if (this.cancelled) return;
    this.timer = setInterval((): void => this.feed(), 20); this.events.started();
  }

  private feed(): void {
    if (this.cancelled || this.ended || this.finishSent) return;
    try {
      const flushing = this.finishing && this.stopping === undefined;
      const packet = this.buffer.packet(flushing);
      if (packet !== undefined) { this.engine.writeAudio(this.id, packet); this.quietTicks = 0; } else { this.quietTicks++; }
      // Finish a few ticks after the last packet, or at once when the feed timer is not running.
      if (flushing && this.buffer.drained() && (this.quietTicks >= FINISH_QUIET_TICKS || this.timer === -1)) {
        this.finishSent = true; this.clearTimer(); this.engine.finish(this.id);
      }
    } catch (_) { void this.complete('录音已保留，但后台识别中断，本次未发送。'); }
  }

  finish(): void {
    if (this.finishing || this.cancelled || this.ended) return;
    this.finishing = true;
    void this.stopRecorder().then((): void => {
      if (!this.cancelled) { this.saveClip(); this.feed(); }
    }).catch((): void => {
      this.events.failed('停止麦克风失败，请取消重试释放。');
    });
  }

  private async stopRecorder(): Promise<void> {
    if (this.stopping !== undefined) return this.stopping;
    const pending = this.stopRecorderNow(); this.stopping = pending;
    try { await pending; } finally { if (this.stopping === pending) this.stopping = undefined; }
  }

  private async stopRecorderNow(): Promise<void> {
    await this.opening;
    const recorder = this.recorder;
    if (recorder !== undefined && recorder.state === audio.AudioState.STATE_RUNNING) await recorder.stop();
  }

  private async complete(error: string): Promise<void> {
    if (this.cancelled || this.ended) return;
    this.ended = true; this.finishing = true; this.clearTimer();
    try {
      await this.stopRecorder();
      if (this.cancelled) return;
      this.saveClip();
      if (error.length > 0) this.events.failed(error); else this.events.complete();
    } catch (_) { if (!this.cancelled) this.events.failed('录音保存或麦克风停止失败，本次未发送，请重试。'); }
  }

  private saveClip(): void {
    if (this.saved !== undefined) return;
    const pcm = this.buffer.bytes();
    if (pcm.length > 0) this.saved = this.archive.save(this.id, pcm);
  }

  clip(): VoiceClip | undefined { return this.saved; }
  cancel(): void { this.cancelled = true; this.clearTimer(); if (!this.engineClosed) this.engine.cancel(this.id); }

  async shutdown(): Promise<void> {
    this.cancelled = true; this.clearTimer();
    try { await this.stopRecorder(); } finally {
      try {
        const recorder = this.recorder;
        if (recorder !== undefined && recorder.state !== audio.AudioState.STATE_RELEASED) {
          recorder.off('readData'); await recorder.release(); this.recorder = undefined;
        }
      } finally { if (!this.engineClosed) { this.engine.shutdown(); this.engineClosed = true; } }
    }
  }

  private clearTimer(): void { if (this.timer !== -1) clearInterval(this.timer); this.timer = -1; }
}

export class HarmonySpeechPort implements SpeechPort {
  private context: common.UIAbilityContext | undefined = undefined;
  private archive: VoiceArchive;
  constructor(archive: VoiceArchive) { this.archive = archive; }
  bind(context: common.UIAbilityContext): void { this.context = context; }
  unbind(): void { this.context = undefined; }

  async authorize(): Promise<void> {
    if (!canIUse('SystemCapability.AI.SpeechRecognizer')) throw new Error('当前设备不支持系统语音识别。');
    const context = this.context;
    if (context === undefined) throw new Error('语音服务尚未就绪。');
    const permissions: Permissions[] = ['ohos.permission.MICROPHONE'];
    const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions);
    if (result.authResults.length !== 1 || result.authResults[0] !== 0) {
      throw new Error('未允许麦克风权限。你仍可键盘输入，或在系统设置中授权后重试。');
    }
  }

  async create(id: string, events: SpeechEvents): Promise<SpeechHandle> {
    const params: speechRecognizer.CreateEngineParams = {
      // API26: online=1 is offline. Pauses segment sentences without ending recording.
      language: 'zh-CN', online: 1, extraParams: { locate: 'CN', recognizerMode: 'long' }
    };
    const engine = await speechRecognizer.createEngine(params);
    const handle = new RecordedSpeechHandle(engine, id, events, this.archive); handle.install();
    return handle;
  }
}
