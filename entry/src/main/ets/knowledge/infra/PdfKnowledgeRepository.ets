import { relationalStore } from '@kit.ArkData';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { imageVerifyExisting, imageTableNames } from './ImageStoreLayout';
import { docxVerifyExisting, docxTableNames } from './DocxStoreLayout';
import { docxReadLocator } from '../pipeline/DocxSnapshotCodec';
import { knowledgePublicationBudget } from './KnowledgePublicationBudget';
import { imageReadLocator, imageExactFields } from '../pipeline/ImageSnapshotCodec';
import { EmbeddingConfig, EmbeddingProvider, EmbeddingRegion, EmbeddingAccess, EmbeddingModelSource, EmbeddingDetection, EmbeddingGrant, EmbeddingModelInfo } from '../domain/EmbeddingModels';
import { EmbeddingSpace, EmbeddingJob, EmbeddingDetectionStatus } from '../domain/EmbeddingModels';
import { embeddingValidateConfig, embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { TextQueryInput } from '../domain/TextKnowledgeModels';
import { KnowledgeHit, KnowledgeSourceKind, KnowledgeChannel, KnowledgeHistory, KnowledgeHistoryCursor, KnowledgeHistoryPage, KnowledgeReferenceState, KnowledgeRoute, KnowledgeRouteState } from '../domain/KnowledgeSearchModels';
import { encodeRanges, decodeRanges } from '../pipeline/StructuredChunker';
import { safeTextBoundary } from '../pipeline/Chunker';
import { textKeywordScore, textLikePattern, prepareTextQuery } from '../pipeline/QueryPreparation';
import { pdfCodecUtf8, pdfDecodeLocators, pdfDecodeSourceBinding } from '../pipeline/PdfSnapshotCodec';
import { BoundedDocumentJson, PdfJsonNode } from '../pipeline/BoundedDocumentJson';
import { PdfEvidenceContext } from '../domain/PdfLocalModels';
import { PdfPageIdentityEvidence, PdfPageReferenceState, ResultPageReference } from '../domain/PdfLocalModels';
import { pdfDecodePageIdentity, pdfDecodePageContext, pdfCopyPageContext } from '../application/PdfPageReferenceService';
import { knowledgeLiteralScore, knowledgeLegacyMatch, knowledgeMatch } from '../pipeline/KnowledgeMatchPolicy';
import { KnowledgeResultPresentation, KnowledgeResultRange, KnowledgeResultMatch } from '../domain/KnowledgeSearchModels';
import { PdfMappingEvidence } from '../domain/PdfKnowledgeModels';
import { pdfEvidenceValid } from '../pipeline/PdfMappingPolicy';
import { pdfDecodeEvidence } from '../pipeline/PdfEvidenceCodec';
import { EmbeddingMetadataPort } from '../application/EmbeddingService';
import { PdfVectorRepository } from './PdfVectorRepository';
import { KnowledgePhysicalBudgetPort } from './KnowledgeDerivedBudget';
import { PdfIngestionRepository } from '../application/PdfIngestionService';
import { KnowledgeSearchRepository } from '../application/KnowledgeSearchService';
import { KnowledgeLifecycleRepository } from '../application/KnowledgeLifecycleService';
import { PdfAssetLedgerPort } from './PdfAssetAdapter';
import { KnowledgeDocumentListPort, KnowledgeSourceReadPort, PdfRepositoryPort, PdfPageIdentityRepositoryPort } from '../domain/KnowledgePorts';
import {
  KnowledgeFailure, PdfBudget, PdfKnowledgeDocument, PdfIngestionJob, PdfStage, PdfAssetWriteRecord, PdfAssetDescriptor,
   KnowledgePin, KnowledgePinState, KnowledgeReadLease, PdfSourceBinding, PdfChunk, PdfPartialApproval, KnowledgeCancellation, KnowledgeCleanupIntent, KnowledgeCleanupTarget
} from '../domain/PdfKnowledgeModels';

const PDF_EXTENSION_LAYOUT: string = 'KB-PDF-EXT-2';
class ImageResultPresentation {
  wire: string = 'KNOWLEDGE-RESULT-2'; citationId: string = ''; match: KnowledgeResultMatch = new KnowledgeResultMatch();
  sourceKind: string = 'Image'; actualFormat: string = ''; originalHash: string = ''; originalVersion: number = 0;
}
class DocxResultPresentation {
  wire: string = 'KNOWLEDGE-RESULT-3'; citationId: string = ''; match: KnowledgeResultMatch = new KnowledgeResultMatch();
  sourceKind: string = 'Docx'; actualFormat: string = 'DOCX'; originalHash: string = ''; originalVersion: number = 0;
}
class PdfRelationLayout {
  name: string;
  columns: string;
  constructor(name: string, columns: string) { this.name = name; this.columns = columns; }
}
const PDF_RELATIONS: PdfRelationLayout[] = [
  new PdfRelationLayout('kb_meta', 'key TEXT PRIMARY KEY,value TEXT NOT NULL'),
  new PdfRelationLayout('kb_migration', 'id TEXT PRIMARY KEY,state TEXT NOT NULL'),
  new PdfRelationLayout('kb_document', 'id TEXT PRIMARY KEY,source_key TEXT UNIQUE NOT NULL,title TEXT,original_id TEXT,original_asset TEXT,original_hash TEXT,original_version INTEGER,original_bytes INTEGER,original_pages INTEGER,task TEXT,data_id TEXT,result_asset TEXT,zip_hash TEXT,zip_bytes INTEGER,active_content TEXT,active_vector TEXT,active_space TEXT,archived INTEGER,tombstone INTEGER,epoch INTEGER,stage TEXT,chunks INTEGER,partial INTEGER,created INTEGER,updated INTEGER'),
  new PdfRelationLayout('kb_content_generation', 'id TEXT PRIMARY KEY,doc TEXT NOT NULL,job TEXT NOT NULL,epoch INTEGER,snapshot TEXT,snapshot_hash TEXT,report_hash TEXT,approval_hash TEXT,old_active TEXT,state TEXT,expected INTEGER,cleanup_claim TEXT'),
  new PdfRelationLayout('kb_job', 'id TEXT PRIMARY KEY,processing_key TEXT UNIQUE NOT NULL,doc TEXT,source TEXT,generation TEXT,epoch INTEGER,stage TEXT,checkpoint TEXT,snapshot TEXT,snapshot_hash TEXT,report_hash TEXT,old_active TEXT,failure TEXT,terminated INTEGER'),
  new PdfRelationLayout('kb_pin', 'id TEXT PRIMARY KEY,source TEXT NOT NULL,asset TEXT NOT NULL,hash TEXT,owner TEXT NOT NULL,doc TEXT,generation TEXT,state TEXT NOT NULL'),
  new PdfRelationLayout('kb_read_lease', 'id TEXT PRIMARY KEY,source TEXT,generation TEXT,session TEXT,epoch INTEGER'),
  new PdfRelationLayout('kb_session', 'id TEXT PRIMARY KEY,epoch INTEGER,state TEXT'),
  new PdfRelationLayout('kb_asset', 'id TEXT PRIMARY KEY,generation TEXT,hash TEXT,bytes INTEGER,state TEXT,manifest TEXT'),
  new PdfRelationLayout('kb_cleanup', 'id TEXT PRIMARY KEY,doc TEXT,generation TEXT,claim TEXT,assets TEXT,vector_space TEXT,failure TEXT'),
  new PdfRelationLayout('kb_chunk', 'id TEXT PRIMARY KEY,doc TEXT,generation TEXT,snapshot TEXT,snapshot_hash TEXT,original_hash TEXT,version INTEGER,ordinal INTEGER,kind TEXT,text TEXT,evidence TEXT,input_hash TEXT,locator TEXT,default_included INTEGER'),
  new PdfRelationLayout('kb_embedding_config', 'provider TEXT PRIMARY KEY,region TEXT,access TEXT,workspace TEXT,model TEXT,source TEXT,revision INTEGER,credential_revision INTEGER,pending INTEGER,contract TEXT'),
  new PdfRelationLayout('kb_embedding_model', 'fingerprint TEXT,id TEXT,source TEXT,observed INTEGER,capability TEXT,PRIMARY KEY(fingerprint,id)'),
  new PdfRelationLayout('kb_embedding_detection', 'fingerprint TEXT PRIMARY KEY,credential_revision INTEGER,status TEXT,probe_hash TEXT,requested_model TEXT,returned_model TEXT,dimension INTEGER,elapsed INTEGER,observed INTEGER,total_tokens INTEGER,prompt_tokens INTEGER,provider_revision TEXT,failure TEXT'),
  new PdfRelationLayout('kb_embedding_grant', 'id TEXT PRIMARY KEY,purpose TEXT,provider TEXT,fingerprint TEXT,credential_revision INTEGER,doc TEXT,generation TEXT,snapshot_hash TEXT,inputs TEXT,space TEXT,session TEXT,free TEXT,issued INTEGER,expires INTEGER,revoked INTEGER'),
  new PdfRelationLayout('kb_embedding_space', 'id TEXT PRIMARY KEY,fingerprint TEXT UNIQUE,config_fingerprint TEXT,provider TEXT,region TEXT,access TEXT,workspace TEXT,requested_model TEXT,returned_model TEXT,provider_revision TEXT,dimension INTEGER,profile TEXT,preprocessing TEXT,roles TEXT,normalization TEXT,metric TEXT,detection TEXT'),
  new PdfRelationLayout('kb_vector_generation', 'id TEXT PRIMARY KEY,doc TEXT,content_generation TEXT,space TEXT,job TEXT,epoch INTEGER,state TEXT,expected INTEGER,completed INTEGER,eligibility INTEGER,cleanup_claim TEXT'),
  new PdfRelationLayout('kb_vector_input', 'generation TEXT,chunk TEXT,input_hash TEXT,readback_hash TEXT,PRIMARY KEY(generation,chunk)'),
  new PdfRelationLayout('kb_query', 'id TEXT PRIMARY KEY,created INTEGER,input TEXT,notice TEXT,channel TEXT,routes TEXT,failed INTEGER'),
  new PdfRelationLayout('kb_question_part', 'query_id TEXT,ordinal INTEGER,text TEXT,PRIMARY KEY(query_id,ordinal)'),
  new PdfRelationLayout('kb_citation', 'query_id TEXT,ordinal INTEGER,id TEXT,doc TEXT,source TEXT,chunk TEXT,generation TEXT,snapshot TEXT,snapshot_hash TEXT,original_hash TEXT,version INTEGER,title TEXT,text TEXT,retrieval TEXT,locator TEXT,channels TEXT,keyword_score REAL,distance REAL,rrf REAL,space TEXT,epoch INTEGER,PRIMARY KEY(query_id,ordinal)')
];
const PDF_ROUND2_RELATIONS: PdfRelationLayout[] = [
  new PdfRelationLayout('kb_candidate', 'job TEXT PRIMARY KEY,generation TEXT UNIQUE NOT NULL,binding TEXT NOT NULL,attempt INTEGER NOT NULL,owner TEXT NOT NULL,checkpoint TEXT NOT NULL,created INTEGER NOT NULL'),
  new PdfRelationLayout('kb_asset_write', 'asset TEXT PRIMARY KEY,owner TEXT NOT NULL,generation TEXT NOT NULL,member TEXT NOT NULL,type TEXT NOT NULL,expected_hash TEXT NOT NULL,reserved INTEGER NOT NULL,actual INTEGER NOT NULL,phase TEXT NOT NULL,failure TEXT NOT NULL'),
  new PdfRelationLayout('kb_asset_node', 'asset TEXT NOT NULL,node TEXT NOT NULL,relationship TEXT NOT NULL,PRIMARY KEY(asset,node)'),
  new PdfRelationLayout('kb_cleanup_target', 'intent TEXT NOT NULL,kind TEXT NOT NULL,content_generation TEXT NOT NULL,space TEXT NOT NULL,vector_generation TEXT NOT NULL,owner TEXT NOT NULL,state TEXT NOT NULL,failure TEXT NOT NULL,PRIMARY KEY(intent,kind,space,vector_generation)'),
  new PdfRelationLayout('kb_input_attempt', 'generation TEXT NOT NULL,chunk TEXT NOT NULL,input_hash TEXT NOT NULL,state TEXT NOT NULL,readback_hash TEXT NOT NULL,owner TEXT NOT NULL,PRIMARY KEY(generation,chunk)'),
  new PdfRelationLayout('kb_eligibility_mirror', 'doc TEXT PRIMARY KEY,content_generation TEXT NOT NULL,vector_generation TEXT NOT NULL,space TEXT NOT NULL,epoch INTEGER NOT NULL,revision INTEGER NOT NULL,state TEXT NOT NULL'),
  new PdfRelationLayout('kb_derived_reservation', 'id TEXT PRIMARY KEY,owner TEXT NOT NULL,kind TEXT NOT NULL,reserved INTEGER NOT NULL,actual INTEGER NOT NULL,state TEXT NOT NULL')
];
const PDF_LOCAL_RELATIONS: PdfRelationLayout[] = [
  new PdfRelationLayout('kb_local_job', 'job TEXT PRIMARY KEY,profile TEXT NOT NULL,normalization TEXT NOT NULL,filter TEXT NOT NULL,chunk TEXT NOT NULL,release_failure TEXT NOT NULL'),
  new PdfRelationLayout('kb_local_approval', 'generation TEXT PRIMARY KEY,report TEXT NOT NULL,snapshot_hash TEXT NOT NULL,limitations TEXT NOT NULL,confirmed INTEGER NOT NULL'),
  new PdfRelationLayout('kb_mapping_evidence', 'id TEXT PRIMARY KEY,generation TEXT NOT NULL,node TEXT NOT NULL,wire TEXT NOT NULL')
];
const PDF_CHUNK_RELATION: PdfRelationLayout = new PdfRelationLayout('kb_local_chunk', 'id TEXT PRIMARY KEY,generation TEXT NOT NULL,nodes TEXT NOT NULL,cells TEXT NOT NULL,assets TEXT NOT NULL,strategy TEXT NOT NULL');
const PDF_RESULT_RELATIONS: PdfRelationLayout[] = [
  new PdfRelationLayout('kb_page_identity', 'id TEXT PRIMARY KEY,generation TEXT NOT NULL,node TEXT NOT NULL,wire TEXT NOT NULL'),
  new PdfRelationLayout('kb_result_presentation', 'query_id TEXT NOT NULL,ordinal INTEGER NOT NULL,wire TEXT NOT NULL,PRIMARY KEY(query_id,ordinal)')
];
const PDF_VECTOR_RELATIONS: PdfRelationLayout[] = [
  new PdfRelationLayout('r2s_source_release','id TEXT PRIMARY KEY,session TEXT NOT NULL,wire TEXT NOT NULL,failure TEXT NOT NULL'),
  new PdfRelationLayout('r2v_job','id TEXT PRIMARY KEY,vector TEXT UNIQUE NOT NULL,snapshot TEXT NOT NULL,old_vector TEXT NOT NULL,grant_id TEXT NOT NULL,config TEXT NOT NULL,session TEXT NOT NULL,window INTEGER NOT NULL,failure TEXT NOT NULL'),
  new PdfRelationLayout('r2v_space','id TEXT PRIMARY KEY,wire TEXT NOT NULL'),
  new PdfRelationLayout('r2v_citation','query_id TEXT NOT NULL,ordinal INTEGER NOT NULL,vector_generation TEXT NOT NULL,keyword_rank INTEGER NOT NULL,vector_rank INTEGER NOT NULL,PRIMARY KEY(query_id,ordinal)'),
  new PdfRelationLayout('r2v_grant_input','grant_id TEXT NOT NULL,ordinal INTEGER NOT NULL,input_hash TEXT NOT NULL,evidence TEXT NOT NULL,PRIMARY KEY(grant_id,ordinal)'),
  new PdfRelationLayout('r2v_resend','generation TEXT NOT NULL,chunk TEXT NOT NULL,grant_id TEXT NOT NULL,confirmed INTEGER NOT NULL,PRIMARY KEY(generation,chunk,grant_id)'),
  new PdfRelationLayout('r2v_usage','generation TEXT NOT NULL,chunk TEXT NOT NULL,grant_id TEXT NOT NULL,total INTEGER,prompt INTEGER,received INTEGER NOT NULL,PRIMARY KEY(generation,chunk,grant_id)'),
  new PdfRelationLayout('r2v_baseline','fingerprint TEXT PRIMARY KEY,model TEXT NOT NULL,profile TEXT NOT NULL,revision TEXT NOT NULL,tokenizer TEXT NOT NULL,weights TEXT NOT NULL,metadata TEXT NOT NULL,parameters TEXT NOT NULL,policy TEXT NOT NULL,config_revision INTEGER NOT NULL,accepted INTEGER NOT NULL,provider_revision TEXT NOT NULL,provider_consistency TEXT NOT NULL'),
  new PdfRelationLayout('r2v_release','id TEXT PRIMARY KEY,session TEXT NOT NULL,generation TEXT NOT NULL,failure TEXT NOT NULL'),
  new PdfRelationLayout('r2v_review','set_hash TEXT NOT NULL,doc TEXT NOT NULL,generation TEXT NOT NULL,snapshot_hash TEXT NOT NULL,config TEXT NOT NULL,ordinal INTEGER NOT NULL,chunk TEXT NOT NULL,input_hash TEXT NOT NULL,binding_hash TEXT NOT NULL,state TEXT NOT NULL,bound INTEGER NOT NULL,eligible INTEGER NOT NULL,attempt_state TEXT NOT NULL,PRIMARY KEY(set_hash,ordinal)'),
  new PdfRelationLayout('r2v_trial_query','trial TEXT PRIMARY KEY,scope_hash TEXT NOT NULL,grant_id TEXT NOT NULL,query_hash TEXT NOT NULL,job TEXT NOT NULL,vector_generation TEXT NOT NULL,space TEXT NOT NULL,state TEXT NOT NULL,result TEXT NOT NULL'),
  new PdfRelationLayout('r2v_trial_grant','grant_id TEXT PRIMARY KEY,trial TEXT NOT NULL,scope_hash TEXT NOT NULL,chunks TEXT NOT NULL,inputs TEXT NOT NULL'),
  new PdfRelationLayout('r2v_rpc_receipt','job TEXT NOT NULL,vector_generation TEXT NOT NULL,space TEXT NOT NULL,chunk TEXT NOT NULL,input_hash TEXT NOT NULL,readback_hash TEXT NOT NULL,bound INTEGER NOT NULL,dimension INTEGER NOT NULL,elapsed INTEGER NOT NULL,total INTEGER NOT NULL,prompt INTEGER NOT NULL,grant_id TEXT NOT NULL,PRIMARY KEY(job,chunk,grant_id)')
];

function pdfStoredStage(raw: string): PdfStage {
  const stages: PdfStage[] = [PdfStage.Received, PdfStage.Validating, PdfStage.Normalized, PdfStage.Review, PdfStage.Chunks, PdfStage.Prepared, PdfStage.Published, PdfStage.Paused, PdfStage.Failed, PdfStage.Deleted];
  for (const stage of stages) { if (stage === raw) { return stage; } }
  throw new KnowledgeFailure('UnknownStage', 'pdf-store');
}
function pdfStoredPin(raw: string): KnowledgePinState {
  const states: KnowledgePinState[] = [KnowledgePinState.Preparing, KnowledgePinState.Checkpoint, KnowledgePinState.Active, KnowledgePinState.ReleasePending, KnowledgePinState.Released];
  for (const state of states) { if (state === raw) { return state; } }
  throw new KnowledgeFailure('UnknownPin', 'pdf-store');
}
export function pdfStoreFields(fields: string[]): string {
  const wire: string = fields.map((field: string): string => encodeURIComponent(field)).join('\t');
  if (wire.length * 3 > PdfBudget.rowBytes) { throw new KnowledgeFailure('RowBudget', 'pdf-store'); } return wire;
}
export function pdfReadFields(wire: string, max: number): string[] {
  if (wire.length * 3 > PdfBudget.rowBytes) { throw new KnowledgeFailure('RowBudget', 'pdf-store'); }
  const fields: string[] = wire.split('\t');
  if (fields.length > max) { throw new KnowledgeFailure('FieldBudget', 'pdf-store'); }
  return fields.map((field: string): string => decodeURIComponent(field));
}
export class PdfKnowledgeRepository implements PdfRepositoryPort, EmbeddingMetadataPort, PdfIngestionRepository, KnowledgeSearchRepository, KnowledgeLifecycleRepository, PdfAssetLedgerPort, KnowledgeDocumentListPort, KnowledgeSourceReadPort, PdfPageIdentityRepositoryPort {
  private host: KnowledgeStoreHost;
  private store: relationalStore.RdbStore | undefined = undefined;
  private opened: boolean = false;
  private migrationFault: string = '';
  private operationFault: string = '';
  constructor(host: KnowledgeStoreHost) { this.host = host; }
  private physicalBudget: KnowledgePhysicalBudgetPort | undefined;
  attachPhysicalBudget(port: KnowledgePhysicalBudgetPort): void { this.physicalBudget = port; }
  injectMigrationFault(scope: string): void { this.host.storageScope.requireTestOwner(scope); this.migrationFault = 'BeforeCommit'; }
  injectLocalFault(scope: string, stage: string): void { this.host.storageScope.requireTestOwner(scope); if (['Register','Checkpoint','Prepare','Publish','PublishAck','History','ReleaseRead'].indexOf(stage) < 0) { throw new KnowledgeFailure('FaultStageInvalid','test'); } this.operationFault = stage; }
  private boundary(stage: string): void { if (this.operationFault === stage) { this.operationFault = ''; throw new KnowledgeFailure(`Injected${stage}`,'test'); } }
  async legacyFixture(scope: string): Promise<void> {
    this.host.storageScope.requireTestOwner(scope);
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
      for (const relation of PDF_ROUND2_RELATIONS) { await transaction.execute(`DROP TABLE ${relation.name}`); }
      for (const relation of PDF_LOCAL_RELATIONS) { await transaction.execute(`DROP TABLE ${relation.name}`); }
      for (const relation of PDF_RESULT_RELATIONS) { await transaction.execute(`DROP TABLE ${relation.name}`); } await transaction.execute('DELETE FROM kb_migration WHERE id=?',['KB-PDF-RESULT-1']);
      await transaction.execute('DROP TABLE kb_local_chunk'); await transaction.execute('DELETE FROM kb_migration WHERE id=?',['KB-PDF-CHUNK-1']);
      await transaction.execute('DELETE FROM kb_migration WHERE id=?',['KB-PDF-LOCAL-1']);
      await transaction.execute('UPDATE kb_meta SET value=? WHERE key=?',['KB-PDF-EXT-1','layout']); await transaction.execute('DELETE FROM kb_migration WHERE id=?',[PDF_EXTENSION_LAYOUT]);
    }); });
  }
  ready(): boolean { return this.opened && this.host.extensionReady; }
  async sourceRelease(lease: KnowledgeReadLease, failure: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { if (failure.length === 0) { await this.requireStore().executeSql('DELETE FROM r2s_source_release WHERE id=?',[lease.id]); } else { await this.requireStore().executeSql('INSERT OR REPLACE INTO r2s_source_release VALUES(?,?,?,?)',[lease.id,lease.sessionId,JSON.stringify(lease),failure]); } });
  }
  async retrySourceReleases(session: string): Promise<void> {
    const rows = await this.requireStore().querySql('SELECT id FROM r2s_source_release WHERE session=?',[session]); const ids: string[] = [];
    try { while (rows.goToNextRow()) { ids.push(rows.getString(0)); } } finally { rows.close(); }
    for (const id of ids) { await this.releaseRead(id); await this.requireStore().executeSql('DELETE FROM r2s_source_release WHERE id=?',[id]); }
  }
  private requireStore(): relationalStore.RdbStore {
    if (this.store === undefined || !this.ready()) { throw new KnowledgeFailure('ExtensionUnavailable', 'pdf-store'); } return this.store;
  }
  private async scalar(sql: string, args: relationalStore.ValueType[] = []): Promise<number> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql(sql, args);
    try { return rows.goToNextRow() ? rows.getLong(0) : 0; } finally { rows.close(); }
  }
  private async verifyLayout(transaction: relationalStore.Transaction, relations: PdfRelationLayout[]): Promise<void> {
    for (const relation of relations) {
      const rows: relationalStore.ResultSet = await transaction.querySql('SELECT sql FROM sqlite_master WHERE type=? AND name=?', ['table', relation.name]);
      try {
        if (!rows.goToNextRow() || rows.getString(0) !== `CREATE TABLE ${relation.name} (${relation.columns})`) {
          throw new KnowledgeFailure('ExtensionLayoutMismatch', relation.name);
        }
      } finally { rows.close(); }
    }
  }
  async open(): Promise<void> {
    if (this.opened) { return; }
    this.store = await this.host.acquireExtension();
    try {
      await this.host.enqueue<void>(async (): Promise<void> => {
        await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
          const tables: relationalStore.ResultSet = await transaction.querySql("SELECT name FROM sqlite_master WHERE type='table' AND name GLOB 'kb_*'");
          const existing: string[] = [];
           try { while (tables.goToNextRow()) { existing.push(tables.getString(0)); if (existing.length > 80) { throw new KnowledgeFailure('ExtensionResidual', 'open'); } } } finally { tables.close(); }
          const imagePresent: boolean = await imageVerifyExisting(transaction);
           if (imagePresent) { const imageNames: string[] = imageTableNames(); for (let at: number = existing.length-1; at >= 0; at--) { if (imageNames.indexOf(existing[at]) >= 0) { existing.splice(at,1); } } }
           if (await docxVerifyExisting(transaction)) { const docxNames: string[] = docxTableNames(); for (let at: number = existing.length-1; at >= 0; at--) { if (docxNames.indexOf(existing[at]) >= 0) { existing.splice(at,1); } } }
          if (existing.length === 0) {
            for (const relation of PDF_RELATIONS) { await transaction.execute(`CREATE TABLE ${relation.name} (${relation.columns})`); }
            await transaction.execute('CREATE INDEX kb_chunk_generation ON kb_chunk(doc,generation)');
            await transaction.execute('CREATE INDEX kb_pin_asset ON kb_pin(asset,state)');
            await transaction.execute('INSERT INTO kb_meta VALUES(?,?)', ['layout', 'KB-PDF-EXT-1']);
            await transaction.execute('INSERT INTO kb_migration VALUES(?,?)', ['KB-PDF-EXT-1', 'Committed']);
          } else {
            await this.verifyLayout(transaction,PDF_RELATIONS);
          }
            const meta: relationalStore.ResultSet = await transaction.querySql('SELECT value FROM kb_meta WHERE key=?', ['layout']);
            let version: string = '';
            try { if (!meta.goToNextRow()) { throw new KnowledgeFailure('ExtensionVersion', 'open'); } version = meta.getString(0); } finally { meta.close(); }
            if (version === 'KB-PDF-EXT-1') {
              if (existing.length !== 0 && existing.length !== PDF_RELATIONS.length) { throw new KnowledgeFailure('ExtensionResidual','migration'); }
              const old: relationalStore.ResultSet = await transaction.querySql('SELECT state FROM kb_migration WHERE id=?',['KB-PDF-EXT-1']);
              try { if (!old.goToNextRow() || old.getString(0) !== 'Committed') { throw new KnowledgeFailure('MigrationUncertain','migration'); } } finally { old.close(); }
              for (const relation of PDF_ROUND2_RELATIONS) { await transaction.execute(`CREATE TABLE ${relation.name} (${relation.columns})`); }
              await transaction.execute('INSERT INTO kb_candidate SELECT j.id,j.generation,?,1,?,j.checkpoint,? FROM kb_job j',['NotRecorded','PreviousProcess',Date.now()]);
              const candidates: relationalStore.ResultSet = await transaction.querySql('SELECT j.id,j.processing_key,d.* FROM kb_job j JOIN kb_document d ON d.id=j.doc WHERE EXISTS (SELECT 1 FROM kb_pin p WHERE p.owner=j.id AND p.asset=d.result_asset AND p.hash=d.zip_hash)');
              const legacyIds: string[] = []; const bindings: string[] = [];
              try {
                while (candidates.goToNextRow()) {
                  const b: PdfSourceBinding = new PdfSourceBinding(); const key: string = candidates.getString(1);
                  b.originalId = candidates.getString(5); b.originalAssetId = candidates.getString(6); b.originalHash = candidates.getString(7); b.originalVersion = candidates.getLong(8); b.originalBytes = candidates.getLong(9); b.originalPages = candidates.getLong(10);
                  b.taskId = candidates.getString(11); b.dataId = candidates.getString(12); b.resultAssetId = candidates.getString(13); b.zipHash = candidates.getString(14); b.zipBytes = candidates.getLong(15);
                  b.requestMode = 'NotRecorded'; b.backend = 'NotRecorded'; b.producerVersion = 'NotRecorded';
                  if (key.split('|').indexOf(b.zipHash) >= 0) { legacyIds.push(candidates.getString(0)); bindings.push(JSON.stringify(b)); }
                }
              } finally { candidates.close(); }
              for (let at: number = 0; at < legacyIds.length; at++) { await transaction.execute('UPDATE kb_candidate SET binding=? WHERE job=?',[bindings[at],legacyIds[at]]); }
              await transaction.execute('UPDATE kb_meta SET value=? WHERE key=?',[PDF_EXTENSION_LAYOUT,'layout']);
              await transaction.execute('INSERT INTO kb_migration VALUES(?,?)',[PDF_EXTENSION_LAYOUT,'Committed']);
              if (this.migrationFault.length > 0) { this.migrationFault = ''; throw new KnowledgeFailure('InjectedMigrationBeforeCommit','test-scope'); }
            } else if (version !== PDF_EXTENSION_LAYOUT || (existing.length !== PDF_RELATIONS.length+PDF_ROUND2_RELATIONS.length && existing.length !== PDF_RELATIONS.length+PDF_ROUND2_RELATIONS.length+PDF_LOCAL_RELATIONS.length && existing.length !== PDF_RELATIONS.length+PDF_ROUND2_RELATIONS.length+PDF_LOCAL_RELATIONS.length+1 && existing.length !== PDF_RELATIONS.length+PDF_ROUND2_RELATIONS.length+PDF_LOCAL_RELATIONS.length+1+PDF_RESULT_RELATIONS.length)) { throw new KnowledgeFailure('ExtensionVersion','open'); }
            await this.verifyLayout(transaction,PDF_ROUND2_RELATIONS);
            const migration: relationalStore.ResultSet = await transaction.querySql('SELECT state FROM kb_migration WHERE id=?', [PDF_EXTENSION_LAYOUT]);
            try { if (!migration.goToNextRow() || migration.getString(0) !== 'Committed') { throw new KnowledgeFailure('MigrationUncertain', 'open'); } } finally { migration.close(); }
            const local: relationalStore.ResultSet = await transaction.querySql('SELECT state FROM kb_migration WHERE id=?',['KB-PDF-LOCAL-1']); let localExists: boolean = false;
            try { if (local.goToNextRow()) { if (local.getString(0) !== 'Committed') { throw new KnowledgeFailure('LocalMigrationUncertain','open'); } localExists = true; } } finally { local.close(); }
            if (!localExists) {
              for (const relation of PDF_LOCAL_RELATIONS) { await transaction.execute(`CREATE TABLE ${relation.name} (${relation.columns})`); }
              await transaction.execute('INSERT INTO kb_local_job SELECT id,?,?,?,?,? FROM kb_job',['MINERU-HOSTED-PDF-3.4.4-OBSERVED-1','PDF-NORMALIZE-1','PDF-FILTER-1','PDF-CHUNK-1','']);
              await transaction.execute('INSERT INTO kb_migration VALUES(?,?)',['KB-PDF-LOCAL-1','Committed']);
            }
            await this.verifyLayout(transaction,PDF_LOCAL_RELATIONS);
            const chunkMeta: relationalStore.ResultSet = await transaction.querySql('SELECT state FROM kb_migration WHERE id=?',['KB-PDF-CHUNK-1']); let chunkExists: boolean = false;
            try { if (chunkMeta.goToNextRow()) { if (chunkMeta.getString(0) !== 'Committed') { throw new KnowledgeFailure('ChunkMigrationUncertain','open'); } chunkExists = true; } } finally { chunkMeta.close(); }
            if (!chunkExists) { await transaction.execute(`CREATE TABLE ${PDF_CHUNK_RELATION.name} (${PDF_CHUNK_RELATION.columns})`); await transaction.execute('INSERT INTO kb_migration VALUES(?,?)',['KB-PDF-CHUNK-1','Committed']); }
            await this.verifyLayout(transaction,[PDF_CHUNK_RELATION]);
            const resultMigration = await transaction.querySql('SELECT state FROM kb_migration WHERE id=?',['KB-PDF-RESULT-1']); let resultExists: boolean = false;
            try { if (resultMigration.goToNextRow()) { if (resultMigration.getString(0) !== 'Committed') { throw new KnowledgeFailure('ResultMigrationUncertain','open'); } resultExists = true; } } finally { resultMigration.close(); }
            if (!resultExists) { for (const relation of PDF_RESULT_RELATIONS) { await transaction.execute(`CREATE TABLE ${relation.name} (${relation.columns})`); } await transaction.execute('INSERT INTO kb_migration VALUES(?,?)',['KB-PDF-RESULT-1','Committed']); }
            await this.verifyLayout(transaction,PDF_RESULT_RELATIONS);
            for (const relation of PDF_VECTOR_RELATIONS) { await transaction.execute(`CREATE TABLE IF NOT EXISTS ${relation.name} (${relation.columns})`); }
            await this.verifyLayout(transaction,PDF_VECTOR_RELATIONS);
            await transaction.execute('INSERT OR IGNORE INTO kb_migration VALUES(?,?)',['KB-PDF-VECTOR-1','Committed']);
             await transaction.execute('INSERT OR IGNORE INTO kb_migration VALUES(?,?)',['KB-PDF-BASIS-1','Committed']);
             await transaction.execute('INSERT OR IGNORE INTO kb_migration VALUES(?,?)',['KB-PDF-SOURCE-1','Committed']);
            const vectorMigration = await transaction.querySql('SELECT state FROM kb_migration WHERE id=?',['KB-PDF-VECTOR-1']); try { if (!vectorMigration.goToNextRow() || vectorMigration.getString(0) !== 'Committed') { throw new KnowledgeFailure('VectorMetadataMigrationUncertain','open'); } } finally { vectorMigration.close(); }
        });
      });
      this.host.extensionReady = true; this.host.extensionFailure = ''; this.opened = true;
    } catch {
      this.host.extensionReady = false; this.host.extensionFailure = 'ExtensionMigrationRejected';
      this.store = undefined; await this.host.release(); throw new KnowledgeFailure('ExtensionMigrationRejected', 'open');
    }
  }
  async close(): Promise<void> { if (this.store !== undefined) { await this.host.release(); this.store = undefined; this.opened = false; } }
  async register(document: PdfKnowledgeDocument, job: PdfIngestionJob, pins: KnowledgePin[]): Promise<PdfIngestionJob> {
    this.requireStore();
    const binding: PdfSourceBinding = job.binding ?? document.binding;
    if (job.documentId !== document.id || job.sourceId !== binding.originalId || binding.originalHash !== document.binding.originalHash || binding.originalVersion !== document.binding.originalVersion || pins.filter((pin: KnowledgePin): boolean => pin.assetId === binding.originalAssetId && pin.assetHash === binding.originalHash).length !== 1 || pins.filter((pin: KnowledgePin): boolean => pin.assetId === binding.resultAssetId && pin.assetHash === binding.zipHash).length !== 1) { throw new KnowledgeFailure('CandidatePinBindingMismatch','register'); }
    if (pins.length !== 2 || pins.some((pin: KnowledgePin): boolean => pin.ownerId !== job.id || pin.documentId !== document.id || pin.generation !== job.generation || pin.sourceId !== job.sourceId || pin.state !== KnowledgePinState.Preparing)) {
      throw new KnowledgeFailure('PinOwnerMismatch', 'register');
    }
    let registered: PdfIngestionJob = job;
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        const duplicate: relationalStore.ResultSet = await transaction.querySql('SELECT * FROM kb_job WHERE processing_key=?', [job.processingKey]);
        try { if (duplicate.goToNextRow()) { registered = this.rowJob(duplicate); return; } } finally { duplicate.close(); }
        const existing: relationalStore.ResultSet = await transaction.querySql('SELECT id,tombstone,epoch FROM kb_document WHERE source_key=?', [document.sourceKey]);
        let found: boolean = false;
        try {
          if (existing.goToNextRow()) {
            found = true;
            if (existing.getString(0) !== document.id || existing.getLong(1) !== 0 || existing.getLong(2) !== job.epoch) { throw new KnowledgeFailure('StaleDocument', 'register'); }
          }
        } finally { existing.close(); }
        const b: PdfSourceBinding = document.binding;
        if (!found) {
          await transaction.execute('INSERT INTO kb_document VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            [document.id,document.sourceKey,document.title,b.originalId,b.originalAssetId,b.originalHash,b.originalVersion,b.originalBytes,b.originalPages,b.taskId,b.dataId,b.resultAssetId,b.zipHash,b.zipBytes,'','','',0,0,document.epoch,document.stage,0,0,document.createdAt,document.updatedAt]);
        }
        await transaction.execute('INSERT INTO kb_job VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)', [job.id,job.processingKey,job.documentId,job.sourceId,job.generation,job.epoch,job.stage,job.checkpoint,job.snapshotId,job.snapshotHash,job.reportHash,job.expectedOldGeneration,'',0]);
        await transaction.execute('INSERT INTO kb_content_generation VALUES(?,?,?,?,?,?,?,?,?,?,?,?)', [job.generation,job.documentId,job.id,job.epoch,'','','','',job.expectedOldGeneration,'Staging',0,'']);
        const candidate: PdfSourceBinding = job.binding ?? document.binding;
        await transaction.execute('INSERT INTO kb_candidate VALUES(?,?,?,?,?,?,?)',[job.id,job.generation,JSON.stringify(candidate),job.attempt,job.ownerSession,job.checkpoint,Date.now()]);
        await transaction.execute('INSERT INTO kb_local_job VALUES(?,?,?,?,?,?)',[job.id,job.profile,job.normalizeVersion,job.filterVersion,job.chunkVersion,'']);
        for (const pin of pins) { await transaction.execute('INSERT INTO kb_pin VALUES(?,?,?,?,?,?,?,?)', [pin.id,pin.sourceId,pin.assetId,pin.assetHash,pin.ownerId,pin.documentId,pin.generation,pin.state]); }
        this.boundary('Register');
      });
    }); await this.candidate(registered); return registered;
  }
  private rowJob(rows: relationalStore.ResultSet): PdfIngestionJob {
    const job: PdfIngestionJob = new PdfIngestionJob(); job.id = rows.getString(0); job.processingKey = rows.getString(1);
    job.documentId = rows.getString(2); job.sourceId = rows.getString(3); job.generation = rows.getString(4); job.epoch = rows.getLong(5);
    job.stage = pdfStoredStage(rows.getString(6)); job.checkpoint = pdfStoredStage(rows.getString(7));
    job.snapshotId = rows.getString(8); job.snapshotHash = rows.getString(9); job.reportHash = rows.getString(10);
    job.expectedOldGeneration = rows.getString(11); job.failure = rows.getString(12); job.terminated = rows.getLong(13) === 1; return job;
  }
  async jobs(): Promise<PdfIngestionJob[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM kb_job ORDER BY id'); const result: PdfIngestionJob[] = [];
    try { while (rows.goToNextRow()) { if (result.length >= 10000) { throw new KnowledgeFailure('JobBudget', 'read'); } result.push(this.rowJob(rows)); } } finally { rows.close(); }
    for (const job of result) { await this.candidate(job); } return result;
  }
  private async candidate(job: PdfIngestionJob): Promise<void> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT binding,attempt,owner FROM kb_candidate WHERE job=? AND generation=?',[job.id,job.generation]);
    try {
      if (!rows.goToNextRow()) { throw new KnowledgeFailure('CandidateMissing','read'); }
      if (rows.getString(0) !== 'NotRecorded') { job.binding = pdfDecodeSourceBinding(new BoundedDocumentJson(pdfCodecUtf8(rows.getString(0)),new KnowledgeCancellation()).read()); }
      job.attempt = rows.getLong(1); job.ownerSession = rows.getString(2);
    } finally { rows.close(); }
    const policy: relationalStore.ResultSet = await this.requireStore().querySql('SELECT profile,normalization,filter,chunk FROM kb_local_job WHERE job=?',[job.id]);
    try { if (!policy.goToNextRow()) { throw new KnowledgeFailure('JobPolicyMissing','read'); } job.profile = policy.getString(0); job.normalizeVersion = policy.getString(1); job.filterVersion = policy.getString(2); job.chunkVersion = policy.getString(3); } finally { policy.close(); }
  }
  async checkpoint(job: PdfIngestionJob): Promise<void> {
    this.requireStore();
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        const eligible: relationalStore.ResultSet = await transaction.querySql('SELECT j.id FROM kb_job j JOIN kb_document d ON d.id=j.doc JOIN kb_content_generation g ON g.id=j.generation WHERE j.id=? AND j.generation=? AND j.epoch=? AND j.terminated=0 AND d.tombstone=0 AND d.epoch=? AND g.cleanup_claim=? AND g.state IN (?,?)', [job.id,job.generation,job.epoch,job.epoch,'','Staging','Publishable']);
        try { if (!eligible.goToNextRow()) { throw new KnowledgeFailure('StaleJob', 'checkpoint'); } } finally { eligible.close(); }
        const checkpoint: relationalStore.ResultSet = await transaction.querySql('SELECT snapshot,snapshot_hash,report_hash,state FROM kb_content_generation WHERE id=?',[job.generation]);
        try { if (!checkpoint.goToNextRow() || (checkpoint.getString(0).length > 0 && (checkpoint.getString(0) !== job.snapshotId || checkpoint.getString(1) !== job.snapshotHash || checkpoint.getString(2) !== job.reportHash))) { throw new KnowledgeFailure('CheckpointReplacementForbidden','checkpoint'); } } finally { checkpoint.close(); }
        if (['MINERU-HOSTED-PDF-3.4.4-OBSERVED-1','MINERU-HOSTED-PDF-3.4.4-OCR-FALSE-1'].indexOf(job.profile) < 0 || job.normalizeVersion !== 'PDF-NORMALIZE-1' || job.filterVersion !== 'PDF-FILTER-1' || job.chunkVersion !== 'PDF-CHUNK-1') { throw new KnowledgeFailure('JobPolicyInvalid','checkpoint'); }
        await transaction.execute('UPDATE kb_local_job SET profile=? WHERE job=?',[job.profile,job.id]);
        await transaction.execute('UPDATE kb_job SET stage=?,checkpoint=?,snapshot=?,snapshot_hash=?,report_hash=?,failure=? WHERE id=?', [job.stage,job.checkpoint,job.snapshotId,job.snapshotHash,job.reportHash,job.failure,job.id]);
        await transaction.execute('UPDATE kb_content_generation SET snapshot=?,snapshot_hash=?,report_hash=? WHERE id=?', [job.snapshotId,job.snapshotHash,job.reportHash,job.generation]);
        await transaction.execute('UPDATE kb_candidate SET checkpoint=?,owner=? WHERE job=?',[job.checkpoint,job.ownerSession,job.id]);
        await transaction.execute('UPDATE kb_pin SET state=? WHERE owner=? AND state IN (?,?)', [KnowledgePinState.Checkpoint,job.id,KnowledgePinState.Preparing,KnowledgePinState.Checkpoint]);
        this.boundary('Checkpoint');
      });
    });
  }
  async pins(sourceId: string, assetIds: string[]): Promise<KnowledgePin[]> {
    if (assetIds.length > 1000) { throw new KnowledgeFailure('AssetBudget', 'pins'); }
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT p.*,j.id AS owner_id,j.terminated AS owner_terminated FROM kb_pin p LEFT JOIN kb_job j ON j.id=p.owner WHERE p.state<>?', [KnowledgePinState.Released]);
    const result: KnowledgePin[] = []; let scanned: number = 0;
    try {
      while (rows.goToNextRow()) {
        if (++scanned > 20000) { throw new KnowledgeFailure('PinBudget', 'pins'); }
        if (rows.isColumnNull(8)) { throw new KnowledgeFailure('OrphanPin', 'pins'); }
        const pin: KnowledgePin = new KnowledgePin(); pin.id = rows.getString(0); pin.sourceId = rows.getString(1); pin.assetId = rows.getString(2);
        pin.assetHash = rows.getString(3); pin.ownerId = rows.getString(4); pin.documentId = rows.getString(5); pin.generation = rows.getString(6); pin.state = pdfStoredPin(rows.getString(7));
        if (pin.sourceId === sourceId || assetIds.indexOf(pin.assetId) >= 0) { result.push(pin); }
      }
    } finally { rows.close(); } return result;
  }
  async acquireRead(lease: KnowledgeReadLease): Promise<void> {
    this.requireStore();
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        if (this.host.sessionId.length > 0) {
          const session: relationalStore.ResultSet = await transaction.querySql('SELECT id FROM kb_session WHERE id=? AND epoch=? AND state=?',[lease.sessionId,lease.sessionEpoch,'Active']);
          try { if (lease.sessionId !== this.host.sessionId || !session.goToNextRow()) { throw new KnowledgeFailure('ReadSessionUnavailable','read-lease'); } } finally { session.close(); }
        }
        const rows: relationalStore.ResultSet = await transaction.querySql('SELECT g.id FROM kb_content_generation g JOIN kb_job j ON j.id=g.job JOIN kb_document d ON d.id=g.doc WHERE g.id=? AND j.source=? AND g.cleanup_claim=? AND g.state NOT IN (?,?) AND d.tombstone=0', [lease.generation,lease.sourceId,'','CleanupClaimed','Removed']);
        try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('GenerationUnavailable', 'read-lease'); } } finally { rows.close(); }
        await transaction.execute('INSERT INTO kb_read_lease VALUES(?,?,?,?,?)', [lease.id,lease.sourceId,lease.generation,lease.sessionId,lease.sessionEpoch]);
      });
    });
  }
  async releaseRead(id: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { this.boundary('ReleaseRead'); await this.requireStore().executeSql('DELETE FROM kb_read_lease WHERE id=?', [id]); });
  }
  async assertNoReaders(assetIds: string[]): Promise<void> {
    if (await this.scalar('SELECT count(*) FROM kb_read_lease l JOIN kb_pin p ON p.generation=l.generation WHERE p.asset IN (' + assetIds.map((_id: string): string => '?').join(',') + ')', assetIds) > 0) { throw new KnowledgeFailure('ActiveReaders', 'source-delete'); }
  }
  async saveConfig(config: EmbeddingConfig): Promise<void> {
    embeddingValidateConfig(config);
    await this.host.enqueue<void>(async (): Promise<void> => { await this.requireStore().executeSql('INSERT OR REPLACE INTO kb_embedding_config VALUES(?,?,?,?,?,?,?,?,?,?)', [config.provider,config.region,config.access,config.workspaceId,config.modelId,config.modelSource,config.revision,config.credentialRevision,config.mutationPending ? 1 : 0,config.contractVersion]); });
  }
  async configs(): Promise<EmbeddingConfig[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM kb_embedding_config'); const configs: EmbeddingConfig[] = [];
    try {
      while (rows.goToNextRow()) {
        const config: EmbeddingConfig = new EmbeddingConfig();
        const provider: EmbeddingProvider | undefined = [EmbeddingProvider.SiliconFlow,EmbeddingProvider.Bailian,EmbeddingProvider.Gemini,EmbeddingProvider.OpenAI].find((item: EmbeddingProvider): boolean => item === rows.getString(0));
        const region: EmbeddingRegion | undefined = [EmbeddingRegion.Unselected,EmbeddingRegion.Beijing,EmbeddingRegion.Singapore].find((item: EmbeddingRegion): boolean => item === rows.getString(1));
        const access: EmbeddingAccess | undefined = [EmbeddingAccess.Public,EmbeddingAccess.Workspace].find((item: EmbeddingAccess): boolean => item === rows.getString(2));
        const source: EmbeddingModelSource | undefined = [EmbeddingModelSource.Manual,EmbeddingModelSource.Remote].find((item: EmbeddingModelSource): boolean => item === rows.getString(5));
        if (provider === undefined || region === undefined || access === undefined || source === undefined || configs.length >= 4) { throw new KnowledgeFailure('ConfigurationSchema','read'); }
        config.provider = provider; config.region = region; config.access = access; config.workspaceId = rows.getString(3); config.modelId = rows.getString(4);
        config.modelSource = source; config.revision = rows.getLong(6); config.credentialRevision = rows.getLong(7); config.mutationPending = rows.getLong(8) === 1; config.contractVersion = rows.getString(9);
        embeddingValidateConfig(config); configs.push(config);
      }
    } finally { rows.close(); } return configs;
  }
  async revokeGrants(fingerprint: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.requireStore().executeSql('UPDATE kb_embedding_grant SET revoked=1 WHERE fingerprint=?', [fingerprint]); });
  }
  async saveGrant(grant: EmbeddingGrant): Promise<void> {
    if (grant.inputHashes.length > PdfBudget.documentChunks || (grant.inputEvidence.length !== 0 && grant.inputEvidence.length !== grant.inputHashes.length)) { throw new KnowledgeFailure('GrantInputBudgetOrSet','grant'); }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      await tx.execute('INSERT INTO kb_embedding_grant VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', [grant.id,grant.purpose,grant.provider,grant.configFingerprint,grant.credentialRevision,grant.documentId,grant.generation,grant.snapshotHash,'InputsInR2V',grant.spaceId,grant.sessionId,grant.free,grant.issuedAt,grant.expiresAt,grant.revoked ? 1 : 0]);
      for (let at: number = 0; at < grant.inputHashes.length; at++) { const wire: string = grant.inputEvidence[at] === undefined ? '' : JSON.stringify(grant.inputEvidence[at]); if (pdfCodecUtf8(wire).length > PdfBudget.rowBytes) { throw new KnowledgeFailure('GrantEvidenceBudget','grant'); } await tx.execute('INSERT INTO r2v_grant_input VALUES(?,?,?,?)',[grant.id,at,grant.inputHashes[at],wire]); }
      if (grant.trialId.length > 0 || grant.inputChunkIds.length > 0) { await tx.execute('INSERT INTO r2v_trial_grant VALUES(?,?,?,?,?)',[grant.id,grant.trialId,grant.trialSetHash,pdfStoreFields(grant.trialId.length > 0 ? grant.scopeChunkIds : grant.inputChunkIds),pdfStoreFields(grant.trialId.length > 0 ? grant.scopeInputHashes : grant.inputHashes)]); }
    }); });
  }
  async saveModels(config: EmbeddingConfig, models: EmbeddingModelInfo[]): Promise<void> {
    if (models.length > 4096) { throw new KnowledgeFailure('ModelBudget','store'); }
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        const fingerprint: string = embeddingFingerprint(config); await transaction.execute('DELETE FROM kb_embedding_model WHERE fingerprint=?',[fingerprint]);
        for (const model of models) { if (model.configFingerprint !== fingerprint) { throw new KnowledgeFailure('ModelSourceMismatch','store'); } await transaction.execute('INSERT INTO kb_embedding_model VALUES(?,?,?,?,?)',[fingerprint,model.id,model.source,model.observedAt,model.capability]); }
      });
    });
  }
  async saveDetection(detection: EmbeddingDetection): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => {
      const config: EmbeddingConfig | undefined = (await this.configs()).find((item: EmbeddingConfig): boolean => embeddingFingerprint(item) === detection.configFingerprint && item.credentialRevision === detection.credentialRevision && !item.mutationPending);
      if (config === undefined) { throw new KnowledgeFailure('StaleDetectionConfiguration','store'); }
      await this.requireStore().executeSql('INSERT OR REPLACE INTO kb_embedding_detection VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)', [detection.configFingerprint,detection.credentialRevision,detection.status,detection.probeHash,detection.requestedModel,detection.returnedModel,detection.dimension,detection.elapsedMs,detection.observedAt,detection.usage.totalTokens ?? null,detection.usage.promptTokens ?? null,detection.providerRevision,detection.failure]);
    });
  }
  async loadDetection(config: EmbeddingConfig): Promise<EmbeddingDetection | undefined> {
    const rows = await this.requireStore().querySql('SELECT * FROM kb_embedding_detection WHERE fingerprint=? AND credential_revision=?',[embeddingFingerprint(config),config.credentialRevision]);
    try { if (!rows.goToNextRow() || rows.getString(2) !== EmbeddingDetectionStatus.Passed || config.mutationPending || rows.getString(4) !== config.modelId || rows.getString(5) !== config.modelId || rows.getLong(6) < 1 || rows.getLong(6) > 4096 || !new RegExp('^[a-f0-9]{64}$').test(rows.getString(3))) { return undefined; } const detection = new EmbeddingDetection(); detection.configFingerprint = rows.getString(0); detection.credentialRevision = rows.getLong(1); detection.status = EmbeddingDetectionStatus.Passed; detection.probeHash = rows.getString(3); detection.requestedModel = rows.getString(4); detection.returnedModel = rows.getString(5); detection.dimension = rows.getLong(6); detection.elapsedMs = rows.getLong(7); detection.observedAt = rows.getLong(8); detection.usage.totalTokens = rows.isColumnNull(9) ? undefined : rows.getLong(9); detection.usage.promptTokens = rows.isColumnNull(10) ? undefined : rows.getLong(10); detection.providerRevision = rows.getString(11); return detection; } finally { rows.close(); }
  }
  async saveSpace(space: EmbeddingSpace): Promise<void> {
    if (!new RegExp('^kb-[a-f0-9]{32}$').test(space.id) || !Number.isSafeInteger(space.dimension) || space.dimension < 1 || space.dimension > 4096 || space.providerRevision !== 'NotReported') { throw new KnowledgeFailure('SpaceIdentity','store'); }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.requireStore().executeSql('INSERT INTO kb_embedding_space VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[space.id,space.fingerprint,space.configFingerprint,space.provider,space.region,space.access,space.workspaceId,space.requestedModel,space.returnedModel,space.providerRevision,space.dimension,space.profileId,space.preprocessing,space.rolePair,space.normalization,space.metric,space.detectionFingerprint]); });
  }
  async saveVectorJob(job: EmbeddingJob): Promise<void> {
    const repository: PdfVectorRepository = new PdfVectorRepository(this.host,this); await repository.bootstrap(); await repository.begin(job,await repository.corpus(job.documentId));
  }
  async publishVectors(job: EmbeddingJob, expectedHashes: string[]): Promise<boolean> { return new PdfVectorRepository(this.host,this).publish(job,expectedHashes); }
  async reserveAsset(id: string, generation: string, bytes: number): Promise<void> {
    if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > PdfBudget.derivedBytes) { throw new KnowledgeFailure('DerivedBudget','reserve'); }
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        const owner: relationalStore.ResultSet = await transaction.querySql('SELECT g.id FROM kb_content_generation g JOIN kb_job j ON j.id=g.job JOIN kb_document d ON d.id=g.doc WHERE g.id=? AND g.cleanup_claim=? AND j.terminated=0 AND d.tombstone=0',[generation,'']);
        try { if (!owner.goToNextRow()) { throw new KnowledgeFailure('AssetOwnerUnavailable','reserve'); } } finally { owner.close(); }
        const usage = this.physicalBudget === undefined ? undefined : await this.physicalBudget.usage();
        if (usage !== undefined && bytes+usage.total() > PdfBudget.derivedBytes) { throw new KnowledgeFailure('SharedImageDerivedBudget','reserve'); }
        const rows: relationalStore.ResultSet = await transaction.querySql('SELECT (SELECT coalesce(sum(bytes),0) FROM kb_asset),(SELECT coalesce(sum(reserved),0) FROM kb_derived_reservation WHERE state=?),(SELECT coalesce(min(actual),0) FROM kb_derived_reservation WHERE state=?)',['Reserved','Reserved']);
        try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('BudgetLedgerMissing','reserve'); } const vectorPhysical: number = usage?.vectorPhysical ?? 0; const unused: number = Math.max(0,rows.getLong(1)-Math.max(0,vectorPhysical-rows.getLong(2))); const metadata: number = this.physicalBudget === undefined ? 0 : Math.max(usage?.sharedNonReclaimable ?? 0,await new PdfVectorRepository(this.host,this).metadataBytes()); const total: number = Math.max(rows.getLong(0),usage?.assetsPhysical ?? 0)+vectorPhysical+unused+metadata; if (bytes > PdfBudget.derivedBytes-total) { throw new KnowledgeFailure('DerivedBudget','reserve'); } } finally { rows.close(); }
        await transaction.execute('INSERT INTO kb_asset VALUES(?,?,?,?,?,?)',[id,generation,'',bytes,'Reserved','']);
        await transaction.execute('INSERT INTO kb_asset_write SELECT ?,g.job,g.id,?,?,?,?,?,?,? FROM kb_content_generation g WHERE g.id=?',[id,'','Unclassified','',bytes,0,'Reserved','',generation]);
      });
    });
  }
  async commitAsset(id: string, hash: string, bytes: number, manifest: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
      const rows: relationalStore.ResultSet = await transaction.querySql('SELECT a.bytes,a.state FROM kb_asset a JOIN kb_content_generation g ON g.id=a.generation JOIN kb_job j ON j.id=g.job WHERE a.id=? AND g.cleanup_claim=? AND j.terminated=0',[id,'']);
      try { if (!rows.goToNextRow() || rows.getLong(0) < bytes || rows.getString(1) !== 'Reserved') { throw new KnowledgeFailure('AssetReservationMismatch','commit'); } } finally { rows.close(); }
      await transaction.execute('UPDATE kb_asset SET hash=?,bytes=?,state=?,manifest=? WHERE id=?',[hash,bytes,'Staged',manifest,id]);
      await transaction.execute('UPDATE kb_asset_write SET phase=?,actual=? WHERE asset=?',['Committed',bytes,id]);
      });
    });
  }
  async relateAsset(id: string, node: string, relationship: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.requireStore().executeSql('INSERT OR IGNORE INTO kb_asset_node VALUES(?,?,?)',[id,node,relationship]); });
  }
  async describeAsset(id: string, member: string, type: string, hash: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.requireStore().executeSql('UPDATE kb_asset_write SET member=?,type=?,expected_hash=? WHERE asset=? AND phase=?',[member,type,hash,id,'Reserved']); });
  }
  async assetPhase(id: string, phase: string, hash: string, actual: number): Promise<void> {
    if (phase !== 'ManifestVerified' && phase !== 'Renamed') { throw new KnowledgeFailure('AssetPhaseInvalid','asset-ledger'); }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.requireStore().executeSql('UPDATE kb_asset_write SET phase=?,expected_hash=?,actual=? WHERE asset=? AND phase IN (?,?) AND reserved>=?',[phase,hash,actual,id,'Reserved','ManifestVerified',actual]); });
  }
  async assetWrites(): Promise<PdfAssetWriteRecord[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM kb_asset_write WHERE phase<>?',['Committed']); const records: PdfAssetWriteRecord[] = [];
    try { while (rows.goToNextRow()) { if (records.length >= 10000) { throw new KnowledgeFailure('AssetWriteBudget','read'); } const record: PdfAssetWriteRecord = new PdfAssetWriteRecord(); record.id = rows.getString(0); record.owner = rows.getString(1); record.generation = rows.getString(2); record.member = rows.getString(3); record.type = rows.getString(4); record.hash = rows.getString(5); record.bytes = rows.getLong(6); record.actual = rows.getLong(7); record.phase = rows.getString(8); records.push(record); } } finally { rows.close(); } return records;
  }
  async assetDescriptor(id: string): Promise<PdfAssetDescriptor> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT a.id,a.generation,a.hash,a.bytes,a.manifest,coalesce(w.member,?) FROM kb_asset a LEFT JOIN kb_asset_write w ON w.asset=a.id WHERE a.id=? AND a.state=?',['',id,'Staged']);
    try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('AssetNotCommitted','read'); } const item: PdfAssetDescriptor = new PdfAssetDescriptor(); item.id = rows.getString(0); item.generation = rows.getString(1); item.hash = rows.getString(2); item.bytes = rows.getLong(3); item.format = rows.getString(4); item.member = rows.getString(5); return item; } finally { rows.close(); }
  }
  async reusableImage(generation: string, member: string): Promise<string> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT a.id FROM kb_asset a JOIN kb_asset_write w ON w.asset=a.id WHERE a.generation=? AND w.member=? AND a.state=? AND a.manifest=?',[generation,member,'Staged','PDF-DERIVED-JPEG-2']);
    try { return rows.goToNextRow() ? rows.getString(0) : ''; } finally { rows.close(); }
  }
  async snapshotAssets(generation: string): Promise<string[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT id FROM kb_asset WHERE generation=? AND manifest=? AND state=?',[generation,'PDF-NORMALIZED-1','Staged']); const ids: string[] = [];
    try { while (rows.goToNextRow()) { if (ids.length >= 10000) { throw new KnowledgeFailure('SnapshotAssetBudget','read'); } ids.push(rows.getString(0)); } } finally { rows.close(); } return ids;
  }
  async releaseFailure(job: string, failure: string): Promise<void> { await this.host.enqueue<void>(async (): Promise<void> => { await this.requireStore().executeSql('UPDATE kb_local_job SET release_failure=? WHERE job=?',[failure,job]); }); }
  async derivedBytes(): Promise<number> { return this.scalar('SELECT coalesce(sum(bytes),0) FROM kb_asset'); }
  async assetIds(): Promise<string[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT id FROM kb_asset'); const ids: string[] = [];
    try { while (rows.goToNextRow()) { if (ids.length >= 10000) { throw new KnowledgeFailure('AssetRegistryBudget','read'); } ids.push(rows.getString(0)); } } finally { rows.close(); } return ids;
  }
  async assetHash(id: string): Promise<string> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT hash,state FROM kb_asset WHERE id=?',[id]);
    try { if (!rows.goToNextRow() || rows.getString(1) !== 'Staged' || !new RegExp('^[a-f0-9]{64}$').test(rows.getString(0))) { throw new KnowledgeFailure('AssetNotCommitted','read'); } return rows.getString(0); } finally { rows.close(); }
  }
  private rowDocument(rows: relationalStore.ResultSet): PdfKnowledgeDocument {
    const doc: PdfKnowledgeDocument = new PdfKnowledgeDocument(); doc.id = rows.getString(0); doc.sourceKey = rows.getString(1); doc.title = rows.getString(2);
    const b: PdfSourceBinding = doc.binding; b.originalId = rows.getString(3); b.originalAssetId = rows.getString(4); b.originalHash = rows.getString(5); b.originalVersion = rows.getLong(6); b.originalBytes = rows.getLong(7); b.originalPages = rows.getLong(8);
    b.taskId = rows.getString(9); b.dataId = rows.getString(10); b.resultAssetId = rows.getString(11); b.zipHash = rows.getString(12); b.zipBytes = rows.getLong(13);
    doc.activeContentGeneration = rows.getString(14); doc.activeVectorGeneration = rows.getString(15); doc.activeSpaceId = rows.getString(16); doc.archived = rows.getLong(17) === 1; doc.tombstone = rows.getLong(18) === 1;
    doc.epoch = rows.getLong(19); doc.stage = pdfStoredStage(rows.getString(20)); doc.chunkCount = rows.getLong(21); doc.partial = rows.getLong(22) === 1; doc.createdAt = rows.getLong(23); doc.updatedAt = rows.getLong(24);
    if (b.originalPages < 1 || b.originalPages > PdfBudget.pages || b.originalBytes > PdfBudget.originalBytes || b.zipBytes > PdfBudget.zipBytes || doc.chunkCount > PdfBudget.documentChunks) { throw new KnowledgeFailure('DocumentRowBudget','pdf-store'); } return doc;
  }
  async list(): Promise<PdfKnowledgeDocument[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM kb_document ORDER BY created DESC,id'); const documents: PdfKnowledgeDocument[] = [];
    try { while (rows.goToNextRow()) { if (documents.length >= 10000) { throw new KnowledgeFailure('DocumentBudget','pdf-store'); } documents.push(this.rowDocument(rows)); } } finally { rows.close(); } return documents;
  }
  async listPage(offset: number, limit: number): Promise<PdfKnowledgeDocument[]> {
    if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > 20) { throw new KnowledgeFailure('DocumentPageBudget','read'); }
    const rows = await this.requireStore().querySql('SELECT * FROM kb_document WHERE tombstone=0 ORDER BY created DESC,id LIMIT ? OFFSET ?',[limit,offset]); const documents: PdfKnowledgeDocument[] = [];
    try { while (rows.goToNextRow()) { documents.push(this.rowDocument(rows)); } } finally { rows.close(); } return documents;
  }
  async get(id: string): Promise<PdfKnowledgeDocument | undefined> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM kb_document WHERE id=?',[id]); try { return rows.goToNextRow() ? this.rowDocument(rows) : undefined; } finally { rows.close(); }
  }
  async generationJob(generation: string): Promise<PdfIngestionJob> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT j.* FROM kb_job j JOIN kb_content_generation g ON g.id=j.generation WHERE j.generation=? AND g.cleanup_claim=? AND g.state NOT IN (?,?)',[generation,'','Removed','CleanupClaimed']);
    let job: PdfIngestionJob;
    try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('GenerationUnavailable','source'); } job = this.rowJob(rows); } finally { rows.close(); }
    await this.candidate(job); return job;
  }
  async localCounts(generation: string): Promise<number[]> {
    return [await this.scalar('SELECT count(*) FROM kb_chunk WHERE generation=?',[generation]),await this.scalar('SELECT count(*) FROM kb_asset WHERE generation=?',[generation]),await this.scalar('SELECT coalesce(sum(bytes),0) FROM kb_asset WHERE generation=?',[generation]),await this.scalar('SELECT count(*) FROM kb_read_lease WHERE generation=?',[generation])];
  }
  async chunkSources(id: string, generation: string): Promise<string[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT nodes FROM kb_local_chunk WHERE id=? AND generation=?',[id,generation]);
    try { return rows.goToNextRow() && rows.getString(0).length > 0 ? pdfReadFields(rows.getString(0),PdfBudget.nodes) : []; } finally { rows.close(); }
  }
  async bindExistingChunkSources(generation: string, chunks: PdfChunk[]): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
      for (const chunk of chunks) {
        const existing: relationalStore.ResultSet = await transaction.querySql('SELECT input_hash,text,snapshot_hash FROM kb_chunk WHERE id=? AND generation=?',[chunk.id,generation]);
        try { if (!existing.goToNextRow() || existing.getString(0) !== chunk.inputHash || existing.getString(1) !== chunk.retrievalText || existing.getString(2) !== chunk.snapshotHash) { throw new KnowledgeFailure('ChunkSourceReadbackMismatch','source'); } } finally { existing.close(); }
        await transaction.execute('INSERT OR IGNORE INTO kb_local_chunk VALUES(?,?,?,?,?,?)',[chunk.id,generation,pdfStoreFields(chunk.nodeIds),pdfStoreFields(chunk.cellIds),pdfStoreFields(chunk.assetIds),chunk.strategy]);
      }
    }); });
  }
  async saveEvidence(item: PdfMappingEvidence, context: PdfEvidenceContext): Promise<void> {
    if (!pdfEvidenceValid(item,context) || pdfCodecUtf8(JSON.stringify(item)).length > PdfBudget.rowBytes) { throw new KnowledgeFailure('MappingEvidenceInvalid','store'); }
    await this.host.enqueue<void>(async (): Promise<void> => {
      const job: PdfIngestionJob = await this.generationJob(context.generation);
      if (job.snapshotId !== context.snapshotId || job.snapshotHash !== context.snapshotHash || job.binding?.originalHash !== context.originalHash || job.binding?.zipHash !== context.zipHash) { throw new KnowledgeFailure('MappingBindingMismatch','store'); }
      await this.requireStore().executeSql('INSERT OR REPLACE INTO kb_mapping_evidence VALUES(?,?,?,?)',[item.id,item.generation,item.nodeId,JSON.stringify(item)]);
    });
  }
  async evidence(generation: string, node: string): Promise<PdfMappingEvidence[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT wire FROM kb_mapping_evidence WHERE generation=? AND node=? ORDER BY id',[generation,node]); const result: PdfMappingEvidence[] = [];
    try { while (rows.goToNextRow()) { if (result.length >= 64) { throw new KnowledgeFailure('MappingEvidenceBudget','read'); } result.push(pdfDecodeEvidence(rows.getString(0))); } } finally { rows.close(); } return result;
  }
  async removeEvidence(id: string, generation: string): Promise<void> { await this.host.enqueue<void>(async (): Promise<void> => { await this.requireStore().executeSql('DELETE FROM kb_mapping_evidence WHERE id=? AND generation=?',[id,generation]); }); }
  async pageIdentities(generation: string, node: string): Promise<PdfPageIdentityEvidence[]> {
    const rows = await this.requireStore().querySql('SELECT wire FROM kb_page_identity WHERE generation=? AND node=? ORDER BY id',[generation,node]); const result: PdfPageIdentityEvidence[] = [];
    try { while (rows.goToNextRow()) { if (result.length >= 64) { throw new KnowledgeFailure('PageIdentityBudget','page'); } result.push(pdfDecodePageIdentity(rows.getString(0))); } } finally { rows.close(); } return result;
  }
  async appendPageIdentity(item: PdfPageIdentityEvidence): Promise<void> {
    const wire: string = JSON.stringify(item); if (pdfCodecUtf8(wire).length > PdfBudget.rowBytes || item.wire !== 'PAGE-IDENTITY-1' || item.fragments.length < 1) { throw new KnowledgeFailure('PageIdentityWire','page'); }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const job = await this.generationJob(item.generation); const binding = job.binding;
      if (binding === undefined || job.documentId !== item.documentId || job.snapshotId !== item.snapshotId || job.snapshotHash !== item.snapshotHash || job.profile !== item.protocol || binding.originalHash !== item.originalHash || binding.originalVersion !== item.originalVersion || binding.originalPages !== item.originalPages || binding.zipHash !== item.zipHash) { throw new KnowledgeFailure('PageIdentityBindingMismatch','page'); }
      const active = await tx.querySql('SELECT id FROM kb_document WHERE id=? AND active_content=? AND tombstone=0',[item.documentId,item.generation]); try { if (!active.goToNextRow()) { throw new KnowledgeFailure('PageIdentityNotActive','page'); } } finally { active.close(); }
      const old = await tx.querySql('SELECT wire FROM kb_page_identity WHERE id=?',[item.id]); try { if (old.goToNextRow()) { if (old.getString(0) !== wire) { throw new KnowledgeFailure('PageIdentityReplacementForbidden','page'); } return; } } finally { old.close(); }
      await tx.execute('INSERT INTO kb_page_identity VALUES(?,?,?,?)',[item.id,item.generation,item.nodeId,wire]);
    }); });
  }
  async prepare(document: PdfKnowledgeDocument, job: PdfIngestionJob, chunks: PdfChunk[], approval: PdfPartialApproval): Promise<void> {
    if (chunks.length < 1 || chunks.length > PdfBudget.documentChunks || approval.reportHash !== job.reportHash || approval.snapshotHash !== job.snapshotHash || approval.confirmedAt <= 0) { throw new KnowledgeFailure('ApprovalOrCoverage','prepare'); }
    await this.host.enqueue<void>(async (): Promise<void> => {
      const candidate: PdfIngestionJob = await this.generationJob(job.generation);
      if (candidate.id !== job.id || candidate.binding === undefined || candidate.binding.originalHash !== document.binding.originalHash) { throw new KnowledgeFailure('CandidateBindingMismatch','prepare'); }
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        const replay: relationalStore.ResultSet = await transaction.querySql('SELECT state,expected,approval_hash FROM kb_content_generation WHERE id=? AND job=? AND snapshot_hash=? AND report_hash=? AND cleanup_claim=?',[job.generation,job.id,job.snapshotHash,job.reportHash,'']);
        let replayed: boolean = false;
        try { replayed = replay.goToNextRow() && replay.getString(0) === 'Publishable' && replay.getLong(1) === chunks.length && replay.getString(2) === approval.reportHash; } finally { replay.close(); }
        if (replayed) {
          for (const chunk of chunks) {
            const item: relationalStore.ResultSet = await transaction.querySql('SELECT input_hash,text,snapshot_hash FROM kb_chunk WHERE id=? AND generation=?',[chunk.id,job.generation]);
            try { if (!item.goToNextRow() || item.getString(0) !== chunk.inputHash || item.getString(1) !== chunk.retrievalText || item.getString(2) !== chunk.snapshotHash) { throw new KnowledgeFailure('PreparedReplayMismatch','prepare'); } } finally { item.close(); }
          } return;
        }
        const rows: relationalStore.ResultSet = await transaction.querySql('SELECT g.id FROM kb_content_generation g JOIN kb_job j ON j.id=g.job JOIN kb_document d ON d.id=g.doc WHERE g.id=? AND g.state=? AND g.cleanup_claim=? AND j.id=? AND j.epoch=? AND j.terminated=0 AND d.tombstone=0 AND d.epoch=?',[job.generation,'Staging','',job.id,job.epoch,job.epoch]);
        try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('StalePreparation','prepare'); } } finally { rows.close(); }
        const count: relationalStore.ResultSet = await transaction.querySql('SELECT coalesce(sum(chunks),0) FROM kb_document WHERE tombstone=0 AND id<>?',[document.id]);
        try { if (!count.goToNextRow() || count.getLong(0)+chunks.length > PdfBudget.activeChunks) { throw new KnowledgeFailure('ActiveChunkBudget','prepare'); } } finally { count.close(); }
        await knowledgePublicationBudget(transaction,'Pdf',document.id,chunks.length);
        for (const chunk of chunks) {
          if (chunk.documentId !== document.id || chunk.generation !== job.generation || chunk.snapshotHash !== job.snapshotHash || chunk.originalHash !== document.binding.originalHash || pdfCodecUtf8(chunk.retrievalText).length > 2048 || Array.from(chunk.retrievalText).length > 512) { throw new KnowledgeFailure('ChunkIdentityOrBudget','prepare'); }
          const locators: string = JSON.stringify(chunk.locators); if (pdfCodecUtf8(locators).length > PdfBudget.rowBytes) { throw new KnowledgeFailure('LocatorRowBudget','prepare'); }
          await transaction.execute('INSERT INTO kb_chunk VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[chunk.id,chunk.documentId,chunk.generation,chunk.snapshotId,chunk.snapshotHash,chunk.originalHash,chunk.originalVersion,chunk.ordinal,chunk.kind,chunk.retrievalText,chunk.text,chunk.inputHash,locators,chunk.defaultIncluded ? 1 : 0]);
          await transaction.execute('INSERT INTO kb_local_chunk VALUES(?,?,?,?,?,?)',[chunk.id,chunk.generation,pdfStoreFields(chunk.nodeIds),pdfStoreFields(chunk.cellIds),pdfStoreFields(chunk.assetIds),chunk.strategy]);
        }
        await transaction.execute('UPDATE kb_content_generation SET state=?,expected=?,approval_hash=? WHERE id=?',['Publishable',chunks.length,approval.reportHash,job.generation]);
        await transaction.execute('UPDATE kb_job SET stage=?,checkpoint=? WHERE id=?',[PdfStage.Prepared,PdfStage.Prepared,job.id]);
        await transaction.execute('INSERT OR REPLACE INTO kb_local_approval VALUES(?,?,?,?,?)',[job.generation,approval.reportHash,approval.snapshotHash,pdfStoreFields(approval.limitations),approval.confirmedAt]);
        this.boundary('Prepare');
      });
    });
  }
  async publish(document: PdfKnowledgeDocument, job: PdfIngestionJob, approval: PdfPartialApproval, cancel?: KnowledgeCancellation): Promise<boolean> {
    let published: boolean = false;
    await this.host.enqueue<void>(async (): Promise<void> => {
      const candidate: PdfIngestionJob | undefined = (await this.jobs()).find((row: PdfIngestionJob): boolean => row.generation === job.generation && row.id === job.id);
      if (candidate === undefined || candidate.terminated) { return; }
      const binding: PdfSourceBinding | undefined = candidate.binding;
      if (binding === undefined || candidate.id !== job.id) { throw new KnowledgeFailure('CandidateBindingMismatch','publish'); }
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        cancel?.check();
        const replay: relationalStore.ResultSet = await transaction.querySql('SELECT g.id FROM kb_content_generation g JOIN kb_document d ON d.id=g.doc JOIN kb_job j ON j.id=g.job WHERE g.id=? AND g.job=? AND g.state=? AND d.active_content=g.id AND d.tombstone=0 AND j.terminated=0 AND g.snapshot_hash=? AND g.report_hash=? AND g.approval_hash=?',[job.generation,job.id,'Active',job.snapshotHash,job.reportHash,approval.reportHash]);
        try { if (replay.goToNextRow() && approval.snapshotHash === job.snapshotHash && approval.confirmedAt > 0) { published = true; return; } } finally { replay.close(); }
        const rows: relationalStore.ResultSet = await transaction.querySql('SELECT g.expected FROM kb_content_generation g JOIN kb_job j ON j.id=g.job JOIN kb_document d ON d.id=g.doc WHERE g.id=? AND g.state=? AND g.cleanup_claim=? AND g.snapshot_hash=? AND g.report_hash=? AND g.approval_hash=? AND j.id=? AND j.epoch=? AND j.terminated=0 AND j.stage=? AND d.tombstone=0 AND d.epoch=? AND d.active_content=? AND d.original_hash=?',[job.generation,'Publishable','',job.snapshotHash,job.reportHash,approval.reportHash,job.id,job.epoch,PdfStage.Prepared,job.epoch,job.expectedOldGeneration,document.binding.originalHash]);
        let chunks: number = 0; try { if (!rows.goToNextRow()) { return; } chunks = rows.getLong(0); } finally { rows.close(); }
        if (approval.snapshotHash !== job.snapshotHash || approval.confirmedAt <= 0 || chunks < 1) { return; }
        await knowledgePublicationBudget(transaction,'Pdf',document.id,chunks);
        await transaction.execute('UPDATE kb_content_generation SET state=? WHERE id=?',['Active',job.generation]);
        await transaction.execute('UPDATE kb_vector_generation SET state=?,eligibility=0 WHERE doc=? AND id IN (SELECT active_vector FROM kb_document WHERE id=?)',['Retained',document.id,document.id]);
        await transaction.execute('UPDATE kb_document SET active_content=?,chunks=?,partial=1,stage=?,active_vector=?,active_space=?,updated=? WHERE id=?',[job.generation,chunks,PdfStage.Published,'','',Date.now(),document.id]);
        await transaction.execute('UPDATE kb_document SET task=?,data_id=?,result_asset=?,zip_hash=?,zip_bytes=? WHERE id=?',[binding.taskId,binding.dataId,binding.resultAssetId,binding.zipHash,binding.zipBytes,document.id]);
        await transaction.execute('UPDATE kb_pin SET state=? WHERE owner=?',[KnowledgePinState.Active,job.id]);
        await transaction.execute('UPDATE kb_job SET stage=?,checkpoint=? WHERE id=?',[PdfStage.Published,PdfStage.Published,job.id]);
        if (job.expectedOldGeneration.length > 0 && job.expectedOldGeneration !== job.generation) { await transaction.execute('UPDATE kb_content_generation SET state=? WHERE id=?',['Retained',job.expectedOldGeneration]); }
        cancel?.check(); published = true;
        this.boundary('Publish');
      });
    }); this.boundary('PublishAck'); return published;
  }
  async candidates(input: TextQueryInput, archived: boolean, referenceAside: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeHit[]> {
    return this.keywordCandidates(input,archived,referenceAside,cancel,false);
  }
  async directCandidates(input: TextQueryInput, archived: boolean, referenceAside: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeHit[]> {
    return this.keywordCandidates(input,archived,referenceAside,cancel,true);
  }
  private async keywordCandidates(input: TextQueryInput, archived: boolean, referenceAside: boolean, cancel: KnowledgeCancellation, direct: boolean): Promise<KnowledgeHit[]> {
    cancel.check(); if (input.terms.length === 0) { return []; }
    const args: relationalStore.ValueType[] = [archived ? 1 : 0,referenceAside ? 1 : 0]; const conditions: string[] = [];
    if (direct) { conditions.push('1=1'); } else { for (const term of input.terms) { conditions.push("c.text LIKE ? ESCAPE '\\'"); args.push(textLikePattern(term)); } }
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT c.*,d.title,d.epoch FROM kb_chunk c JOIN kb_document d ON d.id=c.doc AND d.active_content=c.generation JOIN kb_content_generation g ON g.id=c.generation AND g.state=\'Active\' WHERE d.tombstone=0 AND (?=1 OR d.archived=0) AND (?=1 OR c.default_included=1) AND ('+conditions.join(' OR ')+') ORDER BY c.id',args);
    const hits: KnowledgeHit[] = []; let scanned: number = 0;
    try {
      while (rows.goToNextRow()) {
        cancel.check(); if (++scanned > PdfBudget.activeChunks) { throw new KnowledgeFailure('QueryChunkBudget','keyword'); }
        const hit: KnowledgeHit = new KnowledgeHit(); hit.chunkId = rows.getString(0); hit.id = 'pdf:'+hit.chunkId; hit.documentId = rows.getString(1); hit.generation = rows.getString(2); hit.snapshotId = rows.getString(3); hit.snapshotHash = rows.getString(4);
        hit.originalHash = rows.getString(5); hit.originalVersion = rows.getLong(6); hit.retrievalText = rows.getString(9); hit.text = rows.getString(10); hit.title = rows.getString(14); hit.epoch = rows.getLong(15);
        hit.sourceKind = KnowledgeSourceKind.Pdf; hit.locator.kind = KnowledgeSourceKind.Pdf; hit.channels = [KnowledgeChannel.Keyword];
        hit.locator.pdfRegions = pdfDecodeLocators(new BoundedDocumentJson(pdfCodecUtf8(rows.getString(12)),cancel).read());
        hit.keywordScore = direct ? knowledgeLiteralScore(hit.text,input) : textKeywordScore(hit.retrievalText,input.terms); if (hit.keywordScore > 0) { hits.push(hit); }
        hits.sort((a: KnowledgeHit,b: KnowledgeHit): number => b.keywordScore-a.keywordScore || a.id.localeCompare(b.id)); if (hits.length > 20) { hits.pop(); }
        if (direct && scanned%100 === 0) { await new Promise<void>((resolve: () => void): void => { setTimeout(resolve,0); }); }
      }
    } finally { rows.close(); } return hits;
  }
  async visible(hit: KnowledgeHit, archived: boolean): Promise<boolean> {
    const doc: PdfKnowledgeDocument | undefined = await this.get(hit.documentId);
    return doc !== undefined && !doc.tombstone && (archived || !doc.archived) && doc.epoch === hit.epoch && doc.activeContentGeneration === hit.generation && doc.binding.originalHash === hit.originalHash && (hit.spaceId.length === 0 || (doc.activeSpaceId === hit.spaceId && doc.activeVectorGeneration === hit.vectorGeneration));
  }
  async saveHistory(history: KnowledgeHistory): Promise<void> {
    this.boundary('History');
    if (history.result.hits.length > 5 || pdfCodecUtf8(history.result.input.actualInput).length > 1000) { throw new KnowledgeFailure('HistoryBudget','save'); }
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        const old: relationalStore.ResultSet = await transaction.querySql('SELECT created,input FROM kb_query WHERE id=?',[history.id]);
        let replay: boolean = false;
        try { if (old.goToNextRow()) { if (old.getLong(0) !== history.createdAt || old.getString(1) !== history.result.input.actualInput) { throw new KnowledgeFailure('HistoryIdentityMismatch','save'); } replay = true; } } finally { old.close(); }
        if (replay) { return; }
        const routes: string = pdfStoreFields(history.result.routes.map((route: KnowledgeRoute): string => pdfStoreFields([route.channel,route.state,route.reason,route.actualEgress ? '1' : '0'])));
        await transaction.execute('INSERT INTO kb_query VALUES(?,?,?,?,?,?,?)',[history.id,history.createdAt,history.result.input.actualInput,history.result.input.notice,history.result.channel,routes,history.result.failed ? 1 : 0]);
        const full: string = history.result.input.fullQuestion; let ordinal: number = 0;
        for (let start: number = 0; start < full.length;) { const end: number = safeTextBoundary(full,Math.min(full.length,start+16384)); await transaction.execute('INSERT INTO kb_question_part VALUES(?,?,?)',[history.id,ordinal++,full.slice(start,end)]); start = end; }
        for (let index: number = 0; index < history.result.hits.length; index++) {
          const hit: KnowledgeHit = history.result.hits[index];
          if ([KnowledgeSourceKind.Text,KnowledgeSourceKind.Pdf,KnowledgeSourceKind.Image,KnowledgeSourceKind.Docx].indexOf(hit.sourceKind) < 0 || hit.sourceKind === KnowledgeSourceKind.Image && hit.locator.image === undefined || hit.sourceKind === KnowledgeSourceKind.Docx && hit.locator.docx === undefined) { throw new KnowledgeFailure('UnknownCitationSource','history'); }
          const locator: string = hit.sourceKind === KnowledgeSourceKind.Docx ? JSON.stringify(hit.locator.docx) : hit.sourceKind === KnowledgeSourceKind.Text ? encodeRanges(hit.locator.textRanges) : hit.sourceKind === KnowledgeSourceKind.Image ? JSON.stringify(hit.locator.image) : JSON.stringify(hit.locator.pdfRegions);
          if (pdfCodecUtf8(locator).length > PdfBudget.rowBytes || pdfCodecUtf8(hit.text).length > 2048 || pdfCodecUtf8(hit.retrievalText).length > 2048 || pdfCodecUtf8(hit.title).length > 4096) { throw new KnowledgeFailure('CitationBudget','save'); }
          await transaction.execute('INSERT INTO kb_citation VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[history.id,index,hit.id,hit.documentId,hit.sourceKind,hit.chunkId,hit.generation,hit.snapshotId,hit.snapshotHash,hit.originalHash,hit.originalVersion,hit.title,hit.text,hit.retrievalText,locator,pdfStoreFields(hit.channels),hit.keywordScore,hit.vectorDistance ?? null,hit.rrfScore,hit.spaceId,hit.epoch]);
          await transaction.execute('INSERT INTO r2v_citation VALUES(?,?,?,?,?)',[history.id,index,hit.vectorGeneration,hit.keywordRank,hit.vectorRank]);
          const presentation = new KnowledgeResultPresentation(); presentation.citationId = hit.id; presentation.match = hit.match.actualInput.length === 0 ? knowledgeLegacyMatch(hit,history.result.input.actualInput) : hit.match; presentation.pages = hit.pages;
          const imagePresentation: ImageResultPresentation = new ImageResultPresentation(); imagePresentation.citationId = hit.id; imagePresentation.match = presentation.match; imagePresentation.actualFormat = hit.actualFormat; imagePresentation.originalHash = hit.originalHash; imagePresentation.originalVersion = hit.originalVersion;
          const docxPresentation: DocxResultPresentation = new DocxResultPresentation(); docxPresentation.citationId = hit.id; docxPresentation.match = presentation.match; docxPresentation.originalHash = hit.originalHash; docxPresentation.originalVersion = hit.originalVersion;
          const wire: string = hit.sourceKind === KnowledgeSourceKind.Docx ? JSON.stringify(docxPresentation) : hit.sourceKind === KnowledgeSourceKind.Image ? JSON.stringify(imagePresentation) : JSON.stringify(presentation); if (pdfCodecUtf8(wire).length > PdfBudget.rowBytes) { throw new KnowledgeFailure('PresentationBudget','history'); } await transaction.execute('INSERT INTO kb_result_presentation VALUES(?,?,?)',[history.id,index,wire]);
        }
      });
    });
  }
  async history(cursor: KnowledgeHistoryCursor, limit: number): Promise<KnowledgeHistoryPage> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 20) { throw new KnowledgeFailure('HistoryPageBudget','read'); }
    const page: KnowledgeHistoryPage = new KnowledgeHistoryPage();
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM kb_query WHERE created<? OR (created=? AND id<?) ORDER BY created DESC,id DESC LIMIT ?',[cursor.kbCreated,cursor.kbCreated,cursor.kbId,limit]);
    try {
      while (rows.goToNextRow()) {
        const history: KnowledgeHistory = new KnowledgeHistory(); history.id = rows.getString(0); history.createdAt = rows.getLong(1); history.result.input.actualInput = rows.getString(2); history.result.input.notice = rows.getString(3);
        history.result.channel = rows.getString(4) === KnowledgeChannel.Hybrid ? KnowledgeChannel.Hybrid : rows.getString(4) === KnowledgeChannel.Vector ? KnowledgeChannel.Vector : KnowledgeChannel.Keyword;
        history.result.failed = rows.getLong(6) === 1;
        for (const raw of rows.getString(5).length === 0 ? [] : pdfReadFields(rows.getString(5),2)) {
          const fields: string[] = pdfReadFields(raw,4); if (fields.length !== 4) { throw new KnowledgeFailure('HistoryRouteSchema','read'); }
          const route: KnowledgeRoute = new KnowledgeRoute(); route.channel = fields[0] === KnowledgeChannel.Vector ? KnowledgeChannel.Vector : KnowledgeChannel.Keyword;
          route.state = fields[1] === KnowledgeRouteState.Available ? KnowledgeRouteState.Available : fields[1] === KnowledgeRouteState.Failed ? KnowledgeRouteState.Failed : KnowledgeRouteState.Skipped; route.reason = fields[2]; route.actualEgress = fields[3] === '1'; history.result.routes.push(route);
        } page.records.push(history);
      }
    } finally { rows.close(); }
    for (const history of page.records) {
      const parts: relationalStore.ResultSet = await this.requireStore().querySql('SELECT ordinal,text FROM kb_question_part WHERE query_id=? ORDER BY ordinal',[history.id]); const question: string[] = [];
      try { while (parts.goToNextRow()) { if (parts.getLong(0) !== question.length || parts.getString(1).length > 16384) { throw new KnowledgeFailure('QuestionPartsInvalid','read'); } question.push(parts.getString(1)); } } finally { parts.close(); } history.result.input.fullQuestion = question.join('');
      const cites: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM kb_citation WHERE query_id=? ORDER BY ordinal',[history.id]);
      try {
        while (cites.goToNextRow()) {
          if (history.result.hits.length >= 5) { throw new KnowledgeFailure('CitationCount','read'); }
          const hit: KnowledgeHit = new KnowledgeHit(); hit.id = cites.getString(2); hit.documentId = cites.getString(3);
          const sourceKind: string = cites.getString(4); const knownSource = [KnowledgeSourceKind.Text,KnowledgeSourceKind.Pdf,KnowledgeSourceKind.Image,KnowledgeSourceKind.Docx].find((kind: KnowledgeSourceKind): boolean => kind === sourceKind);
          if (knownSource === undefined) { throw new KnowledgeFailure('UnknownHistorySource','history'); } hit.sourceKind = knownSource;
          hit.chunkId = cites.getString(5); hit.generation = cites.getString(6); hit.snapshotId = cites.getString(7); hit.snapshotHash = cites.getString(8); hit.originalHash = cites.getString(9); hit.originalVersion = cites.getLong(10);
          hit.title = cites.getString(11); hit.text = cites.getString(12); hit.retrievalText = cites.getString(13); hit.locator.kind = hit.sourceKind;
          if (hit.sourceKind === KnowledgeSourceKind.Text) { hit.locator.textRanges = decodeRanges(cites.getString(14)); }
          else if (hit.sourceKind === KnowledgeSourceKind.Pdf) { hit.locator.pdfRegions = pdfDecodeLocators(new BoundedDocumentJson(pdfCodecUtf8(cites.getString(14)),new KnowledgeCancellation()).read()); }
          else if (hit.sourceKind === KnowledgeSourceKind.Docx) { hit.locator.docx = docxReadLocator(new BoundedDocumentJson(pdfCodecUtf8(cites.getString(14)),new KnowledgeCancellation()).read()); if (hit.locator.docx.originalHash !== hit.originalHash || hit.locator.docx.originalVersion !== hit.originalVersion || hit.locator.docx.end-hit.locator.docx.start !== hit.text.length) { throw new KnowledgeFailure('DocxCitationBinding','history'); } }
          else { hit.locator.image = imageReadLocator(new BoundedDocumentJson(pdfCodecUtf8(cites.getString(14)),new KnowledgeCancellation()).read()); if (hit.locator.image.originalHash !== hit.originalHash || hit.locator.image.originalVersion !== hit.originalVersion || hit.locator.image.end-hit.locator.image.start !== hit.text.length) { throw new KnowledgeFailure('ImageCitationSourceMismatch','history'); } }
          hit.channels = pdfReadFields(cites.getString(15),2).map((channel: string): KnowledgeChannel => channel === KnowledgeChannel.Vector ? KnowledgeChannel.Vector : KnowledgeChannel.Keyword);
          hit.keywordScore = cites.getDouble(16); hit.vectorDistance = cites.isColumnNull(17) ? undefined : cites.getDouble(17); hit.rrfScore = cites.getDouble(18); hit.spaceId = cites.getString(19); hit.epoch = cites.getLong(20); history.result.hits.push(hit);
        }
      } finally { cites.close(); }
      for (let at: number = 0; at < history.result.hits.length; at++) { const extra = await this.requireStore().querySql('SELECT vector_generation,keyword_rank,vector_rank FROM r2v_citation WHERE query_id=? AND ordinal=?',[history.id,at]); try { if (extra.goToNextRow()) { const hit = history.result.hits[at]; hit.vectorGeneration = extra.getString(0); hit.keywordRank = extra.getLong(1); hit.vectorRank = extra.getLong(2); } } finally { extra.close(); } }
      for (let at: number = 0; at < history.result.hits.length; at++) {
        const hit = history.result.hits[at]; const saved = await this.requireStore().querySql('SELECT wire FROM kb_result_presentation WHERE query_id=? AND ordinal=?',[history.id,at]);
        try { if (saved.goToNextRow()) { this.restorePresentation(hit,history.result.input,saved.getString(0)); } else { if (hit.sourceKind === KnowledgeSourceKind.Image || hit.sourceKind === KnowledgeSourceKind.Docx) { throw new KnowledgeFailure('SourcePresentationMissing','history'); } hit.match = knowledgeLegacyMatch(hit,history.result.input.actualInput); } } finally { saved.close(); }
      }
      for (const hit of history.result.hits) {
        if (hit.sourceKind === KnowledgeSourceKind.Pdf) { const doc: PdfKnowledgeDocument | undefined = await this.get(hit.documentId); hit.referenceState = doc === undefined || doc.tombstone ? KnowledgeReferenceState.Invalid : doc.activeContentGeneration !== hit.generation || doc.binding.originalHash !== hit.originalHash ? KnowledgeReferenceState.Old : KnowledgeReferenceState.Current; }
        else if (hit.sourceKind === KnowledgeSourceKind.Image) {
          const image = await this.requireStore().querySql('SELECT d.active_generation,o.hash,o.version,d.tombstone FROM kb_image_document d JOIN kb_image_original o ON o.asset=d.active_original WHERE d.id=?',[hit.documentId]);
          try { hit.referenceState = !image.goToNextRow() || image.getLong(3) !== 0 ? KnowledgeReferenceState.Invalid : image.getString(0) !== hit.generation || image.getString(1) !== hit.originalHash || image.getLong(2) !== hit.originalVersion ? KnowledgeReferenceState.Old : KnowledgeReferenceState.Current; } finally { image.close(); }
        } else if (hit.sourceKind === KnowledgeSourceKind.Docx) {
          const docx = await this.requireStore().querySql('SELECT d.active_generation,o.hash,o.version,d.tombstone FROM kb_docx_document d JOIN kb_docx_original o ON o.asset=d.active_original WHERE d.id=?',[hit.documentId]);
          try { hit.referenceState = !docx.goToNextRow() || docx.getLong(3) !== 0 ? KnowledgeReferenceState.Invalid : docx.getString(0) !== hit.generation || docx.getString(1) !== hit.originalHash || docx.getLong(2) !== hit.originalVersion ? KnowledgeReferenceState.Old : KnowledgeReferenceState.Current; } finally { docx.close(); }
        } else {
          const text: relationalStore.ResultSet = await this.requireStore().querySql('SELECT active,hash FROM text_doc WHERE id=?',[hit.documentId]);
          try { hit.referenceState = !text.goToNextRow() ? KnowledgeReferenceState.Invalid : text.getString(0) !== hit.generation || text.getString(1) !== hit.originalHash ? KnowledgeReferenceState.Old : KnowledgeReferenceState.Current; } finally { text.close(); }
        }
      }
    } return page;
  }
  private restorePresentation(hit: KnowledgeHit, input: TextQueryInput, wire: string): void {
    const raw = new BoundedDocumentJson(pdfCodecUtf8(wire),new KnowledgeCancellation()).read();
    const wireVersion: string = raw.required('wire').string();
    if (wireVersion !== (hit.sourceKind === KnowledgeSourceKind.Docx ? 'KNOWLEDGE-RESULT-3' : hit.sourceKind === KnowledgeSourceKind.Image ? 'KNOWLEDGE-RESULT-2' : 'KNOWLEDGE-RESULT-1') || raw.required('citationId').string() !== hit.id) { throw new KnowledgeFailure('PresentationIdentity','history'); }
    if (hit.sourceKind === KnowledgeSourceKind.Docx) {
      imageExactFields(raw,['wire','citationId','match','sourceKind','actualFormat','originalHash','originalVersion']);
      if (raw.required('sourceKind').string() !== 'Docx' || raw.required('actualFormat').string() !== 'DOCX' || raw.required('originalHash').string() !== hit.originalHash || raw.required('originalVersion').integer() !== hit.originalVersion) { throw new KnowledgeFailure('DocxPresentationBinding','history'); } hit.actualFormat = 'DOCX';
    }
    if (hit.sourceKind === KnowledgeSourceKind.Image) {
      imageExactFields(raw,['wire','citationId','match','sourceKind','actualFormat','originalHash','originalVersion']);
      hit.actualFormat = raw.required('actualFormat').string();
      if (raw.required('sourceKind').string() !== 'Image' || ['JPEG','PNG','WEBP'].indexOf(hit.actualFormat) < 0 || raw.required('originalHash').string() !== hit.originalHash || raw.required('originalVersion').integer() !== hit.originalVersion) { throw new KnowledgeFailure('ImagePresentationBinding','history'); }
    }
    const match = raw.required('match'); input.terms = prepareTextQuery(input.actualInput).terms;
    if (JSON.stringify(input.terms) !== JSON.stringify(match.required('terms').array().map((term: PdfJsonNode): string => term.string()))) { throw new KnowledgeFailure('PresentationTermsMismatch','history'); }
    if (match.required('actualInput').string() !== input.actualInput || match.required('policyVersion').string() !== 'LITERAL-ASCII-FOLD-1' || input.terms.length > 64) { throw new KnowledgeFailure('PresentationInput','history'); }
    const rebuilt = knowledgeMatch(hit,input,true);
    const ranges: string = JSON.stringify(match.required('ranges').array().map((range: PdfJsonNode): number[] => [range.required('start').integer(),range.required('end').integer()]));
    if (rebuilt.kind !== match.required('kind').string() || ranges !== JSON.stringify(rebuilt.ranges.map((range: KnowledgeResultRange): number[] => [range.start,range.end])) || match.required('matchedTerms').array().map((term: PdfJsonNode): string => term.string()).join('\t') !== rebuilt.matchedTerms.join('\t')) { throw new KnowledgeFailure('PresentationRangeMismatch','history'); }
    rebuilt.textHash = match.required('textHash').string(); rebuilt.compatibility = match.required('compatibility').kind === 'true'; hit.match = rebuilt;
    if (hit.sourceKind === KnowledgeSourceKind.Image || hit.sourceKind === KnowledgeSourceKind.Docx) { return; }
    const pages = raw.required('pages'); const state: string = pages.required('state').string(); const restored = new ResultPageReference();
    // Text citations have no PDF context. PDF context is independently revalidated before navigation.
    if (hit.sourceKind === KnowledgeSourceKind.Pdf && pages.required('originalHash').string().length > 0) { pdfCopyPageContext(pdfDecodePageContext(pages),restored); }
    restored.physicalPages1Based = pages.required('physicalPages1Based').array().map((p: PdfJsonNode): number => p.integer()); restored.evidenceIds = pages.required('evidenceIds').array().map((id: PdfJsonNode): string => id.string()); restored.uncoveredNodeIds = pages.required('uncoveredNodeIds').array().map((id: PdfJsonNode): string => id.string()); restored.reason = pages.required('reason').string();
    restored.state = state === PdfPageReferenceState.Verified ? PdfPageReferenceState.Verified : state === PdfPageReferenceState.Partial ? PdfPageReferenceState.Partial : state === PdfPageReferenceState.Conflict ? PdfPageReferenceState.Conflict : PdfPageReferenceState.Unknown;
    if (restored.physicalPages1Based.some((p: number): boolean => p < 1 || p > restored.originalPages) || restored.physicalPages1Based.length > 50) { throw new KnowledgeFailure('PresentationPages','history'); } hit.pages = restored;
  }
  async archive(id: string, archived: boolean): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        await transaction.execute('UPDATE kb_vector_generation SET eligibility=0 WHERE doc=?',[id]);
        await transaction.execute('UPDATE kb_document SET archived=?,epoch=epoch+1,updated=? WHERE id=? AND tombstone=0',[archived ? 1 : 0,Date.now(),id]);
        await transaction.execute('UPDATE kb_eligibility_mirror SET epoch=epoch+1,revision=revision+1,state=? WHERE doc=?',['Pending',id]);
        await transaction.execute('UPDATE kb_job SET epoch=epoch+1,stage=? WHERE doc=? AND stage<>?',[PdfStage.Paused,id,PdfStage.Published]);
      });
    });
  }
  private async terminate(transaction: relationalStore.Transaction, job: PdfIngestionJob): Promise<void> {
    await transaction.execute('UPDATE kb_job SET terminated=1,epoch=epoch+1,stage=? WHERE id=?',[PdfStage.Paused,job.id]);
    await transaction.execute('UPDATE kb_content_generation SET state=? WHERE id=? AND state NOT IN (?,?)',['Retiring',job.generation,'CleanupClaimed','Removed']);
    await transaction.execute('UPDATE kb_pin SET state=? WHERE owner=? AND state<>?',[KnowledgePinState.ReleasePending,job.id,KnowledgePinState.Released]);
    await transaction.execute('INSERT OR IGNORE INTO kb_cleanup VALUES(?,?,?,?,?,?,?)',[`cleanup-${job.generation}`,job.documentId,job.generation,'','','','']);
  }
  async deleteDocument(id: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        await transaction.execute('UPDATE kb_document SET tombstone=1,epoch=epoch+1,active_content=?,active_vector=?,active_space=?,stage=?,chunks=0,updated=? WHERE id=?',['','','',PdfStage.Deleted,Date.now(),id]);
        await transaction.execute('UPDATE kb_vector_generation SET eligibility=0,state=? WHERE doc=?',['Retiring',id]);
        for (const job of await this.jobs()) { if (job.documentId === id && !job.terminated) { await this.terminate(transaction,job); } }
      });
    });
  }
  async abandon(jobId: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        const jobs: PdfIngestionJob[] = await this.jobs(); const job: PdfIngestionJob | undefined = jobs.find((item: PdfIngestionJob): boolean => item.id === jobId);
        if (job === undefined || job.terminated) { return; }
        const rows: relationalStore.ResultSet = await transaction.querySql('SELECT active_content FROM kb_document WHERE id=?',[job.documentId]);
        try { if (!rows.goToNextRow() || rows.getString(0) === job.generation || job.stage === PdfStage.Published) { throw new KnowledgeFailure('CannotAbandonPublished','lifecycle'); } } finally { rows.close(); }
        await this.terminate(transaction,job);
      });
    });
  }
  async cleanups(): Promise<KnowledgeCleanupIntent[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM kb_cleanup ORDER BY id'); const intents: KnowledgeCleanupIntent[] = [];
    try { while (rows.goToNextRow()) { if (intents.length >= 10000) { throw new KnowledgeFailure('CleanupBudget','read'); } const intent: KnowledgeCleanupIntent = new KnowledgeCleanupIntent(); intent.id = rows.getString(0); intent.documentId = rows.getString(1); intent.generation = rows.getString(2); intent.claim = rows.getString(3); intent.assets = rows.getString(4).length === 0 ? [] : pdfReadFields(rows.getString(4),10000); intent.vectorSpaceId = rows.getString(5); intent.failure = rows.getString(6); intents.push(intent); } } finally { rows.close(); }
    for (const intent of intents) { const targets = await this.requireStore().querySql('SELECT space,vector_generation,content_generation,owner,state,failure FROM kb_cleanup_target WHERE intent=? AND kind=?',[intent.id,'Vector']); try { while (targets.goToNextRow()) { const target: KnowledgeCleanupTarget = new KnowledgeCleanupTarget(); target.spaceId = targets.getString(0); target.vectorGeneration = targets.getString(1); target.contentGeneration = targets.getString(2); target.owner = targets.getString(3); target.state = targets.getString(4); target.failure = targets.getString(5); intent.vectorTargets.push(target); } } finally { targets.close(); } } return intents;
  }
  async claimCleanup(id: string): Promise<KnowledgeCleanupIntent | undefined> {
    let claimed: KnowledgeCleanupIntent | undefined = undefined;
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        const intents: KnowledgeCleanupIntent[] = await this.cleanups(); const intent: KnowledgeCleanupIntent | undefined = intents.find((item: KnowledgeCleanupIntent): boolean => item.id === id); if (intent === undefined) { return; }
        if (intent.id.startsWith('vector-cleanup-')) {
          const readers = await transaction.querySql('SELECT id FROM kb_read_lease WHERE generation=?',[intent.generation]); try { if (readers.goToNextRow()) { return; } } finally { readers.close(); }
          for (const target of intent.vectorTargets) { const active = await transaction.querySql('SELECT v.id FROM kb_vector_generation v WHERE v.id=? AND v.space=? AND v.content_generation=? AND v.state IN (?,?) AND NOT EXISTS (SELECT 1 FROM kb_document d WHERE d.active_vector=v.id AND d.tombstone=0)',[target.vectorGeneration,target.spaceId,intent.generation,'Retiring','CleanupClaimed']); try { if (!active.goToNextRow()) { return; } } finally { active.close(); } }
          if (intent.vectorTargets.length !== 1) { throw new KnowledgeFailure('VectorRetirementTargetInvalid','claim'); }
          if (intent.claim.length === 0) { intent.claim = `claim-${intent.id}`; await transaction.execute('UPDATE kb_cleanup SET claim=? WHERE id=?',[intent.claim,intent.id]); for (const target of intent.vectorTargets) { await transaction.execute('UPDATE kb_vector_generation SET state=?,cleanup_claim=?,eligibility=0 WHERE id=?',['CleanupClaimed',intent.claim,target.vectorGeneration]); } }
          claimed = intent; return;
        }
        const otherVectorClaim = await transaction.querySql('SELECT id FROM kb_cleanup WHERE generation=? AND id<>? AND id LIKE ?',[intent.generation,intent.id,'vector-cleanup-%']); try { if (otherVectorClaim.goToNextRow()) { return; } } finally { otherVectorClaim.close(); }
        const eligibility: relationalStore.ResultSet = await transaction.querySql('SELECT g.id FROM kb_content_generation g WHERE g.id=? AND g.state IN (?,?) AND NOT EXISTS (SELECT 1 FROM kb_document d WHERE d.active_content=g.id AND d.tombstone=0) AND NOT EXISTS (SELECT 1 FROM kb_job j WHERE j.generation=g.id AND j.terminated=0) AND NOT EXISTS (SELECT 1 FROM kb_read_lease l WHERE l.generation=g.id) AND NOT EXISTS (SELECT 1 FROM kb_pin p WHERE p.generation=g.id AND p.state NOT IN (?,?))',[intent.generation,'Retiring','CleanupClaimed',KnowledgePinState.ReleasePending,KnowledgePinState.Released]);
        try { if (!eligibility.goToNextRow()) { return; } } finally { eligibility.close(); }
        if (intent.claim.length === 0) {
          intent.claim = `claim-${intent.generation}`; const assets: relationalStore.ResultSet = await transaction.querySql('SELECT id FROM kb_asset WHERE generation=?',[intent.generation]);
          try { while (assets.goToNextRow()) { intent.assets.push(assets.getString(0)); } } finally { assets.close(); }
          await this.host.assertUnifiedUnheld('PdfAssetAdapter',intent.assets);
          const vectors: relationalStore.ResultSet = await transaction.querySql('SELECT id,space,job FROM kb_vector_generation WHERE content_generation=?',[intent.generation]);
          try { while (vectors.goToNextRow()) { const target: KnowledgeCleanupTarget = new KnowledgeCleanupTarget(); target.vectorGeneration = vectors.getString(0); target.spaceId = vectors.getString(1); target.owner = vectors.getString(2); target.contentGeneration = intent.generation; intent.vectorTargets.push(target); } } finally { vectors.close(); }
          for (const target of intent.vectorTargets) { await transaction.execute('UPDATE kb_vector_generation SET state=?,eligibility=0,cleanup_claim=? WHERE id=?',['CleanupClaimed',intent.claim,target.vectorGeneration]); await transaction.execute('INSERT INTO kb_cleanup_target VALUES(?,?,?,?,?,?,?,?)',[intent.id,'Vector',intent.generation,target.spaceId,target.vectorGeneration,target.owner,'Pending','']); }
          await transaction.execute('UPDATE kb_content_generation SET state=?,cleanup_claim=? WHERE id=?',['CleanupClaimed',intent.claim,intent.generation]);
          await transaction.execute('UPDATE kb_cleanup SET claim=?,assets=? WHERE id=?',[intent.claim,pdfStoreFields(intent.assets),intent.id]);
        }
        claimed = intent;
      });
    }); return claimed;
  }
  async finishCleanup(claim: KnowledgeCleanupIntent, failure: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        const rows: relationalStore.ResultSet = await transaction.querySql('SELECT id FROM kb_cleanup WHERE id=? AND claim=?',[claim.id,claim.claim]);
        try { if (!rows.goToNextRow() || claim.claim.length === 0) { throw new KnowledgeFailure('CleanupClaimMismatch','finish'); } } finally { rows.close(); }
        if (failure.length > 0) { await transaction.execute('UPDATE kb_cleanup SET failure=? WHERE id=?',[failure,claim.id]); return; }
        const pending = await transaction.querySql('SELECT intent FROM kb_cleanup_target WHERE intent=? AND state<>?',[claim.id,'Done']); try { if (pending.goToNextRow()) { throw new KnowledgeFailure('VectorCleanupTargetsPending','finish'); } } finally { pending.close(); }
        if (claim.id.startsWith('vector-cleanup-')) {
          for (const target of claim.vectorTargets) {
            await transaction.execute('DELETE FROM kb_vector_input WHERE generation=?',[target.vectorGeneration]); await transaction.execute('DELETE FROM kb_input_attempt WHERE generation=?',[target.vectorGeneration]);
            await transaction.execute('UPDATE kb_derived_reservation SET state=?,reserved=0 WHERE owner=?',['Released',target.owner]);
            await transaction.execute('DELETE FROM kb_vector_generation WHERE id=? AND cleanup_claim=?',[target.vectorGeneration,claim.claim]);
          }
          await transaction.execute('DELETE FROM kb_cleanup_target WHERE intent=?',[claim.id]); await transaction.execute('DELETE FROM kb_cleanup WHERE id=?',[claim.id]); return;
        }
        await transaction.execute('DELETE FROM kb_vector_input WHERE generation IN (SELECT id FROM kb_vector_generation WHERE content_generation=?)',[claim.generation]);
        await transaction.execute('UPDATE kb_derived_reservation SET state=? WHERE owner IN (SELECT job FROM kb_vector_generation WHERE content_generation=?)',['Released',claim.generation]);
        await transaction.execute('DELETE FROM kb_input_attempt WHERE generation IN (SELECT id FROM kb_vector_generation WHERE content_generation=?)',[claim.generation]);
        await transaction.execute('DELETE FROM kb_vector_generation WHERE content_generation=?',[claim.generation]); await transaction.execute('DELETE FROM kb_cleanup_target WHERE intent=?',[claim.id]);
        await transaction.execute('DELETE FROM kb_chunk WHERE generation=?',[claim.generation]); await transaction.execute('DELETE FROM kb_asset WHERE generation=?',[claim.generation]);
        await transaction.execute('DELETE FROM kb_local_chunk WHERE generation=?',[claim.generation]); await transaction.execute('DELETE FROM kb_mapping_evidence WHERE generation=?',[claim.generation]);
        await transaction.execute('DELETE FROM kb_asset_node WHERE asset IN (SELECT asset FROM kb_asset_write WHERE generation=?)',[claim.generation]);
        await transaction.execute('DELETE FROM kb_asset_write WHERE generation=?',[claim.generation]);
        await transaction.execute('UPDATE kb_content_generation SET state=? WHERE id=? AND cleanup_claim=?',['Removed',claim.generation,claim.claim]);
        await transaction.execute('UPDATE kb_pin SET state=? WHERE generation=? AND state=?',[KnowledgePinState.Released,claim.generation,KnowledgePinState.ReleasePending]);
        await transaction.execute('DELETE FROM kb_cleanup WHERE id=?',[claim.id]);
      });
    });
  }
  async finishVectorTarget(claim: KnowledgeCleanupIntent, target: KnowledgeCleanupTarget, failure: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const rows = await tx.querySql('SELECT id FROM kb_cleanup WHERE id=? AND claim=? AND generation=?',[claim.id,claim.claim,target.contentGeneration]); try { if (claim.claim.length === 0 || !rows.goToNextRow()) { throw new KnowledgeFailure('CleanupClaimMismatch','vector-cleanup'); } } finally { rows.close(); }
      await tx.execute('UPDATE kb_cleanup_target SET state=?,failure=? WHERE intent=? AND kind=? AND space=? AND vector_generation=?',[failure.length === 0 ? 'Done' : 'Pending',failure,claim.id,'Vector',target.spaceId,target.vectorGeneration]);
    }); });
  }
  async retireContent(generation: string): Promise<void> {
    const job = await this.generationJob(generation);
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const rows = await tx.querySql('SELECT id FROM kb_content_generation WHERE id=? AND state=? AND cleanup_claim=? AND NOT EXISTS (SELECT 1 FROM kb_document WHERE active_content=? AND tombstone=0)',[generation,'Retained','',generation]); try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('RetainedStillActive','retire'); } } finally { rows.close(); } await this.terminate(tx,job);
    }); });
  }
  async retireVectorGeneration(generation: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const rows = await tx.querySql('SELECT id,doc,content_generation,space,job FROM kb_vector_generation v WHERE id=? AND state IN (?,?,?) AND cleanup_claim=? AND NOT EXISTS (SELECT 1 FROM kb_document d WHERE d.active_vector=v.id AND d.tombstone=0)',[generation,'Retained','Paused','Failed','']);
      let document: string = ''; let content: string = ''; let space: string = ''; let owner: string = '';
      try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('VectorRetirementActiveOrBusy','retire'); } document = rows.getString(1); content = rows.getString(2); space = rows.getString(3); owner = rows.getString(4); } finally { rows.close(); }
      const id: string = `vector-cleanup-${generation}`; await tx.execute('UPDATE kb_vector_generation SET state=?,eligibility=0 WHERE id=?',['Retiring',generation]);
      await tx.execute('INSERT INTO kb_cleanup VALUES(?,?,?,?,?,?,?)',[id,document,content,'','','','']);
      await tx.execute('INSERT INTO kb_cleanup_target VALUES(?,?,?,?,?,?,?,?)',[id,'Vector',content,space,generation,owner,'Pending','']);
    }); });
  }
  async reconcile(sessionId: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        const orphan: relationalStore.ResultSet = await transaction.querySql('SELECT p.id FROM kb_pin p LEFT JOIN kb_job j ON j.id=p.owner LEFT JOIN kb_content_generation g ON g.id=p.generation WHERE p.state<>? AND (j.id IS NULL OR g.id IS NULL OR j.doc<>p.doc OR j.generation<>p.generation)',[KnowledgePinState.Released]);
        try { if (orphan.goToNextRow()) { throw new KnowledgeFailure('PinOwnerReconciliationUnknown','startup'); } } finally { orphan.close(); }
        // Called once by the singleton during fresh process assembly, never by a
        // view. Prior-process leases are retired by explicit session identity.
        await transaction.execute('UPDATE kb_session SET state=? WHERE id<>?',['ClosedPreviousProcess',sessionId]);
        await transaction.execute('DELETE FROM kb_read_lease WHERE session IN (SELECT id FROM kb_session WHERE state=?)',['ClosedPreviousProcess']);
         await transaction.execute('DELETE FROM r2v_release WHERE session IN (SELECT id FROM kb_session WHERE state=?)',['ClosedPreviousProcess']);
         await transaction.execute('DELETE FROM r2s_source_release WHERE session IN (SELECT id FROM kb_session WHERE state=?)',['ClosedPreviousProcess']);
        await transaction.execute('INSERT OR IGNORE INTO kb_session VALUES(?,?,?)',[sessionId,0,'Active']);
        await transaction.execute('UPDATE kb_job SET stage=?,epoch=epoch+1 WHERE terminated=0 AND stage NOT IN (?,?)',[PdfStage.Paused,PdfStage.Published,PdfStage.Paused]);
        await transaction.execute('UPDATE kb_embedding_grant SET revoked=1');
        await transaction.execute('UPDATE kb_vector_generation SET eligibility=0');
        await transaction.execute('UPDATE kb_eligibility_mirror SET state=?',['Pending']);
        await transaction.execute('UPDATE kb_input_attempt SET state=? WHERE state=?',['Unknown','InFlight']);
      });
    });
    this.host.sessionId = sessionId;
  }
  async resumeJob(jobId: string): Promise<PdfIngestionJob> {
    let resumed: PdfIngestionJob | undefined = undefined;
    await this.host.enqueue<void>(async (): Promise<void> => {
      await this.host.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        const rows: relationalStore.ResultSet = await transaction.querySql('SELECT j.* FROM kb_job j JOIN kb_document d ON d.id=j.doc JOIN kb_content_generation g ON g.id=j.generation WHERE j.id=? AND j.terminated=0 AND d.tombstone=0 AND g.cleanup_claim=? AND g.state IN (?,?,?)',[jobId,'','Staging','Publishable','Active']);
        let job: PdfIngestionJob;
        try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('CheckpointUnavailable','resume'); } job = this.rowJob(rows); } finally { rows.close(); }
        const document: relationalStore.ResultSet = await transaction.querySql('SELECT epoch,active_content FROM kb_document WHERE id=?',[job.documentId]);
        try { if (!document.goToNextRow()) { throw new KnowledgeFailure('DocumentMissing','resume'); } job.epoch = document.getLong(0); job.expectedOldGeneration = document.getString(1); } finally { document.close(); }
        if (job.stage === PdfStage.Published || job.expectedOldGeneration === job.generation) { job.stage = PdfStage.Published; resumed = job; return; }
        const prepared: relationalStore.ResultSet = await transaction.querySql('SELECT state FROM kb_content_generation WHERE id=?',[job.generation]);
        let stage: PdfStage = PdfStage.Review;
        try { if (prepared.goToNextRow() && prepared.getString(0) === 'Publishable') { stage = PdfStage.Prepared; } } finally { prepared.close(); }
        await transaction.execute('UPDATE kb_job SET epoch=?,stage=?,old_active=? WHERE id=?',[job.epoch,stage,job.expectedOldGeneration,job.id]);
        await transaction.execute('UPDATE kb_content_generation SET epoch=?,old_active=? WHERE id=?',[job.epoch,job.expectedOldGeneration,job.generation]);
        job.stage = stage; resumed = job;
      });
    });
    if (resumed === undefined) { throw new KnowledgeFailure('CheckpointUnavailable','resume'); } await this.candidate(resumed); return resumed;
  }
}
