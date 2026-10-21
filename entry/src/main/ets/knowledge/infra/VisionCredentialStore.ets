import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { VisionCredentialPort, VisionCredentialStatus, VisionFailure } from '../domain/VisionModels';
import { VISION_ENDPOINT } from '../pipeline/VisionPolicy';
import { documentValidateToken } from '../domain/DocumentParseModels';

export const VISION_CREDENTIAL_ALIAS: string = 'shuvi.vision.deepseek.flash.v1';
export interface VisionAssetStorePort {
  query(query: asset.AssetMap): Promise<asset.AssetMap[]>; add(attributes: asset.AssetMap): Promise<void>;
  update(query: asset.AssetMap, attributes: asset.AssetMap): Promise<void>; remove(query: asset.AssetMap): Promise<void>;
}
class VisionPlatformAssetStore implements VisionAssetStorePort {
  query(q: asset.AssetMap): Promise<asset.AssetMap[]> { return asset.query(q); }
  add(a: asset.AssetMap): Promise<void> { return asset.add(a); }
  update(q: asset.AssetMap,a: asset.AssetMap): Promise<void> { return asset.update(q,a); }
  remove(q: asset.AssetMap): Promise<void> { return asset.remove(q); }
}
function visionAssetQuery(type?: asset.ReturnType): asset.AssetMap {
  const q: asset.AssetMap=new Map<asset.Tag,asset.Value>(); q.set(asset.Tag.ALIAS,new util.TextEncoder().encodeInto(VISION_CREDENTIAL_ALIAS)); if (type!==undefined) { q.set(asset.Tag.RETURN_TYPE,type); } return q;
}
class VisionFetchPending { pending: Promise<rcp.Response> | undefined; }
export class VisionCredentialStore implements VisionCredentialPort {
  private store: VisionAssetStorePort; private epoch: number=0;
  constructor(store: VisionAssetStorePort=new VisionPlatformAssetStore()) { this.store=store; }
  private async attributes(): Promise<asset.AssetMap[]> {
    return this.store.query(visionAssetQuery(asset.ReturnType.ATTRIBUTES)).catch((e: BusinessError): asset.AssetMap[]=> { if (e.code===24000002) { return []; } throw new VisionFailure('CredentialStoreUnavailable','credential'); });
  }
  async status(): Promise<VisionCredentialStatus> {
    const s: VisionCredentialStatus=new VisionCredentialStatus();
    try { const rows: asset.AssetMap[]=await this.attributes(); if (rows.length>1 || rows.some((r: asset.AssetMap): boolean=>r.get(asset.Tag.ACCESSIBILITY)!==asset.Accessibility.DEVICE_UNLOCKED || r.get(asset.Tag.SYNC_TYPE)!==asset.SyncType.NEVER)) { throw new VisionFailure('CredentialAttributes','credential'); } s.present=rows.length===1; }
    catch { s.failure='CredentialUnavailable'; } return s;
  }
  async save(secret: string): Promise<void> {
    documentValidateToken(secret); this.epoch++; const bytes: Uint8Array=new util.TextEncoder().encodeInto(secret);
    try { const state: VisionCredentialStatus=await this.status(); if (state.failure.length>0) { throw new VisionFailure(state.failure,'credential'); }
      const a: asset.AssetMap=new Map<asset.Tag,asset.Value>(); a.set(asset.Tag.SECRET,bytes);
      if (state.present) { await this.store.update(visionAssetQuery(),a); }
      else { a.set(asset.Tag.ALIAS,new util.TextEncoder().encodeInto(VISION_CREDENTIAL_ALIAS)); a.set(asset.Tag.ACCESSIBILITY,asset.Accessibility.DEVICE_UNLOCKED); a.set(asset.Tag.SYNC_TYPE,asset.SyncType.NEVER); a.set(asset.Tag.CONFLICT_RESOLUTION,asset.ConflictResolution.THROW_ERROR); await this.store.add(a); }
      if (!(await this.status()).present) { throw new VisionFailure('CredentialWriteUnconfirmed','credential'); }
    } finally { bytes.fill(0); }
  }
  async remove(): Promise<void> { this.epoch++; if ((await this.status()).present) { await this.store.remove(visionAssetQuery()); } if ((await this.status()).present) { throw new VisionFailure('CredentialRemoveUnconfirmed','credential'); } }
  async fetch(request: rcp.Request, session: rcp.Session, check: () => void, admission: (launch: () => void) => Promise<void>): Promise<rcp.Response> {
    if (request.url.toString()!==VISION_ENDPOINT) { throw new VisionFailure('CredentialDestinationRejected','credential'); }
    const epoch: number=this.epoch; if (!(await this.status()).present) { throw new VisionFailure('CredentialMissing','credential'); }
    const rows: asset.AssetMap[]=await this.store.query(visionAssetQuery(asset.ReturnType.ALL)); const secret: asset.Value | undefined=rows.length===1?rows[0].get(asset.Tag.SECRET):undefined;
    if (!(secret instanceof Uint8Array)) { throw new VisionFailure('CredentialType','credential'); }
    try {
      const token: string=util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(secret); documentValidateToken(token);
      if (epoch!==this.epoch) { throw new VisionFailure('CredentialChanged','credential'); } check();
      const headers: rcp.RequestHeaders={'authorization':`Bearer ${token}`,'content-type':'application/json','accept':'application/json'}; request.headers=headers;
      const pending: VisionFetchPending=new VisionFetchPending();
      await admission((): void=> { check(); if (epoch!==this.epoch) { throw new VisionFailure('CredentialChanged','credential'); } pending.pending=session.fetch(request); });
      if (pending.pending===undefined) { throw new VisionFailure('AdmissionDidNotLaunch','credential'); } return await pending.pending;
    } finally { secret.fill(0); request.headers=undefined; }
  }
}
