import { relationalStore } from '@kit.ArkData';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { ParsedDocumentRepository } from './ParsedDocumentRepository';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { ParsedCancellation, ParsedFailure, ParsedDocumentRecord, ParsedTextChunk } from '../domain/ParsedDocumentModels';
import { UnifiedQueryScopePort, UnifiedQueryPersistentPort, UnifiedQueryAdmissionPort, UnifiedQueryScope, UnifiedQueryTextSource, UnifiedQueryImageSource, UnifiedQueryTarget, UnifiedQueryApproval, UnifiedSearchCard, UnifiedSearchParent } from '../domain/UnifiedQueryModels';
import { UnifiedQueryNumericPort } from '../domain/UnifiedQueryPorts';
import { UnifiedEmbeddingConfigPort } from '../domain/UnifiedEmbeddingPorts';
import { EmbeddingConfig, EmbeddingSpace } from '../domain/EmbeddingModels';
import { UnifiedProcessingJob, UnifiedImageRecord, UnifiedIndexBinding, UnifiedBindingState, UnifiedTextInput, UNIFIED_QUERY_POLICY, UNIFIED_TEXT_POLICY } from '../domain/UnifiedKnowledgeModels';
import { parsedUtf8, parsedJson } from '../pipeline/ParsedDocumentCodec';
import { embeddingConfigBinding } from '../pipeline/EmbeddingBasisPolicy';
import { unifiedStored } from '../pipeline/UnifiedProcessingCodec';
import { unifiedProxyText } from '../pipeline/UnifiedTextPolicy';

