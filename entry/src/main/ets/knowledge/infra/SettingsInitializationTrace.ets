import { hilog } from '@kit.PerformanceAnalysisKit';

/** Fixed phase names and elapsed time only: never log settings, credentials, paths or document contents. */
export function settingsInitializationTrace(scope: string, phase: string, started: number): void {
  hilog.info(0x0001, 'ShuviSettingsInit', 'scope=%{public}s phase=%{public}s elapsed_ms=%{public}d',
    scope, phase, Date.now() - started);
}
