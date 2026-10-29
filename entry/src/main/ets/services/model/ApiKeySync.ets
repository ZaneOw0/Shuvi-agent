import { util } from '@kit.ArkTS';
import { DeepSeekKeyService } from './DeepSeekCredentialStore';
import { UnifiedSettingsService } from '../../knowledge/application/UnifiedSettingsService';

/**
 * Image understanding keeps its own copy of the DeepSeek key in the knowledge base's credential store. 我的 → API Key 管理
 * is the only place users change keys, so that copy follows the saved DeepSeek key.
 */
export class ApiKeySync {
  /** Copies the saved DeepSeek key to image understanding when that copy is missing. Never throws. */
  static async fillVisionKey(settings: UnifiedSettingsService | undefined): Promise<void> {
    if (settings === undefined) { return; }
    try {
      if ((await settings.credentialStatus()).present) { return; }
      const key: Uint8Array | undefined = await DeepSeekKeyService.store.load();
      if (key === undefined) { return; }
      try { await settings.saveVisionKey(util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(key)); }
      finally { key.fill(0); }
    } catch {
      // Image understanding then shows its key as missing; nothing else depends on the copy.
    }
  }

  /** Replaces (or removes) the image-understanding copy after the DeepSeek key changed. Returns false when it failed. */
  static async followDeepSeek(settings: UnifiedSettingsService | undefined, secret: string, remove: boolean): Promise<boolean> {
    if (settings === undefined) { return false; }
    try { await settings.saveVisionKey(remove ? '' : secret, remove); return true; } catch { return false; }
  }
}