export function unifiedApprovalDecode(raw: string): UnifiedQueryApproval {
  const n=unifiedStored(raw); const a: UnifiedQueryApproval=new UnifiedQueryApproval(); a.id=n.required('id').string(); a.policy=n.required('policy').string(); a.session=n.required('session').string(); a.epoch=n.required('epoch').integer(); a.actual=n.required('actual').string(); a.inputHash=n.required('inputHash').string(); a.configBinding=n.required('configBinding').string(); a.credentialRevision=n.required('credentialRevision').integer(); a.settingsRevision=n.required('settingsRevision').integer(); a.costRevision=n.required('costRevision').integer(); a.scopeHash=n.required('scopeHash').string(); a.spaceId=n.required('spaceId').string(); a.proofBinding=n.required('proofBinding').string(); a.approved=n.required('approved').kind==='true'; a.costAccepted=n.required('costAccepted').kind==='true'; a.revoked=n.required('revoked').kind==='true'; a.consumed=n.required('consumed').kind==='true'; a.includeArchived=n.required('includeArchived').kind==='true'; return a;
}
function unifiedApprovalFrozen(a: UnifiedQueryApproval): string { return JSON.stringify([a.id,a.policy,a.session,a.epoch,a.actual,a.inputHash,a.configBinding,a.credentialRevision,a.settingsRevision,a.costRevision,a.scopeHash,a.spaceId,a.proofBinding,a.includeArchived]); }
export class UnifiedQueryRepository implements UnifiedQueryScopePort, UnifiedQueryPersistentPort, UnifiedQueryAdmissionPort {
  private host: KnowledgeStoreHost; private repository: ParsedDocumentRepository; private vectors: UnifiedQueryNumericPort; private config: UnifiedEmbeddingConfigPort; private identity: ParsedIdentityPort;
  constructor(host: KnowledgeStoreHost, repository: ParsedDocumentRepository, vectors: UnifiedQueryNumericPort, config: UnifiedEmbeddingConfigPort, identity: ParsedIdentityPort) { this.host=host; this.repository=repository; this.vectors=vectors; this.config=config; this.identity=identity; }
  capture(config: EmbeddingConfig, archived: boolean, cancel: ParsedCancellation): Promise<UnifiedQueryScope> { return this.host.enqueue<UnifiedQueryScope>(async (): Promise<UnifiedQueryScope>=>this.captureLocked(config,archived,cancel)); }
  captureLocal(config: EmbeddingConfig, archived: boolean, cancel: ParsedCancellation): Promise<UnifiedQueryScope> { return this.host.enqueue<UnifiedQueryScope>(async (): Promise<UnifiedQueryScope>=>this.captureLocked(config,archived,cancel,false)); }
  private async captureLocked(config: EmbeddingConfig, archived: boolean, cancel: ParsedCancellation, openNumeric: boolean=true): Promise<UnifiedQueryScope> {
    const scope: UnifiedQueryScope=new UnifiedQueryScope(); scope.includeArchived=archived; const docs=await this.repository.list();
    const projection: string[]=[]; let count: number=0;
    for (const d of docs) { cancel.check(); if (d.tombstone || !archived && d.archived || d.activeGeneration.length===0) { continue; } const source: UnifiedQueryTextSource=new UnifiedQueryTextSource(); source.document=d; source.chunks=await this.repository.chunks(d.id);
      for (const c of source.chunks) { if (await this.identity.hash(parsedUtf8(c.text))!==c.inputHash) { throw new ParsedFailure('QueryBodyReadbackHash','query-local'); } }
      count+=source.chunks.length; scope.texts.push(source); projection.push(JSON.stringify(d)+'|'+source.chunks.map((c: ParsedTextChunk): string=>c.id+'|'+c.inputHash+'|'+c.occurrenceId).join(';')); }
    for (const r of await this.repository.queryImageRecords(archived)) { cancel.check(); const image: UnifiedQueryImageSource=new UnifiedQueryImageSource(); image.record=r; image.annotation=await this.repository.annotation(r.effectiveId); scope.images.push(image); projection.push(JSON.stringify(r)+'|'+(image.annotation?.textHash ?? 'None')); }
    scope.localHash=await this.identity.hash(parsedUtf8(projection.join('\n')));
    if (!openNumeric) {
      if (count>30000 || scope.images.length>30000) { throw new ParsedFailure('UnifiedQueryInputBudget','query-local'); }
      for (const source of scope.texts) { const binding=await this.repository.binding('upd-body',source.document.id); if (binding?.state!==UnifiedBindingState.Synced || binding.version!==source.document.activeGeneration) { scope.unupgraded++; } }
      for (const image of scope.images) { const binding=await this.repository.binding('upd-image',image.record.lineage); if (binding?.state!==UnifiedBindingState.Synced || binding.version!==image.record.effectiveId) { scope.unupgraded++; } }
      scope.unupgraded+=await this.legacyUnupgraded(); scope.hash=scope.localHash; scope.complete=true; return scope;
    }
    const settings=await this.repository.settings('Embedding'); const jobs: UnifiedProcessingJob[]=await this.repository.jobs(); let numericReady: boolean=false;
    try { await this.vectors.open(); numericReady=true; } catch { projection.push('NumericUnavailable'); }
    const spaces: EmbeddingSpace[]=numericReady?this.vectors.registeredSpaces().filter((s: EmbeddingSpace): boolean=>s.preprocessing===UNIFIED_TEXT_POLICY && s.configFingerprint===embeddingConfigBinding(config)):[];
    // A single current config/policy uses one real dimensional space. Conflicts are not mixed.
    if (spaces.length===1) { scope.space=spaces[0]; } else if (spaces.length>1) { projection.push('UnifiedDimensionConflict'); }
    for (const source of scope.texts) {
      const binding=await this.repository.binding('upd-body',source.document.id); const job: UnifiedProcessingJob | undefined=jobs.find((j: UnifiedProcessingJob): boolean=>j.id===binding?.vectorGeneration);
      if (binding?.state!==UnifiedBindingState.Synced || binding.version!==source.document.activeGeneration || binding.epoch!==source.document.epoch || job===undefined || job.configBinding!==embeddingConfigBinding(config) || scope.space===undefined || await this.repository.meta('vector-space:'+job.id)!==scope.space.id) { scope.unupgraded++; continue; }
      if (binding.expected!==source.chunks.length || binding.expected!==job.inputs.length || job.inputHash!==binding.inputSetHash) { throw new ParsedFailure('UnifiedBodyExpectedMismatch','query-scope'); }
      if (await this.identity.hash(parsedUtf8(job.inputs.map((i: UnifiedTextInput): string=>i.id+'|'+i.inputHash).join('\n')))!==binding.inputSetHash || binding.readbackHash!==binding.inputSetHash) { throw new ParsedFailure('UnifiedBodyReadbackSet','query-scope'); }
      for (const input of job.inputs) { if (!source.chunks.some((c: ParsedTextChunk): boolean=>c.id===input.id && c.inputHash===input.inputHash && c.text===input.actualText)) { throw new ParsedFailure('UnifiedBodyInputMismatch','query-scope'); } const target=this.target(input,job,binding); target.qualification.spaceId=scope.space.id; scope.targets.push(target); }
      projection.push(JSON.stringify(binding));
    }
    const owners: Set<string>=new Set<string>();
    for (const image of scope.images) {
      const r=image.record; const annotation=image.annotation; if (annotation===undefined || owners.has(annotation.lineage)) { continue; } owners.add(annotation.lineage);
      const binding=await this.repository.binding('upd-image',annotation.lineage); const job: UnifiedProcessingJob | undefined=jobs.find((j: UnifiedProcessingJob): boolean=>j.id===binding?.vectorGeneration);
      if (binding?.state!==UnifiedBindingState.Synced || binding.version!==r.effectiveId || job===undefined || job.configBinding!==embeddingConfigBinding(config) || scope.space===undefined || await this.repository.meta('vector-space:'+job.id)!==scope.space.id) { scope.unupgraded++; continue; }
      if (binding.expected!==job.inputs.length || binding.inputSetHash!==job.inputHash) { throw new ParsedFailure('UnifiedProxyExpectedMismatch','query-scope'); }
      if (job.inputs.map((i: UnifiedTextInput): string=>i.actualText).join('')!==unifiedProxyText(annotation.description,annotation.tags) || await this.identity.hash(parsedUtf8(job.inputs.map((i: UnifiedTextInput): string=>i.id+'|'+i.inputHash).join('\n')))!==binding.inputSetHash || binding.readbackHash!==binding.inputSetHash) { throw new ParsedFailure('UnifiedProxyReadbackSet','query-scope'); }
      count+=job.inputs.length; for (const input of job.inputs) { const target=this.target(input,job,binding); target.qualification.spaceId=scope.space.id; scope.targets.push(target); } projection.push(JSON.stringify(binding));
    }
    if (count>30000 || scope.targets.length>30000) { throw new ParsedFailure('UnifiedQueryInputBudget','query-scope'); }
    const old=await this.host.requireStore().querySql("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('text_doc','kb_document','kb_image_document','kb_docx_document')"); const oldNames: string[]=[]; try { while (old.goToNextRow()) { oldNames.push(old.getString(0)); } } finally { old.close(); }
    for (const name of oldNames) { const namespace: string=name==='text_doc'?'Text':name==='kb_document'?'Pdf':name==='kb_image_document'?'Image':'Docx'; const rows=await this.host.requireStore().querySql(`SELECT count(*) FROM ${name} old WHERE `+(name==='text_doc'?'1=1':'old.tombstone=0')+" AND NOT EXISTS(SELECT 1 FROM upd_legacy_link l JOIN upd_document d ON d.id=l.doc AND d.active=l.generation WHERE l.namespace=? AND l.legacy_id=old.id AND l.state='Committed')",[namespace]); try { if (!rows.goToNextRow()) { throw new ParsedFailure('LegacyCoverageUnavailable','query-scope'); } scope.unupgraded+=rows.getLong(0); } finally { rows.close(); } }
    projection.push(JSON.stringify(settings),embeddingConfigBinding(config),scope.space?.id ?? 'NoUnifiedSpace',String(scope.unupgraded)); scope.hash=await this.identity.hash(parsedUtf8(projection.join('\n'))); scope.complete=true; return scope;
  }
  private async legacyUnupgraded(): Promise<number> {
    const tables=await this.host.requireStore().querySql("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('text_doc','kb_document','kb_image_document','kb_docx_document')"); const names: string[]=[];
    try { while (tables.goToNextRow()) { names.push(tables.getString(0)); } } finally { tables.close(); } let total: number=0;
    for (const name of names) {
      const namespace: string=name==='text_doc'?'Text':name==='kb_document'?'Pdf':name==='kb_image_document'?'Image':'Docx';
      const rows=await this.host.requireStore().querySql(`SELECT count(*) FROM ${name} old WHERE `+(name==='text_doc'?'1=1':'old.tombstone=0')+" AND NOT EXISTS(SELECT 1 FROM upd_legacy_link l JOIN upd_document d ON d.id=l.doc AND d.active=l.generation WHERE l.namespace=? AND l.legacy_id=old.id AND l.state='Committed')",[namespace]);
      try { if (!rows.goToNextRow()) { throw new ParsedFailure('LegacyCoverageUnavailable','query-local'); } total+=rows.getLong(0); } finally { rows.close(); }
    } return total;
  }
  private target(input: UnifiedTextInput, job: UnifiedProcessingJob, binding: UnifiedIndexBinding): UnifiedQueryTarget {
    const t: UnifiedQueryTarget=new UnifiedQueryTarget(); t.input=input; t.binding=binding; t.qualification.documentId=`upd:${job.stage==='ImageEmbedding'?'image':'body'}:${job.ownerId}`; t.qualification.contentGeneration=input.version; t.qualification.vectorGeneration=job.id; t.qualification.epoch=job.epoch; t.qualification.chunkIds=[input.id]; t.qualification.inputHash=input.inputHash; return t;
  }
  async visible(card: UnifiedSearchCard, archived: boolean): Promise<boolean> {
    if (card.kind==='Image') { const records=await this.repository.queryImageRecords(archived); return records.some((r: UnifiedImageRecord): boolean=>r.imageHash===card.imageHash && r.effectiveId===card.effectiveId && card.parents.some((p: UnifiedSearchParent): boolean=>p.occurrenceId===r.occurrenceId)); }
    const doc=await this.repository.get(card.documentKey); return doc!==undefined && !doc.tombstone && (archived || !doc.archived) && doc.activeGeneration===card.generation;
  }
  async saveQueryApproval(a: UnifiedQueryApproval): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void>=> { const old=await this.host.requireStore().querySql('SELECT revoked,consumed,metadata FROM upd_grant WHERE id=?',[a.id]);
      try { if (old.goToNextRow()) { const prior=unifiedApprovalDecode(old.getString(2)); if (old.getLong(0)===1 || old.getLong(1)===1 || unifiedApprovalFrozen(prior)!==unifiedApprovalFrozen(a)) { throw new ParsedFailure('QueryApprovalCannotRevive','query-review'); } } } finally { old.close(); }
      await this.repository.ensureCapacity(8192); await this.host.requireStore().executeSql('INSERT INTO upd_grant VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata',[a.id,UNIFIED_QUERY_POLICY,a.settingsRevision,0,0,JSON.stringify(a)]);
    });
  }
  async revokeQuery(session: string, epoch: number): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void>=> { const rows=await this.host.requireStore().querySql('SELECT id,metadata FROM upd_grant WHERE purpose=?',[UNIFIED_QUERY_POLICY]); const ids: string[]=[]; try { while (rows.goToNextRow()) { const a=unifiedApprovalDecode(rows.getString(1)); if (a.session===session && a.epoch<=epoch) { ids.push(rows.getString(0)); } } } finally { rows.close(); } for (const id of ids) { await this.host.requireStore().executeSql('UPDATE upd_grant SET revoked=1 WHERE id=?',[id]); } });
  }
  async consumeQuery(a: UnifiedQueryApproval, currentScope: string, launch: () => void): Promise<void> { await this.host.enqueue<void>(async (): Promise<void>=> { await this.consumeLocked(a,currentScope,launch); }); }
  private async consumeLocked(a: UnifiedQueryApproval, scope: string, launch: () => void): Promise<void> {
    const setting=await this.repository.settings('Embedding'); const config=this.config.currentConfig(); const rows=await this.host.requireStore().querySql('SELECT revoked,consumed,metadata FROM upd_grant WHERE id=? AND purpose=?',[a.id,UNIFIED_QUERY_POLICY]);
    try { if (!rows.goToNextRow()) { throw new ParsedFailure('QueryPersistentApprovalMissing','query-admission'); } const stored=unifiedApprovalDecode(rows.getString(2));
      if (rows.getLong(0)!==0 || rows.getLong(1)!==0 || a.revoked || !stored.approved || !stored.costAccepted || !a.approved || !a.costAccepted || unifiedApprovalFrozen(stored)!==unifiedApprovalFrozen(a) || stored.scopeHash!==scope || a.policy!==UNIFIED_QUERY_POLICY || setting.revision!==a.settingsRevision || setting.costRevision!==a.costRevision || !setting.enabled || !setting.costAcknowledged || setting.paused || setting.configBinding!==a.configBinding || embeddingConfigBinding(config)!==a.configBinding || config.credentialRevision!==a.credentialRevision) { throw new ParsedFailure('NoRequestUnifiedQueryChanged','query-admission'); }
    } finally { rows.close(); }
    await this.host.requireStore().executeSql('UPDATE upd_grant SET consumed=1 WHERE id=?',[a.id]); if (a.revoked) { throw new ParsedFailure('QueryRevokedDuringConsumption','query-admission'); } a.consumed=true; launch();
  }
  async admitUnified(a: UnifiedQueryApproval, input: string, cancel: ParsedCancellation, launch: () => void): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void>=> { cancel.check(); if (input!==a.actual || await this.identity.hash(parsedUtf8(input))!==a.inputHash) { throw new ParsedFailure('QueryActualInputChanged','query-admission'); }
      const current=await this.captureLocked(this.config.currentConfig(),a.includeArchived,cancel); if (!current.complete || current.space?.id!==a.spaceId || current.targets.length===0) { throw new ParsedFailure('UnifiedQueryTargetsUnavailable','query-admission'); }
      cancel.check(); await this.consumeLocked(a,current.hash,(): void=> { cancel.check(); launch(); });
    });
  }
}
