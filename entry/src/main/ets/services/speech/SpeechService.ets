import { common } from '@kit.AbilityKit';
import { HarmonySpeechPort } from './HarmonySpeechPort';
import { SpeechSession } from './SpeechSession';
import { VoiceArchive } from './VoiceArchive';
import { VoicePlayback } from './VoicePlayback';

export class SpeechService {
  static archive: VoiceArchive = new VoiceArchive();
  static playback: VoicePlayback = new VoicePlayback(SpeechService.archive);
  private static port: HarmonySpeechPort = new HarmonySpeechPort(SpeechService.archive);
  static session: SpeechSession = new SpeechSession(SpeechService.port);

  static bind(context: common.UIAbilityContext): void { SpeechService.port.bind(context); SpeechService.archive.bind(context); }
  static foreground(): void { SpeechService.session.setForeground(true); }
  static background(): void {
    SpeechService.session.setForeground(false);
    void SpeechService.playback.stop().catch((): void => {});
  }
  static release(): void { SpeechService.background(); SpeechService.port.unbind(); SpeechService.archive.unbind(); }
}
