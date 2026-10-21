import { relationalStore } from '@kit.ArkData';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { DOCX_STORE_DDL, DOCX_STORE_LAYOUT, docxVerifyExisting } from './DocxStoreLayout';
import { imageVerifyExisting } from './ImageStoreLayout';
import { BoundedDocumentJson, PdfJsonNode } from '../pipeline/BoundedDocumentJson';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { DocxPublicationPort, DocxSnapshotAssetPort } from '../domain/DocxKnowledgePorts';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { KnowledgePhysicalBudgetPort, KnowledgeDerivedUsage } from './KnowledgeDerivedBudget';
import { docxDecodeSnapshot, docxVerifySnapshot, docxReadLocator } from '../pipeline/DocxSnapshotCodec';
import { docxStructureChunks } from '../pipeline/DocxStructureChunker';
import { docxPublicationBudget } from './DocxStoreLayout';
import { KnowledgeHit, KnowledgeSourceKind, KnowledgeChannel } from '../domain/KnowledgeSearchModels';
import { TextQueryInput } from '../domain/TextKnowledgeModels';
import { knowledgeLiteralScore } from '../pipeline/KnowledgeMatchPolicy';
import { DocxOriginal, DocxDocument, DocxJob, DocxAssetClaim, DocxReadLease, DocxReleaseReceipt,
  DocxCleanupIntent, DocxFailure, DocxStage, DocxResultBinding, DocxSnapshot, DocxChunk, docxId, docxHash, docxStage } from '../domain/DocxKnowledgeModels';

