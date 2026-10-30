import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

/** Opt-in "remember DeepSeek key" storage: the system Asset Store on this device only, never synced or logged. */
export enum DeepSeekKeyStatus { Checking = 'Checking', Missing = 'Missing', Saved = 'Saved', Unavailable = 'Unavailable' }
export const DEEPSEEK_KEY_ALIAS: string = 'shuvi.deepseek.api-key.v1';
/** Web search calls Tavily straight from the phone; its key is a separate device-only record of the same shape. */
export const TAVILY_KEY_ALIAS: string = 'shuvi.tavily.api-key.v1';
export const DEEPSEEK_KEY_MAX_BYTES: number = 2048;
const ASSET_NOT_FOUND: number = 24000002;

export interface DeepSeekAssetPort {
  query(query: asset.AssetMap): Promise<asset.AssetMap[]>; add(attributes: asset.AssetMap): Promise<void>;
  update(query: asset.AssetMap, attributes: asset.AssetMap): Promise<void>; remove(query: asset.AssetMap): Promise<void>;
}
export class PlatformDeepSeekAssetStore implements DeepSeekAssetPort {
  query(query: asset.AssetMap): Promise<asset.AssetMap[]> { return asset.query(query); }
  add(attributes: asset.AssetMap): Promise<void> { return asset.add(attributes); }
  update(query: asset.AssetMap, attributes: asset.AssetMap): Promise<void> { return asset.update(query, attributes); }
  remove(query: asset.AssetMap): Promise<void> { return asset.remove(query); }
}
export class DeepSeekCredentialError extends Error {
  readonly stage: string;
  constructor(stage: string) { super('DEEPSEEK_KEY_STORE_' + stage); this.stage = stage; }
}
function aliasQuery(alias: string, kind?: asset.ReturnType): asset.AssetMap {
  const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
  if (kind !== undefined) { query.set(asset.Tag.RETURN_TYPE, kind); }
  return query;
}
/** Printable ASCII without spaces, 1..2048 bytes: DeepSeek and Tavily keys never need anything else. */
export function deepSeekKeyAcceptable(key: Uint8Array): boolean {
  if (key.length === 0 || key.length > DEEPSEEK_KEY_MAX_BYTES) { return false; }
  for (let i: number = 0; i < key.length; i++) { if (key[i] < 0x21 || key[i] > 0x7e) { return false; } }
  return true;
}

/** What a caller that only reads a saved key needs: status, and a fresh copy it clears after use. */
export interface CredentialKeySource {
  status(): Promise<DeepSeekKeyStatus>;
  load(): Promise<Uint8Array | undefined>;
}

export class DeepSeekCredentialStore implements CredentialKeySource {
  private readonly store: DeepSeekAssetPort;
  private readonly alias: string;
  constructor(store: DeepSeekAssetPort = new PlatformDeepSeekAssetStore(), alias: string = DEEPSEEK_KEY_ALIAS) {
    this.store = store; this.alias = alias;
  }

  private async rows(kind: asset.ReturnType): Promise<asset.AssetMap[]> {
    return Promise.resolve().then((): Promise<asset.AssetMap[]> => this.store.query(aliasQuery(this.alias, kind)))
      .catch((error: BusinessError): asset.AssetMap[] => {
        if (error?.code === ASSET_NOT_FOUND) { return []; }
        throw new DeepSeekCredentialError('QUERY');
      });
  }
  private async checked(): Promise<DeepSeekKeyStatus> {
    const rows: asset.AssetMap[] = await this.rows(asset.ReturnType.ATTRIBUTES);
    if (rows.length === 0) { return DeepSeekKeyStatus.Missing; }
    if (rows.length > 1 || rows[0].get(asset.Tag.ACCESSIBILITY) !== asset.Accessibility.DEVICE_UNLOCKED ||
      rows[0].get(asset.Tag.SYNC_TYPE) !== asset.SyncType.NEVER) { throw new DeepSeekCredentialError('ATTRIBUTES'); }
    return DeepSeekKeyStatus.Saved;
  }
  async status(): Promise<DeepSeekKeyStatus> {
    try { return await this.checked(); } catch { return DeepSeekKeyStatus.Unavailable; }
  }
  /** Stores a copy of the key; the caller keeps ownership of (and clears) its own buffer. */
  async save(key: Uint8Array): Promise<void> {
    if (!deepSeekKeyAcceptable(key)) { throw new DeepSeekCredentialError('INVALID_KEY'); }
    const secret: Uint8Array = key.slice();
    try {
      const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      attributes.set(asset.Tag.SECRET, secret);
      if (await this.checked() === DeepSeekKeyStatus.Saved) {
        await Promise.resolve().then((): Promise<void> => this.store.update(aliasQuery(this.alias), attributes))
          .catch((): void => { throw new DeepSeekCredentialError('UPDATE'); });
      } else {
        attributes.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(this.alias));
        attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
        attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
        attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.THROW_ERROR);
        await Promise.resolve().then((): Promise<void> => this.store.add(attributes))
          .catch((): void => { throw new DeepSeekCredentialError('ADD'); });
      }
      if (await this.checked() !== DeepSeekKeyStatus.Saved) { throw new DeepSeekCredentialError('UNCONFIRMED'); }
    } finally { secret.fill(0); }
  }
  /** Returns a fresh copy for one session start, or undefined when nothing usable is stored. */
  async load(): Promise<Uint8Array | undefined> {
    if (await this.checked() !== DeepSeekKeyStatus.Saved) { return undefined; }
    const rows: asset.AssetMap[] = await this.rows(asset.ReturnType.ALL);
    if (rows.length !== 1) { return undefined; }
    const stored: asset.Value | undefined = rows[0].get(asset.Tag.SECRET);
    if (!(stored instanceof Uint8Array)) { return undefined; }
    const copy: Uint8Array = stored.slice(); stored.fill(0);
    if (!deepSeekKeyAcceptable(copy)) { copy.fill(0); return undefined; }
    return copy;
  }
  /** Removes the entry even when its attributes look wrong, so a damaged record can always be cleared. */
  async remove(): Promise<void> {
    if ((await this.rows(asset.ReturnType.ATTRIBUTES)).length > 0) {
      await Promise.resolve().then((): Promise<void> => this.store.remove(aliasQuery(this.alias)))
        .catch((): void => { throw new DeepSeekCredentialError('REMOVE'); });
    }
    if ((await this.rows(asset.ReturnType.ATTRIBUTES)).length !== 0) { throw new DeepSeekCredentialError('UNCONFIRMED'); }
  }
}

export class DeepSeekKeyService {
  static readonly store: DeepSeekCredentialStore = new DeepSeekCredentialStore();
}

/** The Tavily key used by web search: same device-only, never-synced Asset Store record, under its own alias. */
export class TavilyKeyService {
  static readonly store: DeepSeekCredentialStore = new DeepSeekCredentialStore(new PlatformDeepSeekAssetStore(), TAVILY_KEY_ALIAS);
}
