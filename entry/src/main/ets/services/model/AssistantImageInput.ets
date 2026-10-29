import { common } from '@kit.AbilityKit';
import { fileUri, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { ASSISTANT_IMAGE_MAX_BYTES, ASSISTANT_IMAGE_MAX_SIDE } from '../calendar/AssistantIntent';
import { VisionChatImage } from './VisionChatProtocol';
import { VisionImageFailure, VisionPreparedImage } from './VisionImagePorts';
import { VisionImagePreparer } from './VisionImagePreparer';

/** Text sent with an image when the user typed or said nothing; the model describes the picture and asks what to do. */
export const ASSISTANT_IMAGE_DEFAULT_PROMPT: string = '请看看这张图片。';

/**
 * Assistant image input: the system gallery picker (no gallery permission) and the same sanitizer as the vision
 * feature (re-encoded, no EXIF/GPS, no file name or path leaves the device). The bytes stay in memory only.
 */
export class AssistantImageInput {
  private static readonly preparer: VisionImagePreparer = new VisionImagePreparer(ASSISTANT_IMAGE_MAX_SIDE);

  /** Returns the picked image URI, or '' when the user closed the picker without choosing. */
  static async pick(): Promise<string> {
    const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = 1;
    const result: photoAccessHelper.PhotoSelectResult = await new photoAccessHelper.PhotoViewPicker().select(options);
    return result.photoUris.length === 1 ? result.photoUris[0] : '';
  }

  /** System file picker limited to JPG/PNG/WebP (for example images in Download); '' when cancelled. */
  static async pickFile(context: common.Context): Promise<string> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1; options.selectMode = picker.DocumentSelectMode.FILE;
    options.fileSuffixFilters = ['图片|.jpg,.jpeg,.png,.webp'];
    const selected: string[] = await new picker.DocumentViewPicker(context).select(options);
    return selected.length === 1 ? selected[0] : '';
  }

  /** Reads and re-encodes the picked image; throws VisionImageFailure with a code for failureText(). */
  static async prepare(uri: string): Promise<VisionChatImage> {
    const prepared: VisionPreparedImage = await AssistantImageInput.preparer.prepare(uri, AssistantImageInput.displayName(uri));
    if (prepared.image.bytes.length > ASSISTANT_IMAGE_MAX_BYTES) {
      prepared.image.bytes.fill(0); throw new VisionImageFailure('IMAGE_SANITIZED_BUDGET');
    }
    return prepared.image;
  }

  /** Local name used only for the format check (its suffix); it is never sent. */
  static displayName(uri: string): string {
    let name: string = uri.slice(uri.lastIndexOf('/') + 1);
    try { name = new fileUri.FileUri(uri).name; } catch {
      try { name = decodeURIComponent(name); } catch { /* Keep the raw segment. */ }
    }
    name = name.replace(/[\u0000-\u001f\u007f]/g, '').trim();
    if (name.length > 200) name = name.slice(name.length - 200).trim();
    return name.length > 0 ? name : 'image';
  }

  static failureText(error: Object): string {
    const code: string = error instanceof VisionImageFailure ? error.code : '';
    if (code === 'IMAGE_HEADER_INVALID' || code === 'IMAGE_SDK_HEADER_CONFLICT') {
      return '只支持 JPG、PNG、WebP 静态图片（不支持动图、HEIC 或超过 2000 万像素的图片），请换一张。';
    }
    if (code === 'IMAGE_SIZE_OR_TYPE_INVALID') return '图片超过 20 MB 或不是普通图片文件，请换一张。';
    if (code === 'IMAGE_SANITIZED_BUDGET') return '图片压缩后仍然过大，请换一张或先裁剪。';
    if (code === 'IMAGE_CHANGED_DURING_READ') return '图片在读取时发生了变化，请重新选择。';
    if (code === 'IMAGE_REMOTE_URI_UNSUPPORTED') return '云端图片还没有下载到本机，请下载后再选择。';
    return '没能读取这张图片，请重新选择或换一张。';
  }
}