function docxStoredNumber(rows: relationalStore.ResultSet, at: number): number {
  const n: number = rows.getLong(at); if (!Number.isSafeInteger(n) || n < 0) { throw new DocxFailure('StoredNumberInvalid','docx-store'); } return n;
}
function docxStoredBoolean(rows: relationalStore.ResultSet, at: number): boolean {
  const n: number = docxStoredNumber(rows,at); if (n > 1) { throw new DocxFailure('StoredBooleanInvalid','docx-store'); } return n === 1;
}
export class DocxKnowledgeRepository implements DocxPublicationPort {
  private static recoveredHosts: KnowledgeStoreHost[] = [];
  private host: KnowledgeStoreHost; private opened: boolean = false;
  private identity: KnowledgeIdentityPort | undefined = undefined; private assets: DocxSnapshotAssetPort | undefined = undefined;
  private physical: KnowledgePhysicalBudgetPort | undefined = undefined;
  attachAssets(identity: KnowledgeIdentityPort, assets: DocxSnapshotAssetPort, physical: KnowledgePhysicalBudgetPort): void { this.identity = identity; this.assets = assets; this.physical = physical; }
  constructor(host: KnowledgeStoreHost) { this.host = host; }
  ready(): boolean { return this.opened && this.host.docxReady && this.host.m1Ready; }
  private store(): relationalStore.RdbStore { if (!this.ready()) { throw new DocxFailure('DocxStoreUnavailable','docx-store'); } return this.host.requireStore(); }
  async open(): Promise<void> {
    if (this.opened) { return; } await this.host.acquireExtension();
    try {
      await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
        if (!(await imageVerifyExisting(tx))) { throw new DocxFailure('ImageRegistryNotReady','migration'); }
        if (!(await docxVerifyExisting(tx))) {
          for (const ddl of DOCX_STORE_DDL) { await tx.execute(ddl); }
          await tx.execute('INSERT INTO kb_docx_meta VALUES(?,?)',['layout',DOCX_STORE_LAYOUT]);
          await tx.execute('INSERT INTO kb_docx_meta VALUES(?,?)',['state','Committed']);
          await tx.execute('INSERT INTO kb_source_registry VALUES(?,?,?)',['Docx','DOCX-NORMALIZED-1','Enabled']);
        }
        await docxVerifyExisting(tx); await imageVerifyExisting(tx);
      }); }); this.opened = true; this.host.docxReady = true;
      if (DocxKnowledgeRepository.recoveredHosts.indexOf(this.host) < 0) {
        await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
          await tx.execute("INSERT OR REPLACE INTO kb_docx_release SELECT id,'ProcessEnded','Released','PreviousProcessResourcesEnded' FROM kb_docx_lease");
          await tx.execute('DELETE FROM kb_docx_lease');
          await tx.execute("UPDATE kb_docx_vector_input SET state='Unknown' WHERE state='InFlight'");
        }); DocxKnowledgeRepository.recoveredHosts.push(this.host);
      }
    } catch (error) { this.opened = false; this.host.docxReady = false; await this.host.release(); if (error instanceof Error) { throw error; } throw new DocxFailure('MigrationFailed','migration'); }
  }
  async close(): Promise<void> { if (this.opened) { await this.host.release(); this.opened = false; } }
  private async write(action: (tx: relationalStore.Transaction) => Promise<void>): Promise<void> {
    this.store(); await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(action); });
  }
  private documentRow(rows: relationalStore.ResultSet): DocxDocument {
    const d: DocxDocument = new DocxDocument(); d.id = rows.getString(0); d.title = rows.getString(1); d.epoch = docxStoredNumber(rows,2);
    d.archived = docxStoredBoolean(rows,3); d.tombstone = docxStoredBoolean(rows,4); d.activeOriginal = rows.getString(5);
    d.activeGeneration = rows.getString(6); d.chunkCount = docxStoredNumber(rows,7); d.stage = docxStage(rows.getString(8));
    if (!docxId(d.id) || d.chunkCount > 2000) { throw new DocxFailure('StoredDocumentInvalid','docx-store'); } return d;
  }
  async list(): Promise<DocxDocument[]> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM kb_docx_document ORDER BY id'); const docs: DocxDocument[] = [];
    try { while (rows.goToNextRow()) { if (docs.length >= 10000) { throw new DocxFailure('DocumentBudget','docx-store'); } docs.push(this.documentRow(rows)); } } finally { rows.close(); } return docs;
  }
  async get(id: string): Promise<DocxDocument | undefined> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM kb_docx_document WHERE id=?',[id]);
    try { return rows.goToNextRow() ? this.documentRow(rows) : undefined; } finally { rows.close(); }
  }
  async original(asset: string): Promise<DocxOriginal> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM kb_docx_original WHERE asset=?',[asset]);
    try {
      if (!rows.goToNextRow()) { throw new DocxFailure('OriginalMissing','docx-read'); }
      const o: DocxOriginal = new DocxOriginal(); o.assetId = rows.getString(0); o.documentId = rows.getString(1); o.sourceId = rows.getString(2);
      o.version = docxStoredNumber(rows,3); o.title = rows.getString(4); o.hash = rows.getString(5); o.bytes = docxStoredNumber(rows,6); o.mainPart = rows.getString(7); o.savedAt = docxStoredNumber(rows,8);
      if (!docxId(o.assetId) || !docxId(o.documentId) || !docxId(o.sourceId) || !docxHash(o.hash) || o.version < 1 || o.bytes < 1 || o.bytes > 20*1024*1024) { throw new DocxFailure('StoredOriginalInvalid','docx-store'); } return o;
    } finally { rows.close(); }
  }
  async latestOriginal(documentId: string): Promise<DocxOriginal> {
    const rows = await this.store().querySql("SELECT o.asset FROM kb_docx_original o WHERE o.doc=? AND (o.asset=(SELECT active_original FROM kb_docx_document WHERE id=o.doc) OR NOT EXISTS(SELECT 1 FROM kb_docx_generation g WHERE g.original=o.asset AND g.state='Abandoned')) ORDER BY o.version DESC,o.saved DESC,o.asset DESC LIMIT 1",[documentId]); let asset: string = '';
    try { if (!rows.goToNextRow()) { throw new DocxFailure('OriginalMissing','read'); } asset = rows.getString(0); } finally { rows.close(); } return this.original(asset);
  }
  async nextVersion(documentId: string): Promise<number> {
    const rows = await this.store().querySql('SELECT MAX(version) FROM kb_docx_original WHERE doc=?',[documentId]);
    try { if (!rows.goToNextRow() || rows.getLong(0) < 1 || !Number.isSafeInteger(rows.getLong(0)+1)) { throw new DocxFailure('VersionSequenceInvalid','replace'); } return rows.getLong(0)+1; } finally { rows.close(); }
  }
  async assertUnpinned(assets: string[]): Promise<void> {
    for (const asset of assets) { const rows = await this.store().querySql('SELECT (SELECT count(*) FROM kb_docx_asset WHERE id=? AND pins>0)+(SELECT count(*) FROM kb_docx_lease WHERE asset=?)',[asset,asset]); try { if (!rows.goToNextRow() || rows.getLong(0) !== 0) { throw new DocxFailure('DocxAssetHeld','cleanup'); } } finally { rows.close(); } }
  }
  async register(o: DocxOriginal, assets: DocxAssetClaim[]): Promise<void> {
    if (!docxId(o.documentId) || !docxId(o.assetId) || !docxId(o.sourceId) || !docxHash(o.hash) || o.version < 1 || o.bytes < 1 || o.bytes > 20*1024*1024 || assets.length < 1 || assets.length > 256 || assets.filter((a: DocxAssetClaim): boolean => a.assetId === o.assetId && a.hash === o.hash && a.role === 'Original' && a.owner === 'DocumentParseService').length !== 1 || assets.some((a: DocxAssetClaim): boolean => a.documentId !== o.documentId || !docxId(a.assetId) || !docxId(a.owner) || !docxHash(a.hash) || !Number.isSafeInteger(a.pins) || a.pins < 1)) { throw new DocxFailure('OriginalOwnershipInvalid','docx-register'); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const prior: relationalStore.ResultSet = await tx.querySql('SELECT tombstone FROM kb_docx_document WHERE id=?',[o.documentId]); let found: boolean = false;
      try { if (prior.goToNextRow()) { found = true; if (prior.getLong(0) !== 0) { throw new DocxFailure('DeletedDocument','docx-register'); } } } finally { prior.close(); }
      const owner = await tx.querySql('SELECT asset,doc,version FROM kb_docx_original WHERE source=? OR (doc=? AND version=?)',[o.sourceId,o.documentId,o.version]);
      try { if (owner.goToNextRow()) { throw new DocxFailure('SourceOwnerOrVersionAlreadyRegistered','docx-register'); } } finally { owner.close(); }
      if (!found) { await tx.execute('INSERT INTO kb_docx_document VALUES(?,?,0,0,0,?,?,0,?)',[o.documentId,o.title,o.assetId,'',DocxStage.Saved]); }
      await tx.execute('INSERT INTO kb_docx_original VALUES(?,?,?,?,?,?,?,?,?)',[o.assetId,o.documentId,o.sourceId,o.version,o.title,o.hash,o.bytes,o.mainPart,o.savedAt]);
      for (const a of assets) { await tx.execute('INSERT INTO kb_docx_asset VALUES(?,?,?,?,?,?,?,?)',[a.assetId,a.documentId,a.owner,a.hash,a.bytes,a.generation,a.role,a.pins]); }
    });
  }
  async holdAsset(asset: DocxAssetClaim): Promise<void> {
    if (!docxId(asset.assetId) || !docxId(asset.documentId) || !docxHash(asset.hash) || asset.owner !== 'DocumentParseService' || asset.bytes < 1 || asset.bytes > 30*1024*1024) { throw new DocxFailure('AssetOwnerInvalid','hold'); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const document: relationalStore.ResultSet = await tx.querySql('SELECT tombstone FROM kb_docx_document WHERE id=?',[asset.documentId]);
      try { if (!document.goToNextRow() || document.getLong(0) !== 0) { throw new DocxFailure('DocumentUnavailable','hold'); } } finally { document.close(); }
      const prior: relationalStore.ResultSet = await tx.querySql('SELECT doc,owner,hash FROM kb_docx_asset WHERE id=?',[asset.assetId]); let found: boolean = false;
      try { if (prior.goToNextRow()) { found = true; if (prior.getString(0) !== asset.documentId || prior.getString(1) !== asset.owner || prior.getString(2) !== asset.hash) { throw new DocxFailure('AssetOwnerConflict','hold'); } } } finally { prior.close(); }
      if (!found) { await tx.execute('INSERT INTO kb_docx_asset VALUES(?,?,?,?,?,?,?,?)',[asset.assetId,asset.documentId,asset.owner,asset.hash,asset.bytes,asset.generation,asset.role,1]); }
    });
  }
  private async assertJob(tx: relationalStore.Transaction, job: DocxJob): Promise<void> {
    const rows: relationalStore.ResultSet = await tx.querySql('SELECT epoch,tombstone,active_generation FROM kb_docx_document WHERE id=?',[job.documentId]);
    try { if (!rows.goToNextRow() || rows.getLong(0) !== job.epoch || rows.getLong(1) !== 0 || rows.getString(2) !== job.expectedActive) { throw new DocxFailure('StaleJob','docx-write'); } } finally { rows.close(); }
    const latest = await tx.querySql("SELECT o.asset FROM kb_docx_original o WHERE o.doc=? AND (o.asset=(SELECT active_original FROM kb_docx_document WHERE id=o.doc) OR NOT EXISTS(SELECT 1 FROM kb_docx_generation g WHERE g.original=o.asset AND g.state='Abandoned')) ORDER BY o.version DESC,o.saved DESC,o.asset DESC LIMIT 1",[job.documentId]);
    try { if (!latest.goToNextRow() || latest.getString(0) !== job.originalAssetId) { throw new DocxFailure('CandidateOriginalSuperseded','docx-write'); } } finally { latest.close(); }
  }
  async begin(job: DocxJob): Promise<void> {
    if (!docxId(job.id) || !docxId(job.generation)) { throw new DocxFailure('JobIdentityInvalid','docx-job'); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJob(tx,job);
      const original: relationalStore.ResultSet = await tx.querySql('SELECT asset FROM kb_docx_original WHERE asset=? AND doc=?',[job.originalAssetId,job.documentId]);
      try { if (!original.goToNextRow()) { throw new DocxFailure('CandidateOriginalMissing','docx-job'); } } finally { original.close(); }
      await tx.execute('INSERT INTO kb_docx_job VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',[job.id,job.documentId,job.generation,job.originalAssetId,job.epoch,job.expectedActive,job.reportHash,job.snapshotHash,job.stage,job.checkpoint,job.failure,JSON.stringify(job.result)]);
      await tx.execute('INSERT INTO kb_docx_generation VALUES(?,?,?,?,?,?,?,?,?)',[job.generation,job.documentId,job.originalAssetId,job.epoch,'Staging','','','',0]);
    });
  }
  async checkpoint(job: DocxJob): Promise<void> {
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJob(tx,job);
      const state: relationalStore.ResultSet = await tx.querySql('SELECT state FROM kb_docx_generation WHERE id=? AND doc=? AND epoch=?',[job.generation,job.documentId,job.epoch]);
      try { if (!state.goToNextRow() || ['Staging','Prepared'].indexOf(state.getString(0)) < 0) { throw new DocxFailure('CandidateNotCurrent','checkpoint'); } } finally { state.close(); }
      await tx.execute('UPDATE kb_docx_job SET report=?,snapshot=?,stage=?,checkpoint=?,failure=?,result_binding=? WHERE id=? AND generation=?',[job.reportHash,job.snapshotHash,job.stage,job.checkpoint,job.failure,JSON.stringify(job.result),job.id,job.generation]);
    });
  }
  async jobs(): Promise<DocxJob[]> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM kb_docx_job ORDER BY id'); const jobs: DocxJob[] = [];
    try { while (rows.goToNextRow()) {
      if (jobs.length >= 10000) { throw new DocxFailure('JobBudget','docx-store'); }
      const j: DocxJob = new DocxJob(); j.id = rows.getString(0); j.documentId = rows.getString(1); j.generation = rows.getString(2); j.originalAssetId = rows.getString(3);
      j.epoch = docxStoredNumber(rows,4); j.expectedActive = rows.getString(5); j.reportHash = rows.getString(6); j.snapshotHash = rows.getString(7); j.stage = docxStage(rows.getString(8)); j.checkpoint = docxStage(rows.getString(9)); j.failure = rows.getString(10);
      const raw: PdfJsonNode = new BoundedDocumentJson(pdfCodecUtf8(rows.getString(11)),new KnowledgeCancellation()).read();
      const result: DocxResultBinding = new DocxResultBinding(); result.taskId = raw.required('taskId').string(); result.dataId = raw.required('dataId').string(); result.assetId = raw.required('assetId').string(); result.hash = raw.required('hash').string(); result.bytes = raw.required('bytes').integer(); result.originalHash = raw.required('originalHash').string(); result.originalVersion = raw.required('originalVersion').integer();
      if (raw.fields.length !== 7 || result.taskId.length > 0 && (!docxId(result.taskId) || !docxId(result.dataId) || !docxId(result.assetId) || !docxHash(result.hash) || !docxHash(result.originalHash) || result.bytes < 22 || result.bytes > 30*1024*1024 || result.originalVersion < 1)) { throw new DocxFailure('StoredResultBindingInvalid','docx-store'); } j.result = result;
      jobs.push(j);
    } } finally { rows.close(); } return jobs;
  }
  async acquireRead(lease: DocxReadLease): Promise<void> {
    if (!docxId(lease.id) || !docxId(lease.owner)) { throw new DocxFailure('LeaseIdentityInvalid','docx-read'); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const rows: relationalStore.ResultSet = await tx.querySql('SELECT a.id FROM kb_docx_asset a JOIN kb_docx_document d ON d.id=a.doc WHERE a.id=? AND a.doc=? AND a.pins>0 AND d.epoch=? AND d.tombstone=0',[lease.assetId,lease.documentId,lease.epoch]);
      try { if (!rows.goToNextRow()) { throw new DocxFailure('ReadIneligible','docx-read'); } } finally { rows.close(); }
      await tx.execute('INSERT INTO kb_docx_lease VALUES(?,?,?,?,?)',[lease.id,lease.documentId,lease.assetId,lease.owner,lease.epoch]);
    });
  }
  async releaseRead(receipt: DocxReleaseReceipt): Promise<void> {
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const complete: boolean = receipt.failure.length === 0 && (receipt.resource === 'Released' || receipt.resource === 'NotAcquired');
      await tx.execute('INSERT OR REPLACE INTO kb_docx_release VALUES(?,?,?,?)',[receipt.leaseId,receipt.resource,complete ? 'Released' : 'Held',receipt.failure]);
      if (complete) { await tx.execute('DELETE FROM kb_docx_lease WHERE id=?',[receipt.leaseId]); }
    });
  }
  async archive(id: string, archived: boolean): Promise<void> {
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await tx.execute('UPDATE kb_docx_document SET archived=?,epoch=epoch+1 WHERE id=? AND tombstone=0',[archived ? 1 : 0,id]);
      await tx.execute("UPDATE kb_docx_vector SET epoch=(SELECT epoch FROM kb_docx_document WHERE id=?) WHERE doc=? AND state='SemanticReady'",[id,id]);
      await tx.execute("UPDATE kb_docx_vector_mirror SET state='Pending',epoch=(SELECT epoch FROM kb_docx_document WHERE id=?),revision=revision+1 WHERE doc=?",[id,id]);
    });
  }
  async deleteDocument(id: string): Promise<void> {
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await tx.execute('UPDATE kb_docx_document SET tombstone=1,epoch=epoch+1,stage=? WHERE id=? AND tombstone=0',[DocxStage.Deleted,id]);
      await tx.execute("UPDATE kb_docx_generation SET state='Retained' WHERE doc=?",[id]);
      await tx.execute("UPDATE kb_docx_vector SET state='Retiring' WHERE doc=?",[id]);
      await tx.execute("UPDATE kb_docx_vector_mirror SET state='Invalid',revision=revision+1 WHERE doc=?",[id]);
      await tx.execute("INSERT OR IGNORE INTO kb_docx_cleanup SELECT 'delete-'||id,doc,id,owner,'Pending','' FROM kb_docx_asset WHERE doc=?",[id]);
    });
  }
  async cleanups(): Promise<DocxCleanupIntent[]> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM kb_docx_cleanup ORDER BY id'); const intents: DocxCleanupIntent[] = [];
    try { while (rows.goToNextRow()) { const c: DocxCleanupIntent = new DocxCleanupIntent(); c.id = rows.getString(0); c.documentId = rows.getString(1); c.assetId = rows.getString(2); c.owner = rows.getString(3); c.state = rows.getString(4); c.failure = rows.getString(5); intents.push(c); } } finally { rows.close(); } return intents;
  }
  async abandon(jobId: string): Promise<void> {
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const rows = await tx.querySql("SELECT g.id,g.doc FROM kb_docx_generation g JOIN kb_docx_job j ON j.generation=g.id WHERE j.id=? AND g.state IN ('Staging','Prepared')",[jobId]); let generation: string = ''; let document: string = '';
      try { if (!rows.goToNextRow()) { throw new DocxFailure('CandidateNotAbandonable','manage'); } generation = rows.getString(0); document = rows.getString(1); } finally { rows.close(); }
      await tx.execute("UPDATE kb_docx_generation SET state='Abandoned' WHERE id=?",[generation]);
      await tx.execute('UPDATE kb_docx_job SET stage=?,checkpoint=?,failure=? WHERE id=?',[DocxStage.Paused,DocxStage.Paused,'CandidateAbandoned',jobId]);
      await tx.execute("INSERT OR IGNORE INTO kb_docx_cleanup SELECT 'abandon-'||id,doc,id,owner,'Pending','' FROM kb_docx_asset WHERE generation=? AND owner='DocxSnapshotAssets'",[generation]);
      await tx.execute('DELETE FROM kb_docx_chunk WHERE generation=? AND doc=?',[generation,document]);
    });
  }
  async claimCleanup(id: string): Promise<DocxCleanupIntent | undefined> {
    let claim: DocxCleanupIntent | undefined = undefined;
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const rows = await tx.querySql("SELECT c.* FROM kb_docx_cleanup c JOIN kb_docx_document d ON d.id=c.doc JOIN kb_docx_asset a ON a.id=c.asset AND a.owner=c.owner WHERE c.id=? AND c.state<>'Done' AND (d.tombstone=1 OR EXISTS(SELECT 1 FROM kb_docx_generation g WHERE g.id=a.generation AND g.state='Abandoned')) AND NOT EXISTS(SELECT 1 FROM kb_docx_lease l WHERE l.doc=c.doc) AND NOT EXISTS(SELECT 1 FROM kb_docx_vector v WHERE v.doc=c.doc AND v.state<>'Removed' AND d.tombstone=1)",[id]);
      try { if (!rows.goToNextRow()) { return; } const c: DocxCleanupIntent = new DocxCleanupIntent(); c.id = rows.getString(0); c.documentId = rows.getString(1); c.assetId = rows.getString(2); c.owner = rows.getString(3); c.state = rows.getString(4); c.failure = rows.getString(5); if (c.owner !== 'DocxSnapshotAssets' && c.owner !== 'DocumentParseService') { throw new DocxFailure('UnknownAssetOwnerQuarantined','cleanup'); } claim = c; } finally { rows.close(); }
      await this.host.assertUnifiedUnheld(claim?.owner ?? '',[claim?.assetId ?? '']);
      if (claim?.owner === 'DocumentParseService') {
        const coupled: relationalStore.ResultSet = await tx.querySql("SELECT id FROM kb_docx_asset WHERE doc=? AND owner='DocumentParseService'",[claim.documentId]); const assets: string[] = [];
        try { while (coupled.goToNextRow()) { assets.push(coupled.getString(0)); } } finally { coupled.close(); }
        await this.host.assertUnifiedUnheld('DocumentParseService',assets);
      }
      await tx.execute("UPDATE kb_docx_cleanup SET state='Claimed' WHERE id=?",[id]); await tx.execute('UPDATE kb_docx_asset SET pins=0 WHERE id=? AND owner=?',[claim?.assetId ?? '',claim?.owner ?? '']);
      if (claim?.owner === 'DocumentParseService') { await tx.execute("UPDATE kb_docx_asset SET pins=0 WHERE doc=? AND owner='DocumentParseService' AND EXISTS(SELECT 1 FROM kb_docx_document d WHERE d.id=? AND d.tombstone=1)",[claim.documentId,claim.documentId]); }
    }); return claim;
  }
  async finishCleanup(claim: DocxCleanupIntent, failure: string): Promise<void> {
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await tx.execute('UPDATE kb_docx_cleanup SET state=?,failure=? WHERE id=? AND owner=?',[failure.length === 0 ? 'Done' : 'Pending',failure,claim.id,claim.owner]);
      if (failure.length === 0) {
        await tx.execute('DELETE FROM kb_docx_asset WHERE id=? AND owner=? AND pins=0',[claim.assetId,claim.owner]);
        await tx.execute('DELETE FROM kb_docx_chunk WHERE doc=? AND EXISTS(SELECT 1 FROM kb_docx_document d WHERE d.id=? AND d.tombstone=1) AND NOT EXISTS(SELECT 1 FROM kb_docx_asset WHERE doc=?)',[claim.documentId,claim.documentId,claim.documentId]);
        await tx.execute("UPDATE kb_docx_generation SET asset='',state='Removed' WHERE doc=? AND EXISTS(SELECT 1 FROM kb_docx_document d WHERE d.id=? AND d.tombstone=1) AND NOT EXISTS(SELECT 1 FROM kb_docx_asset WHERE doc=?)",[claim.documentId,claim.documentId,claim.documentId]);
      }
    });
  }
  async removeSnapshotClaim(claim: DocxCleanupIntent): Promise<void> {
    const assets: DocxSnapshotAssetPort | undefined = this.assets; if (assets === undefined || claim.owner !== 'DocxSnapshotAssets') { throw new DocxFailure('SnapshotOwnerRequired','cleanup'); }
    const rows = await this.store().querySql("SELECT id FROM kb_docx_cleanup WHERE id=? AND asset=? AND state='Claimed' AND owner='DocxSnapshotAssets'",[claim.id,claim.assetId]);
    try { if (!rows.goToNextRow()) { throw new DocxFailure('CleanupClaimMissing','cleanup'); } } finally { rows.close(); } await assets.remove(claim.assetId);
  }
  async snapshot(generation: string): Promise<DocxSnapshot> {
    const assets: DocxSnapshotAssetPort | undefined = this.assets; const identity: KnowledgeIdentityPort | undefined = this.identity;
    if (assets === undefined || identity === undefined) { throw new DocxFailure('SnapshotPortsUnavailable','read'); }
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT asset,hash,report FROM kb_docx_generation WHERE id=?',[generation]);
    try {
      if (!rows.goToNextRow()) { throw new DocxFailure('SnapshotCheckpointMissing','read'); }
      const s: DocxSnapshot = docxDecodeSnapshot(await assets.read(rows.getString(0),rows.getString(1),new KnowledgeCancellation()),new KnowledgeCancellation());
      if (s.generation !== generation || s.hash !== rows.getString(1) || s.coverage.hash !== rows.getString(2)) { throw new DocxFailure('SnapshotCheckpointBinding','read'); }
      await docxVerifySnapshot(s,identity,new KnowledgeCancellation()); return s;
    } finally { rows.close(); }
  }
  async chunks(generation: string): Promise<DocxChunk[]> {
    const identity: KnowledgeIdentityPort | undefined = this.identity; if (identity === undefined) { throw new DocxFailure('IdentityPortMissing','read'); }
    const s: DocxSnapshot = await this.snapshot(generation); const expected: DocxChunk[] = await docxStructureChunks(s,identity,new KnowledgeCancellation());
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM kb_docx_chunk WHERE generation=? ORDER BY ordinal',[generation]); const chunks: DocxChunk[] = [];
    try { while (rows.goToNextRow()) {
      const c: DocxChunk = new DocxChunk(); c.id = rows.getString(0); c.documentId = rows.getString(1); c.generation = rows.getString(2); c.ordinal = docxStoredNumber(rows,3); c.text = rows.getString(4); c.embeddingText = rows.getString(5); c.inputHash = rows.getString(6); c.locator = docxReadLocator(new BoundedDocumentJson(pdfCodecUtf8(rows.getString(7)),new KnowledgeCancellation()).read());
      if (chunks.length >= expected.length || JSON.stringify(c) !== JSON.stringify(expected[chunks.length])) { throw new DocxFailure('ChunkReadbackMismatch','read'); } chunks.push(c);
    } } finally { rows.close(); }
    if (chunks.length !== expected.length) { throw new DocxFailure('ChunkCoverageIncomplete','read'); } return chunks;
  }
  async prepare(job: DocxJob, snapshot: DocxSnapshot, chunks: DocxChunk[]): Promise<void> {
    const assets: DocxSnapshotAssetPort | undefined = this.assets; const identity: KnowledgeIdentityPort | undefined = this.identity; const physical: KnowledgePhysicalBudgetPort | undefined = this.physical;
    if (assets === undefined || identity === undefined || physical === undefined || snapshot.documentId !== job.documentId || snapshot.generation !== job.generation || snapshot.original.assetId !== job.originalAssetId || snapshot.hash !== job.snapshotHash || snapshot.coverage.hash !== job.reportHash) { throw new DocxFailure('PrepareBindingOrPorts','prepare'); }
    await docxVerifySnapshot(snapshot,identity,new KnowledgeCancellation());
    const expected: DocxChunk[] = await docxStructureChunks(snapshot,identity,new KnowledgeCancellation()); if (JSON.stringify(chunks) !== JSON.stringify(expected)) { throw new DocxFailure('PreparedChunksMismatch','prepare'); }
    const wire: string = JSON.stringify(snapshot); const reserved: number = pdfCodecUtf8(wire).length*3+chunks.length*12288+1048576;
    const usage: KnowledgeDerivedUsage = await physical.usage(); const asset: string = 'snapshot-'+job.generation; const reserve: string = 'prepare-'+job.id;
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJob(tx,job);
      const rows: relationalStore.ResultSet = await tx.querySql("SELECT COALESCE((SELECT SUM(bytes) FROM kb_docx_reservation WHERE state='Reserved'),0)+COALESCE((SELECT SUM(bytes) FROM kb_image_reservation WHERE state='Reserved'),0)+COALESCE((SELECT SUM(reserved) FROM kb_derived_reservation WHERE state='Reserved'),0)");
      try { if (!rows.goToNextRow() || usage.total()-usage.pendingReserved+docxStoredNumber(rows,0)+reserved > 500*1024*1024) { throw new DocxFailure('SharedDerivedBudget','prepare'); } } finally { rows.close(); }
      const prior: relationalStore.ResultSet = await tx.querySql('SELECT owner,hash,generation FROM kb_docx_asset WHERE id=?',[asset]); let exists: boolean = false;
      try { if (prior.goToNextRow()) { exists = true; if (prior.getString(0) !== 'DocxSnapshotAssets' || prior.getString(1) !== snapshot.hash || prior.getString(2) !== job.generation) { throw new DocxFailure('SnapshotOwnerConflict','prepare'); } } } finally { prior.close(); }
      await tx.execute('INSERT OR REPLACE INTO kb_docx_reservation VALUES(?,?,?,?)',[reserve,job.id,reserved,'Reserved']);
      if (!exists) { await tx.execute('INSERT INTO kb_docx_asset VALUES(?,?,?,?,?,?,?,?)',[asset,job.documentId,'DocxSnapshotAssets',snapshot.hash,pdfCodecUtf8(wire).length,job.generation,'SnapshotPreparing',1]); }
    });
    try {
      if (await assets.save(snapshot,new KnowledgeCancellation()) !== asset) { throw new DocxFailure('AssetPublicationIdentity','prepare'); }
      await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
        await this.assertJob(tx,job); await docxPublicationBudget(tx,job.documentId,chunks.length);
        await tx.execute('DELETE FROM kb_docx_chunk WHERE generation=?',[job.generation]);
        for (const c of chunks) { await tx.execute('INSERT INTO kb_docx_chunk VALUES(?,?,?,?,?,?,?,?)',[c.id,c.documentId,c.generation,c.ordinal,c.text,c.embeddingText,c.inputHash,JSON.stringify(c.locator)]); }
        await tx.execute('UPDATE kb_docx_generation SET state=?,asset=?,hash=?,report=?,expected=? WHERE id=? AND state=?',['Prepared',asset,snapshot.hash,snapshot.coverage.hash,chunks.length,job.generation,'Staging']);
        await tx.execute('UPDATE kb_docx_original SET main_part=? WHERE asset=? AND hash=? AND version=?',[snapshot.original.mainPart,snapshot.original.assetId,snapshot.original.hash,snapshot.original.version]);
        await tx.execute("UPDATE kb_docx_asset SET role='Snapshot' WHERE id=? AND owner='DocxSnapshotAssets'",[asset]);
        await tx.execute('UPDATE kb_docx_job SET snapshot=?,report=?,stage=?,checkpoint=? WHERE id=?',[snapshot.hash,snapshot.coverage.hash,DocxStage.Review,DocxStage.Review,job.id]);
      });
    } finally { await this.write(async (tx: relationalStore.Transaction): Promise<void> => { await tx.execute('DELETE FROM kb_docx_reservation WHERE id=? AND owner=?',[reserve,job.id]); }); }
  }
  async publish(job: DocxJob, reportHash: string): Promise<boolean> {
    const snapshot: DocxSnapshot = await this.snapshot(job.generation); const chunks: DocxChunk[] = await this.chunks(job.generation); let published: boolean = false;
    if (snapshot.hash !== job.snapshotHash || snapshot.coverage.hash !== reportHash || reportHash !== job.reportHash) { return false; }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJob(tx,job); await docxPublicationBudget(tx,job.documentId,chunks.length);
      const rows: relationalStore.ResultSet = await tx.querySql("SELECT expected FROM kb_docx_generation WHERE id=? AND original=? AND doc=? AND epoch=? AND state='Prepared' AND hash=? AND report=?",[job.generation,job.originalAssetId,job.documentId,job.epoch,snapshot.hash,reportHash]);
      try { if (!rows.goToNextRow() || rows.getLong(0) !== chunks.length) { throw new DocxFailure('PublishCandidateChanged','publish'); } } finally { rows.close(); }
      const stage: DocxStage = chunks.length === 0 ? DocxStage.Empty : snapshot.coverage.partial ? DocxStage.Partial : DocxStage.Published;
      await tx.execute("UPDATE kb_docx_generation SET state='Retained' WHERE doc=? AND state='Active'",[job.documentId]);
      await tx.execute("UPDATE kb_docx_generation SET state='Active' WHERE id=?",[job.generation]);
      await tx.execute("UPDATE kb_docx_vector SET state='Retained' WHERE doc=? AND state='SemanticReady'",[job.documentId]);
      await tx.execute("UPDATE kb_docx_vector_mirror SET state='Invalid',revision=revision+1 WHERE doc=?",[job.documentId]);
      await tx.execute('UPDATE kb_docx_document SET active_original=?,active_generation=?,chunks=?,stage=?,title=?,epoch=epoch+1 WHERE id=?',[job.originalAssetId,job.generation,chunks.length,stage,snapshot.original.title,job.documentId]);
      await tx.execute('UPDATE kb_docx_job SET stage=?,checkpoint=? WHERE id=?',[stage,stage,job.id]); published = true;
    }); return published;
  }
  async documentForSource(source: string): Promise<DocxDocument | undefined> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT DISTINCT doc FROM kb_docx_original WHERE source=?',[source]); let id: string = '';
    try { if (rows.goToNextRow()) { id = rows.getString(0); if (rows.goToNextRow()) { throw new DocxFailure('SourceOwnerAmbiguous','read'); } } } finally { rows.close(); } return id.length === 0 ? undefined : this.get(id);
  }
  async visible(hit: KnowledgeHit, archived: boolean): Promise<boolean> {
    const d: DocxDocument | undefined = await this.get(hit.documentId); if (d === undefined || d.tombstone || !archived && d.archived || d.activeGeneration !== hit.generation || d.epoch !== hit.epoch) { return false; }
    const o: DocxOriginal = await this.original(d.activeOriginal); return hit.originalHash === o.hash && hit.originalVersion === o.version;
  }
  async makeHit(document: DocxDocument, chunk: DocxChunk, snapshot: DocxSnapshot): Promise<KnowledgeHit> {
    const hit: KnowledgeHit = new KnowledgeHit(); hit.id = 'docx:'+chunk.id; hit.documentId = document.id; hit.chunkId = chunk.id; hit.sourceKind = KnowledgeSourceKind.Docx; hit.actualFormat = 'DOCX'; hit.title = document.title; hit.text = chunk.text; hit.retrievalText = chunk.text; hit.generation = chunk.generation; hit.snapshotId = snapshot.generation; hit.snapshotHash = snapshot.hash; hit.originalHash = snapshot.original.hash; hit.originalVersion = snapshot.original.version; hit.epoch = document.epoch; hit.locator.kind = KnowledgeSourceKind.Docx; hit.locator.docx = chunk.locator; hit.channels = [KnowledgeChannel.Keyword]; return hit;
  }
  async directCandidates(input: TextQueryInput, archived: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeHit[]> {
    const hits: KnowledgeHit[] = []; let count: number = 0;
    for (const document of await this.list()) {
      cancel.check(); if (document.tombstone || !archived && document.archived || document.activeGeneration.length === 0) { continue; }
      const snapshot: DocxSnapshot = await this.snapshot(document.activeGeneration); const chunks: DocxChunk[] = await this.chunks(document.activeGeneration);
      if (chunks.length !== document.chunkCount || snapshot.original.assetId !== document.activeOriginal) { throw new DocxFailure('ActiveChunkCoverageIncomplete','scan'); }
      for (const c of chunks) { if (++count > 10000) { throw new DocxFailure('ActiveChunkBudget','scan'); } const score: number = knowledgeLiteralScore(c.text,input); if (score > 0) { const hit: KnowledgeHit = await this.makeHit(document,c,snapshot); hit.keywordScore = score; hits.push(hit); } }
    } return hits;
  }
}
