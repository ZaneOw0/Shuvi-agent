export enum SettingsPreparationPhase { Idle = 'idle', Loading = 'loading', Ready = 'ready', Failed = 'failed' }

export class SettingsPreparationState {
  phase: SettingsPreparationPhase = SettingsPreparationPhase.Idle;
  slow: boolean = false;
  startedAt: number = 0;
  elapsedMs: number = 0;
}

/** One real initialization per service; navigation never belongs to a late completion callback. */
export class SettingsPreparationTask {
  private state: SettingsPreparationState = new SettingsPreparationState();
  private pending: Promise<void> | undefined;
  private timer: number = -1;
  private disposed: boolean = false;
  private load: () => Promise<void>;
  private changed: (state: SettingsPreparationState) => void;
  private slowAfterMs: number;
  constructor(load: () => Promise<void>, changed: (state: SettingsPreparationState) => void, slowAfterMs: number = 3000) {
    this.load = load; this.changed = changed; this.slowAfterMs = slowAfterMs;
  }
  snapshot(): SettingsPreparationState {
    const copied: SettingsPreparationState = new SettingsPreparationState();
    copied.phase = this.state.phase; copied.slow = this.state.slow;
    copied.startedAt = this.state.startedAt; copied.elapsedMs = this.state.elapsedMs; return copied;
  }
  private emit(): void { if (!this.disposed) { this.changed(this.snapshot()); } }
  prepare(): Promise<void> {
    if (this.disposed) { return Promise.reject(new Error('SETTINGS_PREPARATION_DISPOSED')); }
    if (this.pending !== undefined) { return this.pending; }
    if (this.state.phase === SettingsPreparationPhase.Ready) { return Promise.resolve(); }
    this.state = new SettingsPreparationState(); this.state.phase = SettingsPreparationPhase.Loading;
    this.state.startedAt = Date.now(); this.emit();
    this.pending = this.run(); return this.pending;
  }
  private async run(): Promise<void> {
    this.timer = setTimeout((): void => {
      this.timer = -1; this.state.slow = true; this.state.elapsedMs = Date.now() - this.state.startedAt; this.emit();
    }, this.slowAfterMs);
    try { await Promise.resolve().then(this.load); this.state.phase = SettingsPreparationPhase.Ready; }
    catch { this.state.phase = SettingsPreparationPhase.Failed; throw new Error('SETTINGS_PREPARATION_FAILED'); }
    finally {
      if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
      this.state.elapsedMs = Date.now() - this.state.startedAt; this.pending = undefined; this.emit();
    }
  }
  wait(): Promise<void> { return this.pending ?? Promise.resolve(); }
  dispose(): void { this.disposed = true; if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; } }
}
