import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { VoiceClip, voiceWave, voicePcm } from './VoiceAudio';

/** Only audio is durable. Transcripts never enter filenames, metadata or the archive. */
export class VoiceArchive {
  private context: common.UIAbilityContext | undefined = undefined;
  bind(context: common.UIAbilityContext): void { this.context = context; }
  unbind(): void { this.context = undefined; }

  private directory(): string {
    const context = this.context;
    if (context === undefined) throw new Error('录音存储尚未就绪。');
    const directory = context.filesDir + '/voice_messages';
    if (!fs.accessSync(directory)) fs.mkdirSync(directory);
    return directory;
  }

  private filename(id: string): string {
    if (!/^shuvi-speech-[0-9]+-[0-9]+$/.test(id)) throw new Error('录音标识无效。');
    return this.directory() + '/' + id + '.wav';
  }

  save(id: string, pcm: Uint8Array): VoiceClip {
    const path = this.filename(id); const temporary = path + '.tmp';
    if (fs.accessSync(path)) throw new Error('录音标识冲突，未覆盖已有录音。');
    const wave = voiceWave(pcm);
    const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    let closed: boolean = false;
    try {
      if (fs.writeSync(file.fd, wave.buffer) !== wave.length) throw new Error('录音保存不完整。');
      fs.fsyncSync(file.fd); fs.closeSync(file.fd); closed = true;
      fs.renameSync(temporary, path);
    } catch (_) {
      if (!closed) fs.closeSync(file.fd);
      if (fs.accessSync(temporary)) fs.unlinkSync(temporary);
      throw new Error('录音保存失败，请检查本机存储空间。');
    }
    const clip = new VoiceClip(); clip.id = id; clip.path = path;
    clip.durationMs = pcm.length / 32; clip.createdAt = Number(id.split('-')[2]);
    return clip;
  }

  list(): VoiceClip[] {
    const directory = this.directory();
    const files = fs.listFileSync(directory);
    const clips: VoiceClip[] = [];
    for (const file of files) {
      if (!/^shuvi-speech-[0-9]+-[0-9]+\.wav$/.test(file)) continue;
      const id = file.substring(0, file.length - 4); const path = this.filename(id);
      const size = fs.statSync(path).size;
      if (size < 46 || size > 1920044 || (size - 44) % 2 !== 0) continue;
      const clip = new VoiceClip(); clip.id = id; clip.path = path;
      clip.createdAt = Number(id.split('-')[2]); clip.durationMs = (size - 44) / 32;
      clips.push(clip);
    }
    return clips.sort((a: VoiceClip, b: VoiceClip): number => b.createdAt - a.createdAt);
  }

  read(clip: VoiceClip): Uint8Array {
    const path = this.filename(clip.id);
    const size = fs.statSync(path).size;
    if (size < 46 || size > 1920044) throw new Error('录音文件无效。');
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const bytes = new Uint8Array(size);
    try {
      if (fs.readSync(file.fd, bytes.buffer) !== size) throw new Error('录音读取不完整。');
    } finally { fs.closeSync(file.fd); }
    return voicePcm(bytes);
  }

  remove(clip: VoiceClip): void { fs.unlinkSync(this.filename(clip.id)); }
}
