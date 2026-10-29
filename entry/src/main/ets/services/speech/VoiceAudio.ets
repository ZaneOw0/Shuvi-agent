export class VoiceClip {
  id: string = '';
  path: string = '';
  durationMs: number = 0;
  createdAt: number = 0;
}

/** Bounded 16 kHz / mono / S16LE buffer; ASR receives paced 20 ms packets. */
export class VoicePcmBuffer {
  private data: Uint8Array = new Uint8Array(1920000);
  private length: number = 0;
  private cursor: number = 0;

  append(buffer: ArrayBuffer): boolean {
    const bytes = new Uint8Array(buffer);
    const count = Math.min(bytes.length, this.data.length - this.length);
    this.data.set(bytes.subarray(0, count), this.length); this.length += count;
    return this.length === this.data.length;
  }

  packet(flush: boolean): Uint8Array | undefined {
    const remaining = this.length - this.cursor;
    if (remaining <= 0 || (!flush && remaining < 640)) return undefined;
    const packet = new Uint8Array(640);
    const count = Math.min(remaining, 640);
    packet.set(this.data.subarray(this.cursor, this.cursor + count)); this.cursor += count;
    return packet;
  }

  drained(): boolean { return this.cursor === this.length; }
  bytes(): Uint8Array { return this.data.slice(0, this.length - this.length % 2); }
}

export function voiceWave(pcm: Uint8Array): Uint8Array {
  if (pcm.length === 0 || pcm.length > 1920000 || pcm.length % 2 !== 0) throw new Error('录音数据无效。');
  const wave = new Uint8Array(44 + pcm.length);
  const view = new DataView(wave.buffer);
  const riff = 'RIFF'; const format = 'WAVEfmt '; const data = 'data';
  for (let i = 0; i < 4; i++) wave[i] = riff.charCodeAt(i);
  view.setUint32(4, 36 + pcm.length, true);
  for (let i = 0; i < 8; i++) wave[8 + i] = format.charCodeAt(i);
  view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, 16000, true); view.setUint32(28, 32000, true);
  view.setUint16(32, 2, true); view.setUint16(34, 16, true);
  for (let i = 0; i < 4; i++) wave[36 + i] = data.charCodeAt(i);
  view.setUint32(40, pcm.length, true); wave.set(pcm, 44);
  return wave;
}

export function voicePcm(wave: Uint8Array): Uint8Array {
  if (wave.length < 46 || wave.length > 1920044) throw new Error('录音文件无效。');
  const view = new DataView(wave.buffer, wave.byteOffset, wave.byteLength);
  if (view.getUint32(0) !== 0x52494646 || view.getUint32(8) !== 0x57415645 ||
    view.getUint32(12) !== 0x666d7420 || view.getUint32(36) !== 0x64617461 ||
    view.getUint32(16, true) !== 16 || view.getUint16(20, true) !== 1 || view.getUint16(22, true) !== 1 ||
    view.getUint32(24, true) !== 16000 || view.getUint16(34, true) !== 16 ||
    view.getUint32(40, true) !== wave.length - 44 || (wave.length - 44) % 2 !== 0) {
    throw new Error('录音格式无效。');
  }
  return wave.slice(44);
}


/** Join backend-only transcription and the user's visible supplement as one request. */
export function composeVoiceMessage(transcript: string, supplement: string): string {
  const voice = transcript.trim(); const text = supplement.trim();
  if (voice.length === 0) return '';
  return text.length === 0 ? voice : voice + '\n\n' + text;
}
