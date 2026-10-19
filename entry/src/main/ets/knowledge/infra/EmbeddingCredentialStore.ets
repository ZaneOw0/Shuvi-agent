import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EmbeddingCredentialPort } from '../domain/KnowledgePorts';
import { EmbeddingConfig, EmbeddingCredentialStatus, EmbeddingPurpose } from '../domain/EmbeddingModels';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { embeddingCredentialAlias, embeddingEndpoint } from '../pipeline/EmbeddingPolicy';
import { documentValidateToken } from '../domain/DocumentParseModels';

export interface EmbeddingAssetStorePort {
  query(query: asset.AssetMap): Promise<asset.AssetMap[]>; add(attributes: asset.AssetMap): Promise<void>;
  update(query: asset.AssetMap, attributes: asset.AssetMap): Promise<void>; remove(query: asset.AssetMap): Promise<void>;
}
class EmbeddingPlatformAssetStore implements EmbeddingAssetStorePort {
  query(query: asset.AssetMap): Promise<asset.AssetMap[]> { return asset.query(query); }
  add(attributes: asset.AssetMap): Promise<void> { return asset.add(attributes); }
  update(query: asset.AssetMap, attributes: asset.AssetMap): Promise<void> { return asset.update(query, attributes); }
  remove(query: asset.AssetMap): Promise<void> { return asset.remove(query); }
}
function embeddingAssetQuery(config: EmbeddingConfig, kind?: asset.ReturnType): asset.AssetMap {
  const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
  query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(embeddingCredentialAlias(config)));
  if (kind !== undefined) { query.set(asset.Tag.RETURN_TYPE, kind); } return query;
}
function embeddingStorageFailure(error: BusinessError, stage: string): KnowledgeFailure {
  const code: number = typeof error?.code === 'number' && Number.isSafeInteger(error.code) ? error.code : 0;
  return new KnowledgeFailure(`AssetStoreRejected:${code}`, stage);
}
export class EmbeddingCredentialStore implements EmbeddingCredentialPort {
  private store: EmbeddingAssetStorePort;
  private generation: number = 0; private active: Uint8Array[] = []; private requests: rcp.Request[] = [];
  constructor(store: EmbeddingAssetStorePort = new EmbeddingPlatformAssetStore()) { this.store = store; }
  clearTransient(): void { this.generation++; for (const bytes of this.active) { bytes.fill(0); } for (const request of this.requests) { request.headers = undefined; } }
  private async attributes(config: EmbeddingConfig): Promise<asset.AssetMap[]> {
    return Promise.resolve().then((): Promise<asset.AssetMap[]> => this.store.query(embeddingAssetQuery(config, asset.ReturnType.ATTRIBUTES)))
      .catch((error: BusinessError): asset.AssetMap[] => { if (error?.code === 24000002) { return []; } throw embeddingStorageFailure(error, 'credential-attributes'); });
  }
  private async checked(config: EmbeddingConfig): Promise<EmbeddingCredentialStatus> {
    const rows: asset.AssetMap[] = await this.attributes(config);
    if (rows.length > 1 || (rows.length === 1 && (rows[0].get(asset.Tag.ACCESSIBILITY) !== asset.Accessibility.DEVICE_UNLOCKED || rows[0].get(asset.Tag.SYNC_TYPE) !== asset.SyncType.NEVER))) { throw new KnowledgeFailure('CredentialAttributesMismatch', 'embedding'); }
    return rows.length === 1 ? EmbeddingCredentialStatus.Configured : EmbeddingCredentialStatus.Missing;
  }
  async status(config: EmbeddingConfig): Promise<EmbeddingCredentialStatus> { try { return await this.checked(config); } catch { return EmbeddingCredentialStatus.Unavailable; } }
  async save(config: EmbeddingConfig, input: string, replace: boolean): Promise<EmbeddingCredentialStatus> {
    documentValidateToken(input); const bytes: Uint8Array = new util.TextEncoder().encodeInto(input);
    try {
      if ((await this.checked(config) === EmbeddingCredentialStatus.Configured) !== replace) { throw new KnowledgeFailure('CredentialConflict', 'embedding'); }
      const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>(); attributes.set(asset.Tag.SECRET, bytes);
      if (replace) { await Promise.resolve().then((): Promise<void> => this.store.update(embeddingAssetQuery(config), attributes)).catch((error: BusinessError): void => { throw embeddingStorageFailure(error, 'credential-update'); }); }
      else {
        attributes.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(embeddingCredentialAlias(config)));
        attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED); attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
        attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.THROW_ERROR);
        await Promise.resolve().then((): Promise<void> => this.store.add(attributes)).catch((error: BusinessError): void => { throw embeddingStorageFailure(error, 'credential-add'); });
      }
      if (await this.checked(config) !== EmbeddingCredentialStatus.Configured) { throw new KnowledgeFailure('CredentialWriteUnconfirmed', 'embedding'); }
      return EmbeddingCredentialStatus.Configured;
    } finally { bytes.fill(0); this.clearTransient(); }
  }
  async remove(config: EmbeddingConfig): Promise<EmbeddingCredentialStatus> {
    try {
      if (await this.checked(config) === EmbeddingCredentialStatus.Configured) { await this.store.remove(embeddingAssetQuery(config)).catch((error: BusinessError): void => { throw embeddingStorageFailure(error, 'credential-remove'); }); }
      if (await this.checked(config) !== EmbeddingCredentialStatus.Missing) { throw new KnowledgeFailure('CredentialRemovalUnconfirmed', 'embedding'); }
      return EmbeddingCredentialStatus.Missing;
    } finally { this.clearTransient(); }
  }
  async fetch(config: EmbeddingConfig, purpose: EmbeddingPurpose, request: rcp.Request, session: rcp.Session, check: () => void, admission?: (launch: () => void) => Promise<void>): Promise<rcp.Response> {
    // No caller-supplied host can receive the secret, including a redirect target.
    if (request.url.toString() !== embeddingEndpoint(config, purpose)) { throw new KnowledgeFailure('CredentialDestinationRejected', 'embedding'); }
    const epoch: number = this.generation; await this.checked(config);
    const rows: asset.AssetMap[] = await this.store.query(embeddingAssetQuery(config, asset.ReturnType.ALL));
    if (rows.length !== 1) { throw new KnowledgeFailure('CredentialMissing', 'embedding'); }
    const bytes: asset.Value | undefined = rows[0].get(asset.Tag.SECRET);
    if (!(bytes instanceof Uint8Array)) { throw new KnowledgeFailure('CredentialType', 'embedding'); }
    this.active.push(bytes); this.requests.push(request);
    try {
      if (epoch !== this.generation) { throw new KnowledgeFailure('CredentialStale', 'embedding'); }
      check(); const secret: string = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes); documentValidateToken(secret);
      const headers: rcp.RequestHeaders = { 'authorization': `Bearer ${secret}`, 'content-type': 'application/json', 'accept': 'application/json' };
      request.headers = headers; check();
      if (admission === undefined) { return await session.fetch(request); }
      const response: EmbeddingFetchLaunch = new EmbeddingFetchLaunch();
      await admission((): void => { check(); response.pending = session.fetch(request); });
      if (response.pending === undefined) { throw new KnowledgeFailure('NoRequestAdmissionDidNotLaunch','embedding'); } return await response.pending;
    } finally { bytes.fill(0); request.headers = undefined; this.active = this.active.filter((item: Uint8Array): boolean => item !== bytes); this.requests = this.requests.filter((item: rcp.Request): boolean => item !== request); }
  }
}
class EmbeddingFetchLaunch { pending: Promise<rcp.Response> | undefined = undefined; }
