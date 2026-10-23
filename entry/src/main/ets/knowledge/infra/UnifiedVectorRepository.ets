import { UnifiedProcessingRepositoryPort } from '../domain/UnifiedProcessingPorts';
import { UnifiedNumericVectorPort } from '../domain/UnifiedEmbeddingPorts';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { ParsedCancellation, ParsedFailure } from '../domain/ParsedDocumentModels';
import { UnifiedProcessingJob, UnifiedIndexBinding, UnifiedBindingState, UNIFIED_TEXT_POLICY, UnifiedImageRecord, UnifiedTextInput } from '../domain/UnifiedKnowledgeModels';
import { EmbeddingConfig, EmbeddingSpace, KnowledgeVectorRow, EmbeddingVectorResponse } from '../domain/EmbeddingModels';
import { EmbeddingPinnedBasis } from '../domain/EmbeddingBasisModels';
import { embeddingConfigBinding } from '../pipeline/EmbeddingBasisPolicy';
import { embeddingValidateVector } from '../pipeline/EmbeddingPolicy';
import { parsedUtf8 } from '../pipeline/ParsedDocumentCodec';
import { unifiedStored } from '../pipeline/UnifiedProcessingCodec';
import { ParsedUpgradeCoverage } from '../domain/ParsedMigrationModels';
import { ParsedLifecycleMirrorPort } from '../domain/ParsedLifecyclePorts';

