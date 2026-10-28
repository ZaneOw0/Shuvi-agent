import { VoiceClip } from './VoiceAudio';
/** Platform-independent 60-second voice session. Transcripts remain in memory only. */
export enum SpeechPhase {
  Idle = 'idle', Authorizing = 'authorizing', Starting = 'starting',
  Listening = 'listening', Finishing = 'finishing', Ready = 'ready', Error = 'error'
}

export class SpeechView {
  phase: SpeechPhase = SpeechPhase.Idle;
  preview: string = '';
  text: string = '';
  message: string = '';
  resultId: number = 0;
  cleanupPending: boolean = false;
  busy: boolean = false;
  clip: VoiceClip | undefined = undefined;
}

export class SpeechEvents {
  started: () => void;
  result: (text: string, final: boolean, last: boolean) => void;
  complete: () => void;
  failed: (message: string) => void;

  constructor(started: () => void, result: (text: string, final: boolean, last: boolean) => void,
    complete: () => void, failed: (message: string) => void) {
    this.started = started; this.result = result; this.complete = complete; this.failed = failed;
  }
}

export interface SpeechHandle {
  start(): void;
  finish(): void;
  cancel(): void;
  shutdown(): Promise<void> | void;
  clip?(): VoiceClip | undefined;
}

export interface SpeechPort {
  authorize(): Promise<void>;
  create(id: string, events: SpeechEvents): Promise<SpeechHandle>;
}

export class SpeechSession {
  private port: SpeechPort;
  private view: SpeechView = new SpeechView();
  private listener: ((view: SpeechView) => void) | undefined = undefined;
  private handle: SpeechHandle | undefined = undefined;
  private epoch: number = 0;
  private timer: number = -1;
  private foreground: boolean = true;
  private preparing: boolean = false;
  private releasing: Promise<boolean> | undefined = undefined;
  private committed: string = '';
  private lastClause: boolean = false;

  constructor(port: SpeechPort) { this.port = port; }

  snapshot(): SpeechView {
    const copy = new SpeechView();
    copy.phase = this.view.phase; copy.preview = this.view.preview; copy.text = this.view.text;
    copy.message = this.view.message; copy.resultId = this.view.resultId;
    copy.cleanupPending = this.view.cleanupPending;
    copy.busy = this.busy();
    copy.clip = this.view.clip;
    return copy;
  }

  attach(listener: (view: SpeechView) => void): void {
    this.listener = listener; this.publish();
  }

  detach(): void { this.listener = undefined; void this.cancel(); }

  busy(): boolean {
    return this.view.cleanupPending || this.preparing || this.view.phase === SpeechPhase.Authorizing ||
      this.view.phase === SpeechPhase.Starting || this.view.phase === SpeechPhase.Listening ||
      this.view.phase === SpeechPhase.Finishing;
  }

  setForeground(value: boolean): void {
    this.foreground = value;
    if (!value) void this.cancel();
  }

  async start(): Promise<void> {
    if (!this.foreground || this.busy()) return;
    const token = ++this.epoch;
    this.preparing = true; this.committed = ''; this.lastClause = false;
    this.view = new SpeechView(); this.view.phase = SpeechPhase.Authorizing;
    this.view.message = '请允许使用麦克风'; this.publish();
    try {
      await this.port.authorize();
      if (!this.current(token)) return;
      this.view.phase = SpeechPhase.Starting; this.view.message = '正在准备语音识别…'; this.publish();
      this.arm(15000, (): void => void this.fail(token, '语音引擎启动超时，请重试。'));
      const events = new SpeechEvents(
        (): void => this.started(token),
        (text: string, final: boolean, last: boolean): void => this.result(token, text, final, last),
        (): void => void this.complete(token),
        (message: string): void => void this.fail(token, message)
      );
      const handle = await this.port.create(`shuvi-speech-${Date.now()}-${token}`, events);
      if (!this.current(token)) {
        // No recognition was started, but even a cancelled create must release its late engine.
        try { await handle.shutdown(); } catch (_) {
          this.handle = handle; this.cleanupError();
        }
        return;
      }
      this.handle = handle;
      handle.start();
    } catch (error) {
      await this.fail(token, error.message || '无法启动语音输入，请重试。');
    } finally {
      this.preparing = false; this.publish();
    }
  }

  finish(): void {
    if (this.view.phase !== SpeechPhase.Listening) return;
    const token = this.epoch;
    this.view.phase = SpeechPhase.Finishing; this.view.message = '正在整理识别结果…'; this.publish();
    this.arm(5000, (): void => void this.fail(token, '语音识别未及时结束，未填入不完整结果，请重试。'));
    try { this.handle?.finish(); } catch (_) { this.fail(token, '结束识别失败，请重试。'); }
  }

  dismissMessage(): void {
    if (this.busy()) return;
    this.view.message = ''; this.publish();
  }

