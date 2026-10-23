import { UnifiedProcessingRepositoryPort } from '../domain/UnifiedProcessingPorts';
import { ParsedAssetPort, ParsedAssetLedgerPort, ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { ParsedCancellation, ParsedFailure, ParsedImageAsset, ParsedAssetState } from '../domain/ParsedDocumentModels';
import { UnifiedImageRecord, UnifiedEffectiveAnnotation, UnifiedAnnotationAuto, UnifiedAnnotationOverlay, UnifiedProcessingJob, UnifiedJobOrigin, UnifiedJobState, UnifiedTextInput } from '../domain/UnifiedKnowledgeModels';
import { VisionTransportPort, VisionRequestIdentity, VisionResponse, VisionPolicyVersions } from '../domain/VisionModels';
import { visionCacheKey, visionTags, visionDescription, VISION_ENDPOINT } from '../pipeline/VisionPolicy';
import { unifiedProxyInputs, unifiedProxyText } from '../pipeline/UnifiedTextPolicy';
import { parsedUtf8 } from '../pipeline/ParsedDocumentCodec';

export class ImageKnowledgeService {
  private repository: UnifiedProcessingRepositoryPort; private assets: ParsedAssetPort; private ledger: ParsedAssetLedgerPort; private identity: ParsedIdentityPort; private transport: VisionTransportPort;
  private changed: (() => void) | undefined;
  constructor(repository: UnifiedProcessingRepositoryPort, assets: ParsedAssetPort, ledger: ParsedAssetLedgerPort, identity: ParsedIdentityPort, transport: VisionTransportPort) { this.repository=repository; this.assets=assets; this.ledger=ledger; this.identity=identity; this.transport=transport; }
  attachChanged(callback: () => void): void { this.changed=callback; }
  async records(document: string=''): Promise<UnifiedImageRecord[]> { return this.repository.imageRecords(document); }
  async currentOccurrence(hash: string, effective: string, preferred: string): Promise<string> { const records=(await this.records()).filter((r: UnifiedImageRecord): boolean=>r.imageHash===hash && r.effectiveId===effective); const record=records.find((r: UnifiedImageRecord): boolean=>r.occurrenceId===preferred) ?? records[0]; if (record===undefined) { throw new ParsedFailure('ImageCardNoCurrentParent','source'); } return record.occurrenceId; }
  async effective(record: UnifiedImageRecord): Promise<UnifiedEffectiveAnnotation | undefined> {
    const effective: UnifiedEffectiveAnnotation | undefined=await this.repository.annotation(record.effectiveId);
    if (effective!==undefined && effective.automatic.id.length===0) {
      const automatic: UnifiedEffectiveAnnotation | undefined=await this.repository.annotation('auto-'+await visionCacheKey(record.imageHash,this.identity));
      if (automatic!==undefined) { effective.automatic=automatic.automatic; }
    }
    return effective;
  }
  async process(job: UnifiedProcessingJob, cancel: ParsedCancellation, admit: (launch: () => void) => Promise<void>): Promise<string> {
    const record: UnifiedImageRecord | undefined=(await this.records(job.documentKey)).find((r: UnifiedImageRecord): boolean=>r.occurrenceId===job.occurrenceId && r.assetId===job.assetId && r.generation===job.version);
    if (record===undefined) { throw new ParsedFailure('ImageNoLongerCurrent','vision'); }
    const asset: ParsedImageAsset | undefined=await this.ledger.asset(record.assetId); if (asset===undefined || asset.state!==ParsedAssetState.Ready) { throw new ParsedFailure('ManagedImageMissing','vision'); }
    const key: string=await visionCacheKey(asset.payloadHash,this.identity); const autoId: string='auto-'+key;
    let stored: UnifiedEffectiveAnnotation | undefined=await this.repository.annotation(autoId);
    if (stored===undefined) {
      const request: VisionRequestIdentity=new VisionRequestIdentity(); request.asset=asset; request.imageHash=asset.payloadHash; request.settingsRevision=job.settingsRevision; request.costRevision=job.costRevision; request.credentialRevision=job.credentialRevision; request.cacheKey=key;
      const response: VisionResponse=await this.transport.describe(request,await this.assets.read(asset.id,cancel),cancel,admit);
      for (const attempt of await this.repository.attempts(job.id)) { if (attempt.outcome==='InFlight') { attempt.outcome='Received'; attempt.receipt=JSON.stringify(response); attempt.usageState=response.usage.state; await this.repository.saveAttempt(attempt); } }
      const auto: UnifiedAnnotationAuto=new UnifiedAnnotationAuto(); auto.id=autoId; auto.cacheKey=key; auto.imageHash=asset.payloadHash; auto.description=response.description; auto.tags=response.tags;
      auto.recipient=VISION_ENDPOINT; auto.model=VisionPolicyVersions.model; auto.promptVersion=VisionPolicyVersions.prompt; auto.schemaVersion=VisionPolicyVersions.schema; auto.parametersVersion=VisionPolicyVersions.parameters; auto.receipt=JSON.stringify(response);
      stored=new UnifiedEffectiveAnnotation(); stored.kind='Auto'; stored.id=autoId; stored.lineage=autoId; stored.revision=1; stored.imageHash=auto.imageHash; stored.description=auto.description; stored.tags=auto.tags; stored.textHash=await this.identity.hash(parsedUtf8(unifiedProxyText(auto.description,auto.tags))); stored.automatic=auto; stored.autoId=autoId;
      await this.repository.saveAnnotation(stored);
    }
    cancel.check(); const current: UnifiedImageRecord | undefined=(await this.records(job.documentKey)).find((r: UnifiedImageRecord): boolean=>r.occurrenceId===record.occurrenceId && r.generation===record.generation && r.assetId===record.assetId);
    if (current===undefined) { return 'LateReceiptOnly'; }
    const old: UnifiedEffectiveAnnotation | undefined=await this.effective(current);
    const overlay: UnifiedAnnotationOverlay=old?.overlay ?? new UnifiedAnnotationOverlay();
    await this.apply(current,stored.automatic,overlay,job.origin,job.batchId); return stored.automatic.receipt;
  }
  private async apply(record: UnifiedImageRecord, auto: UnifiedAnnotationAuto, overlay: UnifiedAnnotationOverlay, origin: UnifiedJobOrigin, batch: string): Promise<void> {
    const a: UnifiedEffectiveAnnotation=new UnifiedEffectiveAnnotation(); a.autoId=auto.id; a.automatic=auto; a.imageHash=record.imageHash; a.overlay=overlay;
    a.description=overlay.deleted?'':overlay.description ?? auto.description;
    a.tags=overlay.deleted?[]:(overlay.tags ?? auto.tags).filter((tag: string): boolean=>overlay.suppressedTags.indexOf(tag)<0);
    const text: string=unifiedProxyText(a.description,a.tags); a.textHash=await this.identity.hash(parsedUtf8(text));
    a.lineage=overlay.lineage.length>0?overlay.lineage:'global-'+auto.cacheKey;
    a.revision=overlay.lineage.length>0?overlay.revision:1;
    a.id='eff-'+(await this.identity.hash(parsedUtf8([a.lineage,String(a.revision),a.textHash,overlay.lineage.length>0?'UserEffective':auto.id].join('\n')))).slice(0,40);
    if (a.id===record.effectiveId) { return; }
    const doc=await this.repository.get(record.documentKey); if (doc===undefined || doc.tombstone) { return; }
    let job: UnifiedProcessingJob | undefined;
    if (text.length>0) {
      job=new UnifiedProcessingJob(); job.id='job-'+(await this.identity.hash(parsedUtf8('proxy|'+a.lineage+'|'+a.id+'|'+origin+'|'+batch))).slice(0,40); job.dedupKey=job.id;
      job.documentKey=record.documentKey; job.ownerId=a.lineage; job.version=record.generation; job.assetId=record.assetId; job.occurrenceId=record.occurrenceId; job.annotationId=a.id; job.origin=origin; job.batchId=batch; job.stage='ImageEmbedding'; job.settingsPurpose='Embedding'; job.epoch=doc.epoch;
      job.inputs=await unifiedProxyInputs(record.documentKey,a.lineage,a.id,text,this.identity); job.expected=job.inputs.length; job.inputHash=await this.identity.hash(parsedUtf8(job.inputs.map((i: UnifiedTextInput): string=>i.id+'|'+i.inputHash).join('\n'))); job.state=UnifiedJobState.AwaitingConfig;
    }
    if (await this.repository.applyAnnotation(record,a,job)) { this.changed?.(); }
  }
  async edit(occurrence: string, description: string, tags: string[], deleted: boolean=false): Promise<void> {
    const record: UnifiedImageRecord | undefined=(await this.records()).find((r: UnifiedImageRecord): boolean=>r.occurrenceId===occurrence); if (record===undefined) { throw new ParsedFailure('ImageUnavailable','edit'); }
    const old: UnifiedEffectiveAnnotation | undefined=await this.effective(record); const auto: UnifiedAnnotationAuto=old?.automatic ?? new UnifiedAnnotationAuto(); auto.imageHash=record.imageHash;
    if (description.trim().length>0) { visionDescription(description); } const clean: string[]=visionTags(tags);
    const overlay: UnifiedAnnotationOverlay=new UnifiedAnnotationOverlay(); overlay.lineage=(old?.overlay.lineage.length ?? 0)>0?(old?.overlay.lineage ?? ''):'user-'+(await this.identity.hash(parsedUtf8(record.occurrenceId))).slice(0,32); overlay.revision=(old?.overlay.revision ?? 0)+1;
    overlay.description=description.trim(); overlay.tags=clean; overlay.deleted=deleted; overlay.suppressedTags=(old?.overlay.suppressedTags ?? []).slice();
    for (const tag of old?.tags ?? auto.tags) { if (clean.indexOf(tag)<0 && overlay.suppressedTags.indexOf(tag)<0) { overlay.suppressedTags.push(tag); } }
    overlay.suppressedTags=overlay.suppressedTags.filter((tag: string): boolean=>clean.indexOf(tag)<0);
    const importJob: UnifiedProcessingJob | undefined=(await this.repository.jobs()).find((j: UnifiedProcessingJob): boolean=>j.documentKey===record.documentKey && j.origin===UnifiedJobOrigin.Import);
    await this.apply(record,auto,overlay,importJob===undefined?UnifiedJobOrigin.LocalMigration:UnifiedJobOrigin.Import,'');
  }
}