export class UnifiedVectorRepository implements ParsedLifecycleMirrorPort {
  private repository: UnifiedProcessingRepositoryPort; private vectors: UnifiedNumericVectorPort; private identity: ParsedIdentityPort;
  constructor(repository: UnifiedProcessingRepositoryPort, vectors: UnifiedNumericVectorPort, identity: ParsedIdentityPort) { this.repository=repository; this.vectors=vectors; this.identity=identity; }
  owner(job: UnifiedProcessingJob): string { return `upd:${job.stage==='ImageEmbedding'?'image':'body'}:${job.ownerId}`; }
  async space(config: EmbeddingConfig, dimension: number): Promise<EmbeddingSpace> {
    const s: EmbeddingSpace=new EmbeddingSpace(); s.preprocessing=UNIFIED_TEXT_POLICY; s.configFingerprint=embeddingConfigBinding(config); s.provider=config.provider; s.region=config.region; s.access=config.access; s.workspaceId=config.workspaceId; s.requestedModel=config.modelId; s.returnedModel=config.modelId; s.dimension=dimension;
    s.profileId=EmbeddingPinnedBasis.profile; s.profileRevision=EmbeddingPinnedBasis.revision; s.tokenizerSha256=EmbeddingPinnedBasis.tokenizer; s.profileParameters=EmbeddingPinnedBasis.parameters; s.rolePair='SingleStringNoInventedPrefix';
    s.fingerprint=await this.identity.hash(parsedUtf8([s.configFingerprint,UNIFIED_TEXT_POLICY,String(dimension),s.profileId,s.profileRevision].join('\n'))); s.id='kb-'+s.fingerprint.slice(0,32); await this.vectors.open(); await this.vectors.register(s); return s;
  }
  async reusable(job: UnifiedProcessingJob, inputId: string, hash: string): Promise<boolean> {
    const raw: string=await this.repository.meta(`vector-input:${job.id}:${inputId}`); if (raw.length===0) { return false; }
    const n=unifiedStored(raw); if (n.required('hash').string()!==hash || n.required('state').string()!=='Readback' || n.required('config').string()!==job.configBinding) { return false; }
    await this.vectors.open(); const row: KnowledgeVectorRow | undefined=await this.vectors.read(n.required('space').string(),inputId,job.id);
    return row!==undefined && row.inputHash===hash && row.documentId===this.owner(job) && row.values.length===n.required('dimension').integer() && await this.identity.hash(parsedUtf8(Array.from(row.values).join(',')))===n.required('vectorHash').string();
  }
  async put(job: UnifiedProcessingJob, ordinal: number, response: EmbeddingVectorResponse, config: EmbeddingConfig): Promise<void> {
    const input=job.inputs[ordinal]; if (input===undefined || response.model!==config.modelId || response.index!==0) { throw new ParsedFailure('UnifiedVectorResponseIdentity','vector'); }
    const values: Float32Array=embeddingValidateVector(Array.from(response.vector)); await this.repository.ensureCapacity(values.byteLength+65536); const space: EmbeddingSpace=await this.space(config,values.length);
    const existing: string=await this.repository.meta('vector-space:'+job.id); if (existing.length>0 && existing!==space.id) { throw new ParsedFailure('OwnerDimensionOrConfigChanged','vector'); } await this.repository.putMeta('vector-space:'+job.id,space.id);
    const row: KnowledgeVectorRow=new KnowledgeVectorRow(); row.spaceId=space.id; row.chunkId=input.id; row.documentId=this.owner(job); row.contentGeneration=input.version; row.vectorGeneration=job.id; row.inputHash=input.inputHash; row.epoch=job.epoch; row.eligible=false; row.values=values;
    await this.vectors.put(row); const read: KnowledgeVectorRow | undefined=await this.vectors.read(space.id,input.id,job.id);
    if (read===undefined || read.inputHash!==input.inputHash || read.documentId!==row.documentId || read.contentGeneration!==row.contentGeneration || read.values.length!==values.length || read.values.some((v: number,i: number): boolean=>v!==values[i])) { throw new ParsedFailure('UnifiedVectorReadback','vector'); }
    const raw: string=`{"state":"Readback","hash":${JSON.stringify(input.inputHash)},"config":${JSON.stringify(job.configBinding)},"space":${JSON.stringify(space.id)},"dimension":${values.length},"vectorHash":${JSON.stringify(await this.identity.hash(parsedUtf8(Array.from(values).join(','))))}}`;
    await this.repository.putMeta(`vector-input:${job.id}:${input.id}`,raw);
  }
  async finish(job: UnifiedProcessingJob, cancel: ParsedCancellation): Promise<void> {
    const space: string=await this.repository.meta('vector-space:'+job.id); if (space.length===0 || job.inputs.length!==job.expected) { throw new ParsedFailure('ExpectedSetIncomplete','vector'); }
    const doc=await this.repository.get(job.documentKey); if (doc===undefined || doc.tombstone || doc.archived || doc.epoch!==job.epoch || doc.activeGeneration!==job.version) { throw new ParsedFailure('VectorOwnerChanged','vector'); }
    if (job.stage==='ImageEmbedding' && !(await this.repository.imageRecords(job.documentKey)).some((r: UnifiedImageRecord): boolean=>r.occurrenceId===job.occurrenceId && r.effectiveId===job.annotationId)) { throw new ParsedFailure('AnnotationChanged','vector'); }
    for (const input of job.inputs) { cancel.check(); if (!await this.reusable(job,input.id,input.inputHash)) { throw new ParsedFailure('FullExpectedReadbackRequired','vector'); } }
    const b: UnifiedIndexBinding=new UnifiedIndexBinding(); b.ownerNamespace=job.stage==='ImageEmbedding'?'upd-image':'upd-body'; b.ownerId=job.ownerId; b.version=job.stage==='ImageEmbedding'?job.annotationId:job.version; b.epoch=job.epoch; b.expected=job.expected; b.inputSetHash=job.inputHash; b.vectorGeneration=job.id; b.readbackHash=await this.identity.hash(parsedUtf8(job.inputs.map((i: UnifiedTextInput): string=>i.id+'|'+i.inputHash).join('\n'))); b.state=UnifiedBindingState.Pending;
    await this.repository.saveBinding(b); await this.vectors.synchronizeUnified(space,this.owner(job),job.inputs[0].version,job.id,job.epoch);
    for (const input of job.inputs) { const row: KnowledgeVectorRow | undefined=await this.vectors.read(space,input.id,job.id); if (row===undefined || !row.eligible || row.epoch!==job.epoch) { throw new ParsedFailure('MirrorReadback','vector'); } }
    b.state=UnifiedBindingState.Synced; await this.repository.saveBinding(b);
  }
  async upgradeCoverage(document: string): Promise<ParsedUpgradeCoverage> {
    const coverage: ParsedUpgradeCoverage=new ParsedUpgradeCoverage(); coverage.documentKey=document;
    const record=await this.repository.get(document); if (record===undefined || record.tombstone) { coverage.body='Unavailable'; return coverage; }
    const body=await this.repository.binding('upd-body',document); coverage.body=body?.state===UnifiedBindingState.Synced && body.version===record.activeGeneration?'Synced':'NotUpgraded';
    const images=await this.repository.imageRecords(document); coverage.images=images.length;
    for (const image of images) { const binding=await this.repository.binding('upd-image',image.lineage); if (binding?.state===UnifiedBindingState.Synced && binding.version===image.effectiveId) { coverage.imageReady++; } }
    for (const job of await this.repository.jobs()) { if (job.documentKey!==document || job.version!==record.activeGeneration) { continue; } if (job.state==='Running' || job.state==='Pending' || job.state==='AwaitingConfig') { coverage.running++; } if (job.state==='Unknown' || job.state==='Failed') { coverage.failed++; } }
    return coverage;
  }
  async reconcileCurrentOwners(): Promise<void> {
    await this.repository.reconcileUnifiedOwners(); const records=await this.repository.imageRecords(); const jobs=await this.repository.jobs();
    for (const job of jobs) {
      if (job.stage==='Vision') { continue; } const space=await this.repository.meta('vector-space:'+job.id); if (space.length===0) { continue; }
      const document=await this.repository.get(job.documentKey); const binding=await this.repository.binding(job.stage==='ImageEmbedding'?'upd-image':'upd-body',job.ownerId);
      const current=document!==undefined && !document.tombstone && !document.archived && document.activeGeneration===job.version && document.epoch===job.epoch && (job.stage!=='ImageEmbedding' || records.some((r: UnifiedImageRecord): boolean=>r.lineage===job.ownerId && r.effectiveId===job.annotationId));
      await this.vectors.open();
      if (binding!==undefined && binding.vectorGeneration!==job.id) { continue; }
      if (!current || job.state!=='Complete') { if (this.vectors.revokeUnified!==undefined) { await this.vectors.revokeUnified(space,this.owner(job)); } continue; }
      // Rebind only an already fully received numeric generation; never call transport.
      await this.finish(job,new ParsedCancellation());
    }
  }
}
