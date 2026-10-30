import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import util from '@ohos.util';
import { VisionChatImage } from '../model/VisionChatProtocol';
import { ConversationImagePort, validChatImageName } from './AssistantConversations';

const DIRECTORY: string = 'chat_images';

/**
 * Pictures the user sent in the assistant chat, kept in the app's private files only so a saved conversation can show
 * them again. Each is the re-encoded copy that was sent (no EXIF/GPS, no original file name); the model never receives
 * a kept picture again. Excluded from system backup like voice messages; deleted with their conversation.
 */
export class ChatImageStore implements ConversationImagePort {
  private filesDir: string = '';
  bind(context: common.UIAbilityContext): void { this.filesDir = context.filesDir; }

  private directory(): string {
    if (this.filesDir.length === 0) throw new Error('图片存储尚未就绪。');
    const directory: string = this.filesDir + '/' + DIRECTORY;
    if (!fs.accessSync(directory)) fs.mkdirSync(directory);
    return directory;
  }

  /** Writes a copy of the picture (the caller keeps ownership of `image`) and returns the kept file's name. */
  save(image: VisionChatImage): string {
    const extension: string = image.mime === 'image/png' ? 'png' : (image.mime === 'image/webp' ? 'webp' : 'jpg');
    const name: string = 'chat-image-' + util.generateRandomUUID().toLowerCase() + '.' + extension;
    if (!validChatImageName(name) || image.bytes.length < 1) throw new Error('图片无效。');
    const path: string = this.directory() + '/' + name; const temporary: string = path + '.tmp';
    const bytes: Uint8Array = image.bytes.slice();
    const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    let closed: boolean = false;
    try {
      if (fs.writeSync(file.fd, bytes.buffer) !== bytes.length) throw new Error('图片保存不完整。');
      fs.fsyncSync(file.fd); fs.closeSync(file.fd); closed = true;
      fs.renameSync(temporary, path);
    } catch (_) {
      if (!closed) fs.closeSync(file.fd);
      if (fs.accessSync(temporary)) fs.unlinkSync(temporary);
      throw new Error('图片保存失败，请检查本机存储空间。');
    } finally { bytes.fill(0); }
    return name;
  }

  uri(name: string): string | undefined {
    if (!validChatImageName(name) || this.filesDir.length === 0) return undefined;
    const path: string = this.filesDir + '/' + DIRECTORY + '/' + name;
    return fs.accessSync(path) ? fileUri.getUriFromPath(path) : undefined;
  }

  remove(names: string[]): void {
    if (this.filesDir.length === 0) return;
    for (const name of names) {
      if (!validChatImageName(name)) continue;
      const path: string = this.filesDir + '/' + DIRECTORY + '/' + name;
      try { if (fs.accessSync(path)) fs.unlinkSync(path); } catch (_) { /* Left on the device; never blocks the list. */ }
    }
  }
}

export class ChatImageService {
  static readonly store: ChatImageStore = new ChatImageStore();
}