  async cancel(): Promise<void> {
    ++this.epoch; this.clearTimer();
    const token = this.epoch;
    this.view.cleanupPending = true; this.view.message = '正在释放麦克风…'; this.publish();
    const released = await this.release();
    if (token !== this.epoch) return;
    this.committed = ''; this.lastClause = false;
    this.view = new SpeechView();
    if (this.preparing) this.view.message = '正在取消语音准备…';
    if (!released) this.cleanupError(); else this.publish();
  }

  private current(token: number): boolean {
    return token === this.epoch && this.foreground;
  }

  private started(token: number): void {
    if (!this.current(token) || this.view.phase !== SpeechPhase.Starting) return;
    this.view.phase = SpeechPhase.Listening; this.view.message = '正在聆听，最长 60 秒'; this.publish();
    this.arm(60000, (): void => this.finish());
  }

  private result(token: number, text: string, final: boolean, last: boolean): void {
    if (!this.current(token) || this.lastClause ||
      (this.view.phase !== SpeechPhase.Listening && this.view.phase !== SpeechPhase.Finishing)) return;
    if (typeof text !== 'string' || typeof final !== 'boolean' || typeof last !== 'boolean' || text.length > 8192) {
      this.fail(token, '语音识别返回了无效结果，请重试。'); return;
    }
    if (last && !final) { this.fail(token, '语音识别结果不完整，请重试。'); return; }
    if (final) this.committed += text;
    if (this.committed.length > 8192) { this.fail(token, '识别内容过长，请分段输入。'); return; }
    this.view.preview = final ? this.committed : this.committed + text;
    if (last) {
      this.lastClause = true;
      this.view.phase = SpeechPhase.Finishing; this.view.message = '正在结束语音输入…';
      this.arm(5000, (): void => void this.fail(token, '语音识别未及时结束，请重试。'));
    }
    this.publish();
  }

  private async complete(token: number): Promise<void> {
    if (!this.current(token) ||
      (this.view.phase !== SpeechPhase.Listening && this.view.phase !== SpeechPhase.Finishing)) return;
    // onComplete may occur without any final transcript (silence/cancel); never commit partial text.
    const text = this.committed.trim();
    const clip = this.handle?.clip?.();
    ++this.epoch; const closingToken = this.epoch; this.clearTimer();
    this.view.cleanupPending = true; this.publish();
    const released = await this.release();
    if (closingToken !== this.epoch) return;
    if (!released) { this.cleanupError(); return; }
    this.view.cleanupPending = false; this.view.clip = clip;
    this.view.preview = ''; this.view.text = text;
    this.view.phase = text.length > 0 ? SpeechPhase.Ready : SpeechPhase.Error;
    this.view.message = text.length === 0 ? (clip === undefined ? '没有采集到可保存的音频，请检查麦克风。' : '录音已保存，但未识别到可发送的内容。') :
      (text.length > 500 ? '录音已保存，内容超过本次输入上限，请分段录制。' : '录音已保存，可试听后发送。');
    if (text.length > 0) this.view.resultId = this.epoch;
    this.publish();
  }

  private async fail(token: number, message: string): Promise<void> {
    if (!this.current(token)) return;
    const clip = this.handle?.clip?.();
    ++this.epoch; const closingToken = this.epoch; this.clearTimer();
    this.view.cleanupPending = true; this.publish();
    const released = await this.release();
    if (closingToken !== this.epoch) return;
    if (!released) { this.cleanupError(); return; }
    this.view.cleanupPending = false; this.view.clip = clip;
    this.committed = ''; this.view.preview = ''; this.view.text = '';
    this.view.phase = SpeechPhase.Error; this.view.message = message; this.publish();
  }

  private async release(): Promise<boolean> {
    if (this.releasing !== undefined) return this.releasing;
    const pending = this.releaseNow(); this.releasing = pending;
    try { return await pending; } finally { if (this.releasing === pending) this.releasing = undefined; }
  }

  private async releaseNow(): Promise<boolean> {
    const handle = this.handle;
    if (handle === undefined) return true;
    // shutdown is still attempted when cancel fails; only confirmed shutdown permits another session.
    try { handle.cancel(); } catch (_) {}
    try { await handle.shutdown(); if (this.handle === handle) this.handle = undefined; return true; } catch (_) { return false; }
  }

  private cleanupError(): void {
    this.view.phase = SpeechPhase.Error; this.view.cleanupPending = true;
    this.view.text = ''; this.view.message = '麦克风释放未确认，请点击取消重试释放，或退出应用。';
    this.publish();
  }

  private arm(ms: number, action: () => void): void {
    this.clearTimer(); this.timer = setTimeout(action, ms);
  }

  private clearTimer(): void { if (this.timer !== -1) clearTimeout(this.timer); this.timer = -1; }
  private publish(): void { this.listener?.(this.snapshot()); }
}
