import { relationalStore } from '@kit.ArkData';
import {
  ParsedDocument, ParsedDocumentRecord, ParsedTextChunk, ParsedImageAsset, ParsedAssetRef, ParsedAssetWrite,
  ParsedReadLease, ParsedLegacyLink, ParsedAssetState, ParsedLimits, ParsedFailure, ParsedCancellation, parsedId, parsedHash
} from '../domain/ParsedDocumentModels';
import { ParsedRepositoryPort, ParsedIdentityPort, ParsedPhysicalUsagePort, ParsedPublicationVerificationPort } from '../domain/ParsedDocumentPorts';
import {
  UnifiedProcessingSettings, UnifiedProcessingGrant, UnifiedProcessingBatch, UnifiedProcessingJob, UnifiedProcessingAttempt,
  UnifiedEffectiveAnnotation, UnifiedHistoryRevision, UnifiedIndexBinding, UnifiedInputKind, UnifiedJobOrigin, UnifiedJobState, UnifiedBindingState,
  UNIFIED_TEXT_POLICY, UNIFIED_HISTORY_WIRE
} from '../domain/UnifiedKnowledgeModels';
import { UnifiedImageRecord, UnifiedTextInput } from '../domain/UnifiedKnowledgeModels';
import { UnifiedProcessingRepositoryPort } from '../domain/UnifiedProcessingPorts';
import { unifiedAnnotation, unifiedInput, unifiedAttempt } from '../pipeline/UnifiedProcessingCodec';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { parsedOpenLayout } from './ParsedDocumentStoreLayout';
import { parsedValidate, parsedUtf8, parsedJson, parsedDecodeAsset } from '../pipeline/ParsedDocumentCodec';
import { PdfJsonNode } from '../pipeline/BoundedDocumentJson';
import { parsedPublicationBudget } from './ParsedPublicationBudget';
import { parsedChunkSourceText } from '../pipeline/ParsedDocumentChunker';
import { ParsedMigrationInput, ParsedMigrationBatch, ParsedMigrationReceipt, ParsedMigrationStorePort, ParsedUpgradeBatch, ParsedUpgradeTarget } from '../domain/ParsedMigrationModels';
import { migrationDecodeBatch, migrationDecodeReceipt, upgradeDecodeBatch } from '../pipeline/ParsedMigrationCodec';
import { migrationAssertLegacy, migrationCheckInput, migrationCommitLink } from './ParsedMigrationStore';
import { ParsedLifecycleRepositoryPort } from '../domain/ParsedLifecyclePorts';

function recordFrom(rows: relationalStore.ResultSet): ParsedDocumentRecord {
  const d: ParsedDocumentRecord = new ParsedDocumentRecord(); d.id = rows.getString(0); d.namespace = rows.getString(1); d.legacyId = rows.getString(2);
  d.title = rows.getString(3); d.epoch = rows.getLong(4); d.activeGeneration = rows.getString(5); d.sourceHash = rows.getString(6);
  d.archived = rows.getLong(7) === 1; d.tombstone = rows.getLong(8) === 1; return d;
}
function writeFrom(rows: relationalStore.ResultSet): ParsedAssetWrite {
  const w: ParsedAssetWrite = new ParsedAssetWrite(); w.id = rows.getString(0); w.documentKey = rows.getString(1); w.generation = rows.getString(2);
  w.role = rows.getString(3); w.hash = rows.getString(4); w.bytes = rows.getLong(5); w.relativePath = rows.getString(6); w.phase = rows.getString(7);
  w.reserved = rows.getLong(8); w.failure = rows.getString(9); return w;
}
function nodeString(n: PdfJsonNode, key: string): string { return n.required(key).string(); }
function nodeNumber(n: PdfJsonNode, key: string): number { return n.required(key).integer(); }
function nodeBoolean(n: PdfJsonNode, key: string): boolean { const b: PdfJsonNode = n.required(key); if (b.kind !== 'true' && b.kind !== 'false') { throw new ParsedFailure('StoredBoolean','upd-read'); } return b.kind === 'true'; }
function jobOrigin(s: string): UnifiedJobOrigin {
  const origin: UnifiedJobOrigin | undefined = [UnifiedJobOrigin.Import,UnifiedJobOrigin.LocalMigration,UnifiedJobOrigin.ExplicitUpgrade].find((v: UnifiedJobOrigin): boolean => v === s);
  if (origin === undefined) { throw new ParsedFailure('JobOrigin','upd-read'); } return origin;
}
function jobState(s: string): UnifiedJobState {
  const state: UnifiedJobState | undefined = [UnifiedJobState.AwaitingConfig,UnifiedJobState.Pending,UnifiedJobState.Running,UnifiedJobState.Paused,UnifiedJobState.Unknown,UnifiedJobState.Complete,UnifiedJobState.Failed,UnifiedJobState.Canceled].find((v: UnifiedJobState): boolean => v === s);
  if (state === undefined) { throw new ParsedFailure('JobState','upd-read'); } return state;
}
export class ParsedDocumentRepository implements ParsedRepositoryPort, UnifiedProcessingRepositoryPort, ParsedMigrationStorePort, ParsedLifecycleRepositoryPort {
  private host: KnowledgeStoreHost; private identity: ParsedIdentityPort; private opened: boolean = false;
  private opening: Promise<void> | undefined;
  private physical: ParsedPhysicalUsagePort | undefined;
  private publication: ParsedPublicationVerificationPort | undefined;
  constructor(host: KnowledgeStoreHost, identity: ParsedIdentityPort) { this.host = host; this.identity = identity; }
  attachPhysicalBudget(budget: ParsedPhysicalUsagePort): void { this.physical = budget; }
  attachPublicationVerifier(verifier: ParsedPublicationVerificationPort): void { this.publication = verifier; }
  ready(): boolean { return this.opened && this.host.unifiedReady; }
  private store(): relationalStore.RdbStore { if (!this.ready()) { throw new ParsedFailure('StoreUnavailable','upd'); } return this.host.requireStore(); }
  private write<T>(action: () => Promise<T>): Promise<T> { return this.host.enqueue<T>(action); }
  async open(): Promise<void> {
    if (this.ready()) { return; }
    if (this.opening === undefined) { this.opening = this.openOnce(); }
    try { await this.opening; } finally { this.opening = undefined; }
  }
  private async openOnce(): Promise<void> {
    if (this.ready()) { return; } await this.host.acquireExtension();
    try {
      await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => { await parsedOpenLayout(tx,this.identity); }); this.host.unifiedReady = true; this.opened = true; });
    } catch (error) { this.host.unifiedReady = false; await this.host.release(); if (error instanceof Error) { throw error; } throw new ParsedFailure('LayoutRejected','upd-open'); }
  }
  async close(): Promise<void> { if (this.opening !== undefined) { await this.opening; } if (!this.opened) { return; } await this.host.release(); this.opened = false; }
  async get(id: string): Promise<ParsedDocumentRecord | undefined> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM upd_document WHERE id=?',[id]);
    try { return rows.goToNextRow() ? recordFrom(rows) : undefined; } finally { rows.close(); }
  }
  async list(): Promise<ParsedDocumentRecord[]> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM upd_document ORDER BY id'); const out: ParsedDocumentRecord[] = [];
    try { while (rows.goToNextRow()) { out.push(recordFrom(rows)); } } finally { rows.close(); } return out;
  }
  async register(record: ParsedDocumentRecord): Promise<void> {
    if (!parsedId(record.id) || record.namespace.length === 0 || record.legacyId.length === 0 || !parsedHash(record.sourceHash) || !Number.isSafeInteger(record.epoch) || record.epoch < 0 || record.activeGeneration.length > 0 || record.tombstone) { throw new ParsedFailure('DocumentIdentity','upd-register'); }
    await this.write<void>(async (): Promise<void> => {
      const old: ParsedDocumentRecord | undefined = await this.get(record.id);
      if (old !== undefined) { if (old.namespace !== record.namespace || old.legacyId !== record.legacyId || old.sourceHash !== record.sourceHash) { throw new ParsedFailure('DocumentIdentityConflict','upd-register'); } return; }
      await this.store().executeSql('INSERT INTO upd_document VALUES(?,?,?,?,?,?,?,?,?)',[record.id,record.namespace,record.legacyId,record.title,record.epoch,'',record.sourceHash,record.archived ? 1 : 0,0]);
    });
  }
  async publish(document: ParsedDocument, chunks: ParsedTextChunk[], manifestId: string, contentHash: string, expectedEpoch: number, expectedOld: string, legacy?: ParsedLegacyLink): Promise<boolean> {
    parsedValidate(document);
    if (chunks.length > ParsedLimits.chunks || !parsedHash(contentHash)) { throw new ParsedFailure('PublicationBudgetOrHash','upd-publish'); }
    const verification: ParsedPublicationVerificationPort | undefined = this.publication;
    if (verification === undefined) { throw new ParsedFailure('SnapshotVerificationUnavailable','upd-publish'); }
    await verification.verifyPublication(document,manifestId,contentHash);
    const ids: Set<string> = new Set<string>();
    for (let i: number = 0; i < chunks.length; i++) {
      const c: ParsedTextChunk = chunks[i];
      if (!parsedId(c.id) || ids.has(c.id) || c.documentKey !== document.documentKey || c.generation !== document.generation || c.ordinal !== i ||
        c.text.trim().length === 0 || c.start < 0 || c.end <= c.start || c.end-c.start !== c.text.length || parsedChunkSourceText(document,c).slice(c.start,c.end) !== c.text || ['Body','Ocr','Formula'].indexOf(c.evidence) < 0 || !parsedHash(c.inputHash) || await this.identity.hash(parsedUtf8(c.text)) !== c.inputHash) { throw new ParsedFailure('ChunkIdentity','upd-publish'); } ids.add(c.id);
    }
    let published: boolean = false;
    await this.write<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      if (legacy!==undefined) { await migrationAssertLegacy(tx,legacy.namespace,legacy.legacyId,legacy.oldActive,legacy.epoch,document.source_hash); }
      const d: relationalStore.ResultSet = await tx.querySql('SELECT epoch,active,source_hash,tombstone,namespace,legacy_id FROM upd_document WHERE id=?',[document.documentKey]);
      try { if (!d.goToNextRow() || d.getLong(0) !== expectedEpoch || d.getString(1) !== expectedOld || legacy===undefined && d.getString(2) !== document.source_hash || d.getLong(3) !== 0 || legacy!==undefined && (d.getString(4)!=='Legacy:'+legacy.namespace || d.getString(5)!==legacy.legacyId || legacy.documentKey!==document.documentKey || legacy.generation!==document.generation)) { return; } } finally { d.close(); }
      const manifest: ParsedAssetWrite | undefined = await this.assetWrite(manifestId);
      if (manifest === undefined || manifest.phase !== 'Ready' || manifest.documentKey !== document.documentKey || manifest.generation !== document.generation || manifest.role !== 'manifest') { throw new ParsedFailure('SnapshotNotReady','upd-publish'); }
      const prior: relationalStore.ResultSet = await tx.querySql('SELECT id FROM upd_generation WHERE id=?',[document.generation]);
      try { if (prior.goToNextRow()) { throw new ParsedFailure('GenerationAlreadyExists','upd-publish'); } } finally { prior.close(); }
      if (legacy!==undefined) { await migrationCommitLink(tx,legacy); }
      await parsedPublicationBudget(tx,document.documentKey,chunks.length);
      await tx.execute('INSERT INTO upd_generation VALUES(?,?,?,?,?,?,?,?)',[document.generation,document.documentKey,expectedEpoch,manifestId,contentHash,document.source_hash,chunks.length,'Staging']);
      const snapshotParts: relationalStore.ResultSet = await tx.querySql("SELECT id FROM upd_asset_write WHERE doc=? AND generation=? AND phase='Ready' AND role IN ('payload','manifest')",[document.documentKey,document.generation]);
      const snapshotIds: string[] = [];
      try { while (snapshotParts.goToNextRow()) { snapshotIds.push(snapshotParts.getString(0)); } } finally { snapshotParts.close(); }
      for (const id of snapshotIds) {
        await tx.execute('INSERT OR IGNORE INTO upd_asset_ref VALUES(?,?,?,?,?,?)',[document.generation,document.documentKey,document.generation,id,'ParsedDocumentAssets','snapshot']);
        await tx.execute("DELETE FROM upd_asset_ref WHERE holder=? AND owner='ParsedDocumentAssets' AND asset=?",[`write-${id}`,id]);
      }
      for (const a of document.images) {
        if (a.state !== ParsedAssetState.Ready) { continue; } const current: ParsedImageAsset | undefined = await this.asset(a.id);
        if (current === undefined || current.state !== ParsedAssetState.Ready || current.payloadHash !== a.payloadHash || current.bytes !== a.bytes) { throw new ParsedFailure('ImageNotReady','upd-publish'); }
      }
      for (const o of document.occurrences) {
        const previous: relationalStore.ResultSet=await tx.querySql('SELECT o.lineage,o.effective,o.metadata FROM upd_image_occurrence o JOIN upd_asset a ON a.id=o.asset WHERE o.doc=? AND o.generation=? AND a.hash=? ORDER BY o.id',[document.documentKey,expectedOld,document.images.find((a: ParsedImageAsset): boolean=>a.id===o.assetId)?.payloadHash ?? '']);
        let inheritedLineage: string=o.annotationLineage; let inheritedEffective: string=o.effectiveAnnotationId; const compatible: string[]=[];
        try { while (previous.goToNextRow()) { const raw=parsedJson(parsedUtf8(previous.getString(2)),new ParsedCancellation()); if (raw.required('member').string()===o.member && raw.required('provenance').string()===o.provenance && raw.required('blockId').string()===o.blockId && raw.required('inlineId').string()===o.inlineId) { compatible.push(previous.getString(0)+'|'+previous.getString(1)); } } } finally { previous.close(); }
        if (compatible.length===1) { const fields=compatible[0].split('|'); inheritedLineage=fields[0]; inheritedEffective=fields[1]; }
        await tx.execute('INSERT INTO upd_image_occurrence VALUES(?,?,?,?,?,?,?)',[o.id,document.documentKey,document.generation,o.assetId,inheritedLineage,inheritedEffective,JSON.stringify(o)]);
        if (o.assetId.length > 0 && document.images.some((a: ParsedImageAsset): boolean => a.id === o.assetId && a.state === ParsedAssetState.Ready)) {
          await tx.execute('INSERT OR IGNORE INTO upd_asset_ref VALUES(?,?,?,?,?,?)',[document.generation,document.documentKey,document.generation,o.assetId,'ParsedDocumentAssets','image']);
          await tx.execute("DELETE FROM upd_asset_ref WHERE holder=? AND owner='ParsedDocumentAssets' AND asset=?",[`write-${o.assetId}`,o.assetId]);
        }
      }
      for (const c of chunks) { await tx.execute('INSERT INTO upd_chunk VALUES(?,?,?,?,?,?,?,?,?,?,?)',[c.id,c.documentKey,c.generation,c.ordinal,c.text,c.inputHash,c.blockId,c.occurrenceId,c.evidence,c.start,c.end]); }
      const readback: relationalStore.ResultSet = await tx.querySql('SELECT id,text,input_hash FROM upd_chunk WHERE generation=? ORDER BY ordinal',[document.generation]); let at: number = 0;
      try { while (readback.goToNextRow()) { const c: ParsedTextChunk | undefined = chunks[at++]; if (c === undefined || readback.getString(0) !== c.id || readback.getString(1) !== c.text || readback.getString(2) !== c.inputHash) { throw new ParsedFailure('KeywordReadback','upd-publish'); } } } finally { readback.close(); }
      if (at !== chunks.length) { throw new ParsedFailure('KeywordReadbackCount','upd-publish'); }
      await tx.execute("UPDATE upd_generation SET state='Retained' WHERE doc=? AND state='Active'",[document.documentKey]);
      await tx.execute("UPDATE upd_generation SET state='Active' WHERE id=?",[document.generation]);
      await tx.execute('UPDATE upd_document SET active=?,source_hash=?,archived=CASE WHEN ?=1 THEN ? ELSE archived END WHERE id=? AND epoch=? AND active=? AND tombstone=0',[document.generation,document.source_hash,legacy===undefined?0:1,legacy?.archived===true?1:0,document.documentKey,expectedEpoch,expectedOld]); published = true;
      if (expectedOld.length>0) { await tx.execute("UPDATE upd_index_binding SET state='Invalid' WHERE namespace='upd-body' AND owner=? AND version<>?",[document.documentKey,document.generation]); }
      await this.reconcileOwnersTx(tx);
    }); }); return published;
  }
  async chunks(id: string): Promise<ParsedTextChunk[]> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT c.* FROM upd_chunk c JOIN upd_document d ON d.id=c.doc AND d.active=c.generation WHERE d.id=? AND d.tombstone=0 ORDER BY ordinal',[id]); const out: ParsedTextChunk[] = [];
    try { while (rows.goToNextRow()) {
      const c: ParsedTextChunk = new ParsedTextChunk(); c.id = rows.getString(0); c.documentKey = rows.getString(1); c.generation = rows.getString(2); c.ordinal = rows.getLong(3); c.text = rows.getString(4); c.inputHash = rows.getString(5);
      c.blockId = rows.getString(6); c.occurrenceId = rows.getString(7); c.evidence = rows.getString(8); c.start = rows.getLong(9); c.end = rows.getLong(10); out.push(c);
    } } finally { rows.close(); } return out;
  }
  async reserve(write: ParsedAssetWrite, asset: ParsedImageAsset): Promise<void> {
    const maximum: number = write.role === 'image' ? ParsedLimits.imageBytes : write.role === 'manifest' ? ParsedLimits.manifestBytes : ParsedLimits.payloadBytes;
    if (!parsedId(write.id) || write.id !== asset.id || !parsedId(write.documentKey) || !parsedId(write.generation) || !parsedHash(write.hash) || write.bytes < 1 || !Number.isSafeInteger(write.bytes) ||
      write.bytes > maximum || ['image','payload','manifest','annotation','history'].indexOf(write.role) < 0 ||
      asset.owner !== 'ParsedDocumentAssets' || write.relativePath !== asset.relativePath || asset.payloadHash !== write.hash || asset.bytes !== write.bytes || asset.state !== ParsedAssetState.Reserved ||
      !new RegExp('^(images|snapshots|annotations|history)/[A-Za-z0-9_-]+$').test(write.relativePath) || !write.relativePath.endsWith('/'+write.id)) { throw new ParsedFailure('WriteIdentity','upd-reserve'); }
    await this.write<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const old: ParsedAssetWrite | undefined = await this.assetWrite(write.id);
      if (old !== undefined) {
        if (old.documentKey !== write.documentKey || old.generation !== write.generation || old.hash !== write.hash || old.bytes !== write.bytes || old.relativePath !== write.relativePath || old.role !== write.role || old.phase === 'Removed') { throw new ParsedFailure('WriteIdentityConflict','upd-reserve'); } return;
      }
      const d: ParsedDocumentRecord | undefined = await this.get(write.documentKey);
      if ((d === undefined || d.tombstone) && write.role!=='history') { throw new ParsedFailure('WriteOwnerUnavailable','upd-reserve'); }
      const generation: relationalStore.ResultSet = await tx.querySql("SELECT COALESCE(SUM(bytes),0) FROM upd_asset_write WHERE generation=? AND phase<>'Removed'",[write.generation]);
      try { if (!generation.goToNextRow() || generation.getLong(0)+write.bytes > ParsedLimits.generationBytes) { throw new ParsedFailure('GenerationPhysicalBudget','upd-reserve'); } } finally { generation.close(); }
      const budget: ParsedPhysicalUsagePort | undefined = this.physical;
      if (budget === undefined) { throw new ParsedFailure('PhysicalBudgetUnavailable','upd-reserve'); }
      if (await budget.totalBytes()+Math.ceil(write.bytes/4096)*4096+8192 > ParsedLimits.sharedBytes) { throw new ParsedFailure('SharedPhysicalBudget','upd-reserve'); }
      write.reserved = Math.ceil(write.bytes/4096)*4096; write.phase = 'Reserved';
      await tx.execute('INSERT INTO upd_asset VALUES(?,?,?,?,?,?,?)',[asset.id,asset.owner,asset.relativePath,asset.payloadHash,asset.bytes,asset.state,JSON.stringify(asset)]);
      await tx.execute('INSERT INTO upd_asset_write VALUES(?,?,?,?,?,?,?,?,?,?)',[write.id,write.documentKey,write.generation,write.role,write.hash,write.bytes,write.relativePath,write.phase,write.reserved,'']);
      // The write itself owns its candidate until a content generation takes over.
      await tx.execute('INSERT INTO upd_asset_ref VALUES(?,?,?,?,?,?)',[`write-${write.id}`,write.documentKey,write.generation,write.id,asset.owner,'write']);
    }); });
  }
  async assetWrite(id: string): Promise<ParsedAssetWrite | undefined> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM upd_asset_write WHERE id=?',[id]); try { return rows.goToNextRow() ? writeFrom(rows) : undefined; } finally { rows.close(); }
  }
  async assetWrites(): Promise<ParsedAssetWrite[]> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM upd_asset_write ORDER BY id'); const out: ParsedAssetWrite[] = [];
    try { while (rows.goToNextRow()) { out.push(writeFrom(rows)); } } finally { rows.close(); } return out;
  }
  async asset(id: string): Promise<ParsedImageAsset | undefined> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT metadata,state FROM upd_asset WHERE id=?',[id]);
    try { if (!rows.goToNextRow()) { return undefined; } const a: ParsedImageAsset = parsedDecodeAsset(parsedJson(parsedUtf8(rows.getString(0)),new ParsedCancellation()));
      const state: string = rows.getString(1); const s: ParsedAssetState | undefined = [ParsedAssetState.Reserved,ParsedAssetState.Ready,ParsedAssetState.Missing,ParsedAssetState.Unsupported,ParsedAssetState.Removed].find((v: ParsedAssetState): boolean => v === state);
      if (s === undefined) { throw new ParsedFailure('StoredAssetState','upd-read'); } a.state = s; return a;
    } finally { rows.close(); }
  }
  async materialized(id: string): Promise<void> {
    await this.write<void>(async (): Promise<void> => { await this.store().executeSql("UPDATE upd_asset_write SET phase='Materialized',reserved=0 WHERE id=? AND phase IN ('Reserved','Materialized','Missing')",[id]); });
  }
  async restoreReservation(id: string, materializedBytes: number): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      const w: ParsedAssetWrite | undefined = await this.assetWrite(id);
      if (w === undefined || w.phase === 'Removed' || !Number.isSafeInteger(materializedBytes) || materializedBytes < 0) { throw new ParsedFailure('ReservationIdentity','upd-reserve'); }
      const allocation: number = Math.ceil(w.bytes/4096)*4096;
      if (materializedBytes > allocation) { throw new ParsedFailure('ReservationPhysicalConflict','upd-reserve'); }
      const physical: ParsedPhysicalUsagePort | undefined = this.physical;
      if (physical === undefined) { throw new ParsedFailure('PhysicalBudgetUnavailable','upd-reserve'); }
      const additional: number = Math.max(0,allocation-materializedBytes)-Math.max(0,w.reserved-materializedBytes);
      if (await physical.totalBytes()+additional > ParsedLimits.sharedBytes) { throw new ParsedFailure('SharedPhysicalBudget','upd-reserve'); }
      await this.store().executeSql('UPDATE upd_asset_write SET reserved=? WHERE id=?',[allocation,id]);
    });
  }
  async commitAsset(id: string): Promise<void> {
    await this.write<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const w: ParsedAssetWrite | undefined = await this.assetWrite(id); if (w === undefined || ['Materialized','Renamed','Ready'].indexOf(w.phase) < 0) { throw new ParsedFailure('WriteNotMaterialized','upd-commit'); }
      await tx.execute("UPDATE upd_asset_write SET phase='Ready',reserved=0,failure='' WHERE id=?",[id]); await tx.execute("UPDATE upd_asset SET state='Ready' WHERE id=?",[id]);
    }); });
  }
  async assetMissing(id: string, reason: string): Promise<void> {
    await this.write<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      await tx.execute("UPDATE upd_asset SET state='Missing' WHERE id=?",[id]); await tx.execute("UPDATE upd_asset_write SET phase='Missing',failure=? WHERE id=?",[reason,id]);
    }); });
  }
  async addRef(ref: ParsedAssetRef): Promise<void> {
    if (!parsedId(ref.holder) || !parsedId(ref.assetId) || !parsedId(ref.documentKey) || ref.owner.length === 0) { throw new ParsedFailure('ReferenceIdentity','upd-ref'); }
    await this.write<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const d: ParsedDocumentRecord | undefined = await this.get(ref.documentKey); if (d === undefined || d.tombstone) { throw new ParsedFailure('ReferenceOwnerDeleted','upd-ref'); }
      const claim: relationalStore.ResultSet = await tx.querySql('SELECT asset FROM upd_cleanup WHERE asset=? AND owner=?',[ref.assetId,ref.owner]);
      try { if (claim.goToNextRow()) { throw new ParsedFailure('AssetCleanupClaimed','upd-ref'); } } finally { claim.close(); }
      if (ref.owner === 'ParsedDocumentAssets') { const a: ParsedImageAsset | undefined = await this.asset(ref.assetId); if (a === undefined || a.state === ParsedAssetState.Removed) { throw new ParsedFailure('ReferencedAssetMissing','upd-ref'); } }
      const existing: relationalStore.ResultSet = await tx.querySql('SELECT doc,generation,role FROM upd_asset_ref WHERE holder=? AND owner=? AND asset=?',[ref.holder,ref.owner,ref.assetId]);
      try { if (existing.goToNextRow()) { if (existing.getString(0) !== ref.documentKey || existing.getString(1) !== ref.generation || existing.getString(2) !== ref.role) { throw new ParsedFailure('ReferenceConflict','upd-ref'); } return; } } finally { existing.close(); }
      await tx.execute('INSERT INTO upd_asset_ref VALUES(?,?,?,?,?,?)',[ref.holder,ref.documentKey,ref.generation,ref.assetId,ref.owner,ref.role]);
    }); });
  }
  async releaseRefs(holder: string): Promise<void> { await this.write<void>(async (): Promise<void> => { await this.store().executeSql('DELETE FROM upd_asset_ref WHERE holder=?',[holder]); }); }
  async acquireLease(lease: ParsedReadLease): Promise<void> {
    if (!parsedId(lease.id) || lease.session.length === 0 || lease.holder.length === 0) { throw new ParsedFailure('LeaseIdentity','upd-lease'); }
    await this.write<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const claim: relationalStore.ResultSet = await tx.querySql('SELECT asset FROM upd_cleanup WHERE asset=? AND owner=?',[lease.assetId,lease.owner]);
      try { if (claim.goToNextRow()) { throw new ParsedFailure('AssetCleanupClaimed','upd-lease'); } } finally { claim.close(); }
      if (lease.owner === 'ParsedDocumentAssets') { const a: ParsedImageAsset | undefined = await this.asset(lease.assetId); if (a?.state !== ParsedAssetState.Ready) { throw new ParsedFailure('AssetNotReady','upd-lease'); } }
      const exists: relationalStore.ResultSet = await tx.querySql('SELECT asset,owner,session,holder FROM upd_read_lease WHERE id=?',[lease.id]);
      try { if (exists.goToNextRow()) { if (exists.getString(0) !== lease.assetId || exists.getString(1) !== lease.owner || exists.getString(2) !== lease.session || exists.getString(3) !== lease.holder) { throw new ParsedFailure('LeaseConflict','upd-lease'); } return; } } finally { exists.close(); }
      await tx.execute('INSERT INTO upd_read_lease VALUES(?,?,?,?,?)',[lease.id,lease.assetId,lease.owner,lease.session,lease.holder]);
    }); });
  }
  async releaseLease(id: string): Promise<void> { await this.write<void>(async (): Promise<void> => { await this.store().executeSql("UPDATE upd_read_lease SET holder='ReleasePending' WHERE id=?",[id]); await this.store().executeSql('DELETE FROM upd_read_lease WHERE id=?',[id]); }); }
  async heldLegacyAssets(owner: string): Promise<string[]> { this.store(); return this.host.unifiedHeldAssets(owner); }
  async assertLegacyUnheld(owner: string, assets: string[]): Promise<void> { this.store(); await this.host.assertUnifiedUnheld(owner,assets); }
  async claimAssetCleanup(id: string): Promise<boolean> {
    let claim: boolean = false;
    await this.write<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const rows: relationalStore.ResultSet = await tx.querySql("SELECT id FROM upd_asset a WHERE a.id=? AND a.owner='ParsedDocumentAssets' AND a.state<>'Removed' AND NOT EXISTS(SELECT 1 FROM upd_asset_ref r WHERE r.asset=a.id AND r.owner=a.owner) AND NOT EXISTS(SELECT 1 FROM upd_read_lease l WHERE l.asset=a.id AND l.owner=a.owner) AND NOT EXISTS(SELECT 1 FROM upd_read_lease l JOIN upd_asset_write w ON w.id=l.asset WHERE l.owner=a.owner AND l.holder='snapshot-read' AND w.generation=(SELECT generation FROM upd_asset_write WHERE id=a.id))",[id]);
      try { if (!rows.goToNextRow()) { return; } } finally { rows.close(); }
      await tx.execute("INSERT OR REPLACE INTO upd_cleanup VALUES(?,'ParsedDocumentAssets','Claimed','')",[id]); claim = true;
    }); }); return claim;
  }
  async finishAssetCleanup(id: string, failure: string): Promise<void> {
    await this.write<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const claim: relationalStore.ResultSet = await tx.querySql("SELECT asset FROM upd_cleanup WHERE asset=? AND owner='ParsedDocumentAssets' AND state='Claimed'",[id]);
      try { if (!claim.goToNextRow()) { throw new ParsedFailure('CleanupNotClaimed','upd-cleanup'); } } finally { claim.close(); }
      if (failure.length === 0) { await tx.execute("UPDATE upd_asset SET state='Removed' WHERE id=?",[id]); await tx.execute("UPDATE upd_asset_write SET phase='Removed',reserved=0 WHERE id=?",[id]); }
      await tx.execute('UPDATE upd_cleanup SET state=?,failure=? WHERE asset=?',[failure.length === 0 ? 'Done' : 'Pending',failure,id]);
    }); });
  }
  async saveLegacyLink(link: ParsedLegacyLink): Promise<void> {
    if (!parsedHash(link.legacyHash) || !parsedId(link.documentKey) || !parsedId(link.generation) || link.legacyWire.length === 0) { throw new ParsedFailure('LegacyIdentity','upd-link'); }
    await this.write<void>(async (): Promise<void> => {
      const rows: relationalStore.ResultSet = await this.store().querySql('SELECT legacy_wire,legacy_hash,doc,generation,epoch,old_active FROM upd_legacy_link WHERE namespace=? AND legacy_id=? AND legacy_generation=?',[link.namespace,link.legacyId,link.legacyGeneration]);
      try { if (rows.goToNextRow()) { if (rows.getString(0) !== link.legacyWire || rows.getString(1) !== link.legacyHash || rows.getString(2) !== link.documentKey || rows.getString(3) !== link.generation || rows.getLong(4) !== link.epoch || rows.getString(5) !== link.oldActive) { throw new ParsedFailure('LegacyLinkConflict','upd-link'); } return; } } finally { rows.close(); }
      await this.store().executeSql('INSERT INTO upd_legacy_link VALUES(?,?,?,?,?,?,?,?,?,?)',[link.namespace,link.legacyId,link.legacyGeneration,link.legacyWire,link.legacyHash,link.documentKey,link.generation,link.epoch,link.oldActive,link.state]);
    });
  }
  async settings(purpose: string): Promise<UnifiedProcessingSettings> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT metadata FROM upd_settings WHERE purpose=?',[purpose]); const s: UnifiedProcessingSettings = new UnifiedProcessingSettings(); s.purpose = purpose;
    try { if (!rows.goToNextRow()) { return s; } const n: PdfJsonNode = parsedJson(parsedUtf8(rows.getString(0)),new ParsedCancellation());
      s.purpose = nodeString(n,'purpose'); s.enabled = nodeBoolean(n,'enabled'); s.paused = nodeBoolean(n,'paused'); s.automatic = nodeBoolean(n,'automatic');
      s.recipient = nodeString(n,'recipient'); s.model = nodeString(n,'model'); s.credentialRevision = nodeNumber(n,'credentialRevision'); s.revision = nodeNumber(n,'revision');
      s.costAcknowledged = nodeBoolean(n,'costAcknowledged'); s.costRevision = nodeNumber(n,'costRevision'); s.policy = nodeString(n,'policy');
      s.imageScope = nodeString(n,'imageScope');
      s.configBinding = n.optional('configBinding')?.string() ?? ''; s.baselineAccepted = n.optional('baselineAccepted')?.kind==='true';
      for (const v of n.required('inputKinds').array()) { const k: string = v.string(); if (k === UnifiedInputKind.Body) { s.inputKinds.push(UnifiedInputKind.Body); } else if (k === UnifiedInputKind.Ocr) { s.inputKinds.push(UnifiedInputKind.Ocr); } else if (k === UnifiedInputKind.ImageProxy) { s.inputKinds.push(UnifiedInputKind.ImageProxy); } else { throw new ParsedFailure('InputKind','upd-settings'); } }
      if (s.purpose !== purpose) { throw new ParsedFailure('SettingsIdentity','upd-settings'); } return s;
    } finally { rows.close(); }
  }
  async saveSettings(s: UnifiedProcessingSettings): Promise<void> {
    if (!Number.isSafeInteger(s.revision) || !Number.isSafeInteger(s.costRevision) || !Number.isSafeInteger(s.credentialRevision) || s.revision < 1 || s.costRevision < 0 || s.credentialRevision < 0 || (s.enabled && (!s.costAcknowledged || !s.automatic || s.recipient.length === 0 || s.model.length === 0 || s.policy.length === 0 || s.costRevision < 1))) { throw new ParsedFailure('SettingsCostConsent','upd-settings'); }
    await this.write<void>(async (): Promise<void> => {
      const old: UnifiedProcessingSettings = await this.settings(s.purpose);
      if (old.revision >= s.revision) { if (JSON.stringify(old) !== JSON.stringify(s)) { throw new ParsedFailure('SettingsRevisionConflict','upd-settings'); } return; }
      await this.store().executeSql('INSERT OR REPLACE INTO upd_settings VALUES(?,?,?)',[s.purpose,s.revision,JSON.stringify(s)]);
    });
  }
  async saveGrant(g: UnifiedProcessingGrant): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      const rows: relationalStore.ResultSet = await this.store().querySql('SELECT revoked,consumed FROM upd_grant WHERE id=?',[g.id]);
      try { if (rows.goToNextRow() && ((rows.getLong(0) === 1 && !g.revoked) || (rows.getLong(1) === 1 && !g.consumed))) { throw new ParsedFailure('GrantCannotRevive','upd-grant'); } } finally { rows.close(); }
      await this.store().executeSql('INSERT OR REPLACE INTO upd_grant VALUES(?,?,?,?,?,?)',[g.id,g.settingsPurpose,g.settingsRevision,g.revoked ? 1 : 0,g.consumed ? 1 : 0,JSON.stringify(g)]);
    });
  }
  async saveBatch(b: UnifiedProcessingBatch): Promise<void> {
    if (!parsedId(b.id) || !parsedHash(b.inputSetHash) || b.inputIds.length > ParsedLimits.currentInputs || new Set<string>(b.inputIds).size !== b.inputIds.length) { throw new ParsedFailure('BatchIdentity','upd-batch'); }
    await this.write<void>(async (): Promise<void> => {
      const rows: relationalStore.ResultSet = await this.store().querySql('SELECT origin,input_hash,metadata FROM upd_batch WHERE id=?',[b.id]);
      try { if (rows.goToNextRow()) { if (rows.getString(0) !== b.origin || rows.getString(1) !== b.inputSetHash || rows.getString(2) !== JSON.stringify(b)) { throw new ParsedFailure('FrozenBatchConflict','upd-batch'); } return; } } finally { rows.close(); }
      await this.store().executeSql('INSERT INTO upd_batch VALUES(?,?,?,?)',[b.id,b.origin,b.inputSetHash,JSON.stringify(b)]);
    });
  }
  async saveJob(j: UnifiedProcessingJob): Promise<void> {
    jobOrigin(j.origin); jobState(j.state);
    if (!parsedId(j.id) || j.dedupKey.length === 0 || parsedUtf8(JSON.stringify(j)).length>7340032 || !Number.isSafeInteger(j.expected) || !Number.isSafeInteger(j.completed) || j.expected < 0 || j.completed < 0 || j.completed > j.expected || (j.origin === UnifiedJobOrigin.ExplicitUpgrade && j.batchId.length === 0)) { throw new ParsedFailure('JobIdentity','upd-job'); }
    await this.write<void>(async (): Promise<void> => {
      await this.ensureCapacity(parsedUtf8(JSON.stringify(j)).length+8192);
      const key: relationalStore.ResultSet = await this.store().querySql('SELECT id FROM upd_job WHERE dedup_key=?',[j.dedupKey]);
      try { if (key.goToNextRow() && key.getString(0) !== j.id) { throw new ParsedFailure('JobDedupIdentityConflict','upd-job'); } } finally { key.close(); }
      const rows: relationalStore.ResultSet = await this.store().querySql('SELECT dedup_key,doc,origin,batch,state FROM upd_job WHERE id=?',[j.id]);
      try { if (rows.goToNextRow() && (rows.getString(0) !== j.dedupKey || rows.getString(1) !== j.documentKey || rows.getString(2) !== j.origin || rows.getString(3) !== j.batchId || (rows.getString(4) === 'Unknown' && j.state === UnifiedJobState.Pending))) { throw new ParsedFailure('JobIdentityOrUnknownConflict','upd-job'); } } finally { rows.close(); }
      const old: relationalStore.ResultSet=await this.store().querySql('SELECT metadata FROM upd_job WHERE id=?',[j.id]);
      try { if (old.goToNextRow()) { const prior: PdfJsonNode=parsedJson(parsedUtf8(old.getString(0)),new ParsedCancellation());
        if (prior.required('version').string()!==j.version || prior.required('inputHash').string()!==j.inputHash || prior.required('expected').integer()!==j.expected || JSON.stringify(prior.required('inputs').array().map((n: PdfJsonNode): UnifiedTextInput=>unifiedInput(n)))!==JSON.stringify(j.inputs)) { throw new ParsedFailure('FrozenJobInputsChanged','upd-job'); }
      } } finally { old.close(); }
      await this.store().executeSql('INSERT INTO upd_job VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,metadata=excluded.metadata',[j.id,j.dedupKey,j.documentKey,j.origin,j.batchId,j.state,JSON.stringify(j)]);
    });
  }
  async jobs(): Promise<UnifiedProcessingJob[]> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT metadata FROM upd_job ORDER BY id'); const out: UnifiedProcessingJob[] = [];
    try { while (rows.goToNextRow()) {
      const n: PdfJsonNode = parsedJson(parsedUtf8(rows.getString(0)),new ParsedCancellation()); const j: UnifiedProcessingJob = new UnifiedProcessingJob();
      j.id = nodeString(n,'id'); j.dedupKey = nodeString(n,'dedupKey'); j.documentKey = nodeString(n,'documentKey'); j.ownerId = nodeString(n,'ownerId'); j.version = nodeString(n,'version'); j.inputHash = nodeString(n,'inputHash');
      j.origin = jobOrigin(nodeString(n,'origin')); j.batchId = nodeString(n,'batchId'); j.stage = nodeString(n,'stage'); j.settingsPurpose = nodeString(n,'settingsPurpose');
      j.settingsRevision = nodeNumber(n,'settingsRevision'); j.costRevision = nodeNumber(n,'costRevision'); j.credentialRevision = nodeNumber(n,'credentialRevision');
      j.epoch = nodeNumber(n,'epoch'); j.expected = nodeNumber(n,'expected'); j.completed = nodeNumber(n,'completed'); j.checkpoint = nodeString(n,'checkpoint'); j.failure = nodeString(n,'failure'); j.state = jobState(nodeString(n,'state')); out.push(j);
      j.assetId=n.optional('assetId')?.string() ?? ''; j.occurrenceId=n.optional('occurrenceId')?.string() ?? ''; j.annotationId=n.optional('annotationId')?.string() ?? '';
      j.configBinding=n.optional('configBinding')?.string() ?? '';
      j.resourcePhase=n.optional('resourcePhase')?.string() ?? 'NotHeld';
      for (const raw of n.optional('inputs')?.array() ?? []) { j.inputs.push(unifiedInput(raw)); }
    } } finally { rows.close(); } return out;
  }
  async saveAttempt(a: UnifiedProcessingAttempt): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      await this.ensureCapacity(parsedUtf8(JSON.stringify(a)).length+4096);
      const rows: relationalStore.ResultSet = await this.store().querySql('SELECT job,input_hash,metadata FROM upd_attempt WHERE id=?',[a.id]);
      try { if (rows.goToNextRow()) {
        const old: PdfJsonNode = parsedJson(parsedUtf8(rows.getString(2)),new ParsedCancellation());
        if (rows.getString(0) !== a.jobId || rows.getString(1) !== a.inputHash || (nodeBoolean(old,'launched') && !a.launched)) { throw new ParsedFailure('AttemptIdentityConflict','upd-attempt'); }
      } } finally { rows.close(); }
      await this.store().executeSql('INSERT OR REPLACE INTO upd_attempt VALUES(?,?,?,?,?)',[a.id,a.jobId,a.inputHash,a.outcome,JSON.stringify(a)]);
    });
  }
  async saveAnnotation(a: UnifiedEffectiveAnnotation): Promise<void> {
    if (a.id === 'None' || !parsedId(a.id) || !parsedId(a.lineage) || a.revision < 1 || !parsedHash(a.imageHash) || !parsedHash(a.textHash) || a.tags.length > 20) { throw new ParsedFailure('AnnotationIdentity','upd-annotation'); }
    await this.write<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.ensureCapacity(parsedUtf8(JSON.stringify(a)).length+8192);
      const old: relationalStore.ResultSet = await tx.querySql('SELECT metadata FROM upd_annotation WHERE id=?',[a.id]);
      try { if (old.goToNextRow()) { if (old.getString(0) !== JSON.stringify(a)) { throw new ParsedFailure('AnnotationImmutable','upd-annotation'); } return; } } finally { old.close(); }
      await tx.execute('INSERT INTO upd_annotation VALUES(?,?,?,?,?,?)',[a.id,a.lineage,a.revision,a.imageHash,a.textHash,JSON.stringify(a)]);
      for (let at: number = 0; at < a.tags.length; at++) { await tx.execute('INSERT INTO upd_tag VALUES(?,?,?)',[a.id,at,a.tags[at]]); }
      if (a.kind!=='Auto') { await tx.execute("UPDATE upd_index_binding SET state='Invalid' WHERE namespace='upd-image' AND owner=? AND version<>?",[a.lineage,a.id]); }
    }); });
  }
  async saveBinding(b: UnifiedIndexBinding): Promise<void> {
    if (['upd-body','upd-image'].indexOf(b.ownerNamespace) < 0 || b.space !== UNIFIED_TEXT_POLICY || !parsedHash(b.inputSetHash) || b.expected < 1 ||
      (b.state === UnifiedBindingState.Synced && (!parsedHash(b.readbackHash) || b.vectorGeneration.length === 0))) { throw new ParsedFailure('UnifiedBindingIdentity','upd-binding'); }
    await this.write<void>(async (): Promise<void> => {
      if (b.state===UnifiedBindingState.Synced && b.ownerNamespace==='upd-image' && !(await this.imageRecords()).some((r: UnifiedImageRecord): boolean=>r.lineage===b.ownerId && r.effectiveId===b.version)) { throw new ParsedFailure('BindingAnnotationNoLongerCurrent','vector'); }
      if (b.state===UnifiedBindingState.Synced && b.ownerNamespace==='upd-body') { const owner=await this.get(b.ownerId); if (owner===undefined || owner.tombstone || owner.archived || owner.activeGeneration!==b.version || owner.epoch!==b.epoch) { throw new ParsedFailure('BindingContentNoLongerCurrent','vector'); } }
      await this.store().executeSql('INSERT OR REPLACE INTO upd_index_binding VALUES(?,?,?,?,?,?,?,?,?,?)',[b.ownerNamespace,b.ownerId,b.version,b.epoch,b.space,b.expected,b.inputSetHash,b.vectorGeneration,b.readbackHash,b.state]);
    });
  }
  async appendHistory(r: UnifiedHistoryRevision): Promise<void> {
    if (!parsedId(r.recordId) || !parsedId(r.eventId) || r.revision < 1 || r.wire !== UNIFIED_HISTORY_WIRE || !parsedHash(r.snapshotHash)) { throw new ParsedFailure('HistoryIdentity','upd-history'); }
    await this.write<void>(async (): Promise<void> => {
      const rows: relationalStore.ResultSet = await this.store().querySql('SELECT revision,wire,asset,hash FROM upd_history WHERE record=? AND event=?',[r.recordId,r.eventId]);
      try { if (rows.goToNextRow()) { if (rows.getLong(0) !== r.revision || rows.getString(1) !== r.wire || rows.getString(2) !== r.snapshotAsset || rows.getString(3) !== r.snapshotHash) { throw new ParsedFailure('HistoryEventConflict','upd-history'); } return; } } finally { rows.close(); }
      await this.store().executeSql('INSERT INTO upd_history VALUES(?,?,?,?,?,?,?)',[r.recordId,r.eventId,r.revision,r.wire,r.snapshotAsset,r.snapshotHash,r.createdAt]);
    });
  }
  async meta(id: string): Promise<string> {
    const rows: relationalStore.ResultSet=await this.store().querySql('SELECT metadata FROM upd_settings WHERE purpose=?',['internal:'+id]); try { return rows.goToNextRow()?rows.getString(0):''; } finally { rows.close(); }
  }
  async putMeta(id: string, value: string): Promise<void> {
    if (parsedUtf8(value).length>1048576) { throw new ParsedFailure('MetadataBudget','store'); }
    await this.write<void>(async (): Promise<void> => { await this.ensureCapacity(parsedUtf8(value).length+4096); await this.store().executeSql('INSERT OR REPLACE INTO upd_settings VALUES(?,0,?)',['internal:'+id,value]); });
  }
  async imageRecords(document: string = '', archived: boolean=false): Promise<UnifiedImageRecord[]> {
    const rows: relationalStore.ResultSet=await this.store().querySql('SELECT o.id,o.doc,o.generation,o.asset,o.lineage,o.effective,o.metadata,d.title,a.hash FROM upd_image_occurrence o JOIN upd_document d ON d.id=o.doc AND d.active=o.generation LEFT JOIN upd_asset a ON a.id=o.asset WHERE d.tombstone=0'+(archived?'':' AND d.archived=0')+(document.length>0?' AND d.id=?':'')+' ORDER BY o.doc,o.id',document.length>0?[document]:[]);
    const out: UnifiedImageRecord[]=[]; try { while (rows.goToNextRow()) { const r: UnifiedImageRecord=new UnifiedImageRecord(); r.occurrenceId=rows.getString(0); r.documentKey=rows.getString(1); r.generation=rows.getString(2); r.assetId=rows.getString(3); r.lineage=rows.getString(4); r.effectiveId=rows.getString(5); r.title=rows.getString(7); r.imageHash=rows.getString(8); const n: PdfJsonNode=parsedJson(parsedUtf8(rows.getString(6)),new ParsedCancellation()); r.ocr=nodeString(n,'ocr'); r.caption=nodeString(n,'caption'); r.provenance=nodeString(n,'provenance'); out.push(r); } } finally { rows.close(); } return out;
  }
  async queryImageRecords(archived: boolean): Promise<UnifiedImageRecord[]> { return this.imageRecords('',archived); }
  async annotation(id: string): Promise<UnifiedEffectiveAnnotation | undefined> {
    const rows: relationalStore.ResultSet=await this.store().querySql('SELECT metadata FROM upd_annotation WHERE id=?',[id]); try { return rows.goToNextRow()?unifiedAnnotation(rows.getString(0)):undefined; } finally { rows.close(); }
  }
  async applyAnnotation(record: UnifiedImageRecord, annotation: UnifiedEffectiveAnnotation, proxyJob: UnifiedProcessingJob | undefined): Promise<boolean> {
    let changed: boolean=false;
    await this.write<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.ensureCapacity(parsedUtf8(JSON.stringify(annotation)).length+(proxyJob===undefined?0:parsedUtf8(JSON.stringify(proxyJob)).length)+16384);
      const rows: relationalStore.ResultSet=await tx.querySql('SELECT o.effective FROM upd_image_occurrence o JOIN upd_document d ON d.id=o.doc AND d.active=o.generation WHERE o.id=? AND o.asset=? AND o.generation=? AND d.tombstone=0',[record.occurrenceId,record.assetId,record.generation]);
      try { if (!rows.goToNextRow() || rows.getString(0)!==record.effectiveId) { return; } } finally { rows.close(); }
      const existing: relationalStore.ResultSet=await tx.querySql('SELECT metadata FROM upd_annotation WHERE id=?',[annotation.id]); let exists: boolean=false;
      try { if (existing.goToNextRow()) { if (existing.getString(0)!==JSON.stringify(annotation)) { throw new ParsedFailure('AnnotationImmutable','annotate'); } exists=true; } } finally { existing.close(); }
      if (!exists) { await tx.execute('INSERT INTO upd_annotation VALUES(?,?,?,?,?,?)',[annotation.id,annotation.lineage,annotation.revision,annotation.imageHash,annotation.textHash,JSON.stringify(annotation)]); for (let i: number=0;i<annotation.tags.length;i++) { await tx.execute('INSERT INTO upd_tag VALUES(?,?,?)',[annotation.id,i,annotation.tags[i]]); } }
      await tx.execute('UPDATE upd_image_occurrence SET lineage=?,effective=? WHERE id=? AND effective=?',[annotation.lineage,annotation.id,record.occurrenceId,record.effectiveId]);
      if (record.effectiveId!==annotation.id && record.lineage.length>0) { await tx.execute("UPDATE upd_index_binding SET state='Invalid' WHERE namespace='upd-image' AND owner=? AND version<>? AND NOT EXISTS(SELECT 1 FROM upd_image_occurrence o JOIN upd_document d ON d.id=o.doc AND d.active=o.generation WHERE o.lineage=? AND o.effective=? AND d.tombstone=0)",[record.lineage,annotation.id,record.lineage,record.effectiveId]); }
      for (const job of await this.jobs()) { if (job.stage==='ImageEmbedding' && job.occurrenceId===record.occurrenceId && job.annotationId!==annotation.id && [UnifiedJobState.AwaitingConfig,UnifiedJobState.Pending,UnifiedJobState.Paused].indexOf(job.state)>=0) {
        job.state=UnifiedJobState.Canceled; job.failure='AnnotationVersionChanged'; await tx.execute('UPDATE upd_job SET state=?,metadata=? WHERE id=?',[job.state,JSON.stringify(job),job.id]);
      } }
      if (proxyJob!==undefined) { await tx.execute('INSERT OR IGNORE INTO upd_job VALUES(?,?,?,?,?,?,?)',[proxyJob.id,proxyJob.dedupKey,proxyJob.documentKey,proxyJob.origin,proxyJob.batchId,proxyJob.state,JSON.stringify(proxyJob)]); }
      changed=true;
    }); }); return changed;
  }
  async attempts(job: string): Promise<UnifiedProcessingAttempt[]> {
    const rows: relationalStore.ResultSet=await this.store().querySql('SELECT metadata FROM upd_attempt WHERE job=? ORDER BY id',[job]); const out: UnifiedProcessingAttempt[]=[];
    try { while (rows.goToNextRow()) { out.push(unifiedAttempt(rows.getString(0))); } } finally { rows.close(); } return out;
  }
  async retryUnknown(id: string): Promise<void> {
    await this.write<void>(async (): Promise<void> => { const job: UnifiedProcessingJob | undefined=(await this.jobs()).find((j: UnifiedProcessingJob): boolean=>j.id===id); if (job===undefined || [UnifiedJobState.Unknown,UnifiedJobState.Failed,UnifiedJobState.Paused].indexOf(job.state)<0) { throw new ParsedFailure('RetryState','queue'); } job.state=UnifiedJobState.Pending; job.failure='ExplicitRetryAcceptsPossibleDuplicateCost'; await this.store().executeSql('UPDATE upd_job SET state=?,metadata=? WHERE id=?',[job.state,JSON.stringify(job),id]); });
  }
  async binding(namespace: string, owner: string): Promise<UnifiedIndexBinding | undefined> {
    const rows: relationalStore.ResultSet=await this.store().querySql('SELECT * FROM upd_index_binding WHERE namespace=? AND owner=?',[namespace,owner]);
    try { if (!rows.goToNextRow()) { return undefined; } const b: UnifiedIndexBinding=new UnifiedIndexBinding(); b.ownerNamespace=rows.getString(0); b.ownerId=rows.getString(1); b.version=rows.getString(2); b.epoch=rows.getLong(3); b.space=rows.getString(4); b.expected=rows.getLong(5); b.inputSetHash=rows.getString(6); b.vectorGeneration=rows.getString(7); b.readbackHash=rows.getString(8); const raw: string=rows.getString(9); const state: UnifiedBindingState | undefined=[UnifiedBindingState.Pending,UnifiedBindingState.Synced,UnifiedBindingState.Partial,UnifiedBindingState.Invalid].find((s: UnifiedBindingState): boolean=>s===raw); if (state===undefined) { throw new ParsedFailure('BindingState','store'); } b.state=state; return b; } finally { rows.close(); }
  }
  async reserveProxyInputs(owner: string, version: string, inputs: UnifiedTextInput[]): Promise<void> {
    await this.write<void>(async (): Promise<void>=> { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void>=> {
      await parsedPublicationBudget(tx,'',inputs.length,'','',owner);
      const expected: string=await this.identity.hash(parsedUtf8(inputs.map((i: UnifiedTextInput): string=>i.id+'|'+i.inputHash).join('\n')));
      await tx.execute('INSERT INTO upd_index_binding VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(namespace,owner) DO UPDATE SET version=excluded.version,expected=excluded.expected,input_hash=excluded.input_hash,state=excluded.state',['upd-image',owner,version,0,UNIFIED_TEXT_POLICY,inputs.length,expected,'','','Pending']);
    }); });
  }
  async admitAttempt(job: UnifiedProcessingJob, attempt: UnifiedProcessingAttempt, launch: () => void): Promise<void> {
    await this.write<void>(async (): Promise<void>=> {
      const current: UnifiedProcessingJob | undefined=(await this.jobs()).find((j: UnifiedProcessingJob): boolean=>j.id===job.id);
      const setting: UnifiedProcessingSettings=await this.settings(job.settingsPurpose); const doc: ParsedDocumentRecord | undefined=await this.get(job.documentKey);
      if (current===undefined || current.state!==UnifiedJobState.Running || doc===undefined || doc.tombstone || doc.archived || doc.epoch!==job.epoch ||
        !setting.enabled || setting.paused || !setting.automatic || !setting.costAcknowledged || setting.revision!==job.settingsRevision || setting.costRevision!==job.costRevision || setting.credentialRevision!==job.credentialRevision ||
        job.origin===UnifiedJobOrigin.LocalMigration || (job.origin===UnifiedJobOrigin.ExplicitUpgrade && job.batchId.length===0)) { throw new ParsedFailure('NoRequestCurrentAdmission','queue'); }
      if (current.version!==job.version || current.inputHash!==job.inputHash || current.assetId!==job.assetId || current.annotationId!==job.annotationId || current.stage!==job.stage || current.ownerId!==job.ownerId || current.expected!==job.expected || current.completed!==job.completed) { throw new ParsedFailure('NoRequestJobChanged','queue'); }
      if (job.stage==='Vision' && (setting.model!=='deepseek-flash' || setting.recipient!=='https://api.deepseek.com/chat/completions' || setting.imageScope!=='CurrentManagedImageOnly' || setting.policy!=='SHUVI-IMAGE-DESCRIPTION-ZH-1')) { throw new ParsedFailure('NoRequestVisionContractChanged','queue'); }
      if (job.settingsPurpose==='Embedding' && (setting.policy!==UNIFIED_TEXT_POLICY || setting.inputKinds.length!==3 || !setting.baselineAccepted)) { throw new ParsedFailure('NoRequestUnifiedTextPolicy','queue'); }
      if (job.settingsPurpose==='Embedding' && (setting.configBinding!==job.configBinding || job.inputs[job.completed]?.inputHash!==attempt.inputHash)) { throw new ParsedFailure('NoRequestActualInputOrConfig','queue'); }
      if (job.origin===UnifiedJobOrigin.ExplicitUpgrade) {
        const batchRows: relationalStore.ResultSet=await this.store().querySql('SELECT origin,metadata FROM upd_batch WHERE id=?',[job.batchId]);
        try { if (!batchRows.goToNextRow() || batchRows.getString(0)!=='ExplicitUpgrade') { throw new ParsedFailure('NoRequestFrozenBatchMissing','queue'); }
          const batch: PdfJsonNode=parsedJson(parsedUtf8(batchRows.getString(1)),new ParsedCancellation());
          if (batch.optional('wire')?.string()==='UNIFIED-EXPLICIT-UPGRADE-1') {
            const frozen: ParsedUpgradeBatch=upgradeDecodeBatch(batchRows.getString(1)); const target: ParsedUpgradeTarget | undefined=frozen.targets.find((t: ParsedUpgradeTarget): boolean=>t.documentKey===job.documentKey && t.generation===job.version && t.epoch===job.epoch);
            if (await this.identity.hash(parsedUtf8(JSON.stringify(frozen.targets)))!==frozen.inputSetHash) { throw new ParsedFailure('NoRequestFrozenUpgradeHash','queue'); }
            if (!frozen.approved || frozen.paused || target===undefined || (job.settingsPurpose==='Vision'?frozen.visionRevision:frozen.embeddingRevision)!==setting.revision || (job.settingsPurpose==='Vision'?frozen.visionCostRevision:frozen.embeddingCostRevision)!==setting.costRevision || (job.stage==='Vision' && target.images.indexOf(job.occurrenceId+'|'+job.assetId+'|'+job.inputHash)<0) || (job.stage==='BodyEmbedding' && target.bodyInputHash!==job.inputHash)) { throw new ParsedFailure('NoRequestFrozenUpgradeChanged','queue'); }
            if (job.stage==='ImageEmbedding') {
              const record: UnifiedImageRecord | undefined=(await this.imageRecords(job.documentKey)).find((r: UnifiedImageRecord): boolean=>r.occurrenceId===job.occurrenceId && r.assetId===job.assetId);
              if (record===undefined || target.images.indexOf(record.occurrenceId+'|'+record.assetId+'|'+record.imageHash)<0) { throw new ParsedFailure('NoRequestUpgradeImageOutsideBatch','queue'); }
              if (target.annotations.indexOf(record.occurrenceId+'|'+job.annotationId)<0) {
                const annotation=await this.annotation(job.annotationId); const produced=(await this.jobs()).some((j: UnifiedProcessingJob): boolean=>j.batchId===job.batchId && j.stage==='Vision' && j.occurrenceId===job.occurrenceId && j.state===UnifiedJobState.Complete);
                if (!produced || annotation===undefined || annotation.overlay.lineage.length>0) { throw new ParsedFailure('NoRequestUpgradeAnnotationChanged','queue'); }
              }
            }
          } else if (!batch.required('inputIds').array().some((n: PdfJsonNode): boolean=>n.string()===job.documentKey) || batch.required('settingsRevision').integer()!==setting.revision || batch.required('costRevision').integer()!==setting.costRevision) { throw new ParsedFailure('NoRequestFrozenBatchRevision','queue'); }
        } finally { batchRows.close(); }
      }
      if (job.stage==='Vision' || job.stage==='ImageEmbedding') {
        const record: UnifiedImageRecord | undefined=(await this.imageRecords(job.documentKey)).find((r: UnifiedImageRecord): boolean=>r.occurrenceId===job.occurrenceId && r.assetId===job.assetId && r.generation===job.version);
        if (record===undefined || (job.stage==='Vision' && record.imageHash!==job.inputHash) || (job.stage==='ImageEmbedding' && record.effectiveId!==job.annotationId)) { throw new ParsedFailure('NoRequestInputChanged','queue'); }
      } else if (doc.activeGeneration!==job.version) { throw new ParsedFailure('NoRequestContentChanged','queue'); }
      if (attempt.settingsRevision!==setting.revision || attempt.costRevision!==setting.costRevision || (await this.attempts(job.id)).some((a: UnifiedProcessingAttempt): boolean=>a.id===attempt.id && a.launched)) { throw new ParsedFailure('NoRequestAttemptConsumed','queue'); }
      await this.ensureCapacity(8192); attempt.launched=true; attempt.outcome='InFlight'; await this.store().executeSql('INSERT INTO upd_attempt VALUES(?,?,?,?,?)',[attempt.id,attempt.jobId,attempt.inputHash,attempt.outcome,JSON.stringify(attempt)]);
      launch();
    });
  }
  async tagMatches(term: string): Promise<UnifiedImageRecord[]> {
    const rows: relationalStore.ResultSet=await this.store().querySql('SELECT DISTINCT o.id FROM upd_image_occurrence o JOIN upd_document d ON d.id=o.doc AND d.active=o.generation JOIN upd_tag t ON t.annotation=o.effective WHERE d.tombstone=0 AND d.archived=0 AND instr(t.text,?)>0',[term]);
    const ids: string[]=[]; try { while (rows.goToNextRow()) { ids.push(rows.getString(0)); } } finally { rows.close(); }
    return (await this.imageRecords()).filter((r: UnifiedImageRecord): boolean=>ids.indexOf(r.occurrenceId)>=0);
  }
  async ensureCapacity(bytes: number): Promise<void> {
    if (!Number.isSafeInteger(bytes) || bytes<0 || this.physical===undefined || await this.physical.totalBytes()+Math.ceil(bytes/4096)*4096>ParsedLimits.sharedBytes) { throw new ParsedFailure('SharedPhysicalBudget','unified-write'); }
  }
  async migrationHold(input: ParsedMigrationInput, holder: string, document: string, generation: string): Promise<void> {
    await this.write<void>(async (): Promise<void>=> { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void>=> {
      await migrationCheckInput(tx,input);
      for (const source of input.sources) {
        const cleaned: relationalStore.ResultSet=await tx.querySql('SELECT state FROM upd_cleanup WHERE asset=? AND owner=?',[source.id,source.owner]); try { if (cleaned.goToNextRow()) { throw new ParsedFailure('LegacyCleanupAlreadyClaimed','migration-hold'); } } finally { cleaned.close(); }
        await tx.execute('INSERT OR IGNORE INTO upd_asset_ref VALUES(?,?,?,?,?,?)',[holder,document,generation,source.id,source.owner,source.role]);
      }
    }); });
  }
  async legacyRouteCurrent(namespace: string, id: string, active: string): Promise<boolean> {
    const rows: relationalStore.ResultSet=await this.store().querySql("SELECT l.doc FROM upd_legacy_link l JOIN upd_document d ON d.id=l.doc AND d.active=l.generation WHERE l.namespace=? AND l.legacy_id=? AND l.legacy_generation=? AND l.state='Committed' AND d.tombstone=0",[namespace,id,active]); try { return rows.goToNextRow(); } finally { rows.close(); }
  }
  async migrationLink(input: ParsedMigrationInput): Promise<ParsedLegacyLink | undefined> {
    const rows: relationalStore.ResultSet=await this.store().querySql("SELECT * FROM upd_legacy_link WHERE namespace=? AND legacy_id=? AND legacy_generation=? AND state='Committed'",[input.namespace,input.legacyId,input.active]);
    try { if (!rows.goToNextRow()) { return undefined; } const l: ParsedLegacyLink=new ParsedLegacyLink(); l.namespace=rows.getString(0); l.legacyId=rows.getString(1); l.legacyGeneration=rows.getString(2); l.legacyWire=rows.getString(3); l.legacyHash=rows.getString(4); l.documentKey=rows.getString(5); l.generation=rows.getString(6); l.epoch=rows.getLong(7); l.oldActive=rows.getString(8); l.state=rows.getString(9); return l; } finally { rows.close(); }
  }
  async saveMigrationBatch(batch: ParsedMigrationBatch): Promise<void> {
    await migrationDecodeBatch(JSON.stringify(batch),this.identity); const raw: string=JSON.stringify(batch);
    await this.write<void>(async (): Promise<void>=> { const rows: relationalStore.ResultSet=await this.store().querySql('SELECT origin,input_hash,metadata FROM upd_batch WHERE id=?',[batch.id]);
      try { if (rows.goToNextRow()) { if (rows.getString(0)!=='LocalMigration' || rows.getString(1)!==batch.inputSetHash || rows.getString(2)!==raw) { throw new ParsedFailure('FrozenMigrationBatchConflict','freeze'); } return; } } finally { rows.close(); }
      await this.ensureCapacity(parsedUtf8(raw).length+8192); await this.store().executeSql('INSERT INTO upd_batch VALUES(?,?,?,?)',[batch.id,'LocalMigration',batch.inputSetHash,raw]);
    });
  }
  async migrationBatch(id: string): Promise<ParsedMigrationBatch | undefined> {
    const rows: relationalStore.ResultSet=await this.store().querySql("SELECT metadata FROM upd_batch WHERE id=? AND origin='LocalMigration'",[id]); try { return rows.goToNextRow()?await migrationDecodeBatch(rows.getString(0),this.identity):undefined; } finally { rows.close(); }
  }
  async migrationBatchIds(): Promise<string[]> {
    const rows: relationalStore.ResultSet=await this.store().querySql("SELECT id FROM upd_batch WHERE origin='LocalMigration' ORDER BY id"); const ids: string[]=[]; try { while (rows.goToNextRow()) { ids.push(rows.getString(0)); } } finally { rows.close(); } return ids;
  }
  async saveMigrationReceipt(receipt: ParsedMigrationReceipt): Promise<void> {
    const batch: ParsedMigrationBatch | undefined=await this.migrationBatch(receipt.batchId); const input: ParsedMigrationInput | undefined=batch?.inputs.find((i: ParsedMigrationInput): boolean=>i.key===receipt.inputKey && i.inputHash===receipt.inputHash);
    if (input===undefined) { throw new ParsedFailure('ReceiptOutsideFrozenBatch','migration'); }
    await this.putMeta('migration-receipt:'+receipt.batchId+':'+receipt.inputKey,JSON.stringify(receipt));
  }
  async migrationReceipts(batch: string): Promise<ParsedMigrationReceipt[]> {
    const frozen: ParsedMigrationBatch | undefined=await this.migrationBatch(batch); const out: ParsedMigrationReceipt[]=[];
    for (const input of frozen?.inputs ?? []) { const raw: string=await this.meta('migration-receipt:'+batch+':'+input.key); if (raw.length>0) { out.push(migrationDecodeReceipt(raw)); } } return out;
  }
  async saveUpgradeBatch(batch: ParsedUpgradeBatch): Promise<void> {
    const raw: string=JSON.stringify(batch); upgradeDecodeBatch(raw); if (await this.identity.hash(parsedUtf8(JSON.stringify(batch.targets)))!==batch.inputSetHash) { throw new ParsedFailure('FrozenUpgradeHash','upgrade'); }
    await this.write<void>(async (): Promise<void>=> { await this.ensureCapacity(parsedUtf8(raw).length+8192);
      const rows: relationalStore.ResultSet=await this.store().querySql('SELECT origin,input_hash,metadata FROM upd_batch WHERE id=?',[batch.id]);
      try { if (rows.goToNextRow()) { const old: ParsedUpgradeBatch=upgradeDecodeBatch(rows.getString(2)); if (rows.getString(0)!=='ExplicitUpgrade' || rows.getString(1)!==batch.inputSetHash || JSON.stringify(old.targets)!==JSON.stringify(batch.targets) || old.visionRevision!==batch.visionRevision || old.visionCostRevision!==batch.visionCostRevision || old.embeddingRevision!==batch.embeddingRevision || old.embeddingCostRevision!==batch.embeddingCostRevision || old.approved && !batch.approved) { throw new ParsedFailure('FrozenUpgradeConflict','upgrade'); } } } finally { rows.close(); }
      await this.store().executeSql('INSERT INTO upd_batch VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata',[batch.id,'ExplicitUpgrade',batch.inputSetHash,raw]);
    });
  }
  async upgradeBatch(id: string): Promise<ParsedUpgradeBatch | undefined> {
    const rows: relationalStore.ResultSet=await this.store().querySql("SELECT metadata FROM upd_batch WHERE id=? AND origin='ExplicitUpgrade'",[id]); try { return rows.goToNextRow()?upgradeDecodeBatch(rows.getString(0)):undefined; } finally { rows.close(); }
  }
  async upgradeBatchIds(): Promise<string[]> {
    const rows: relationalStore.ResultSet=await this.store().querySql("SELECT id FROM upd_batch WHERE origin='ExplicitUpgrade' ORDER BY id"); const ids: string[]=[]; try { while (rows.goToNextRow()) { ids.push(rows.getString(0)); } } finally { rows.close(); } return ids;
  }
  async unifiedHistoryRows(offset: number, limit: number): Promise<UnifiedHistoryRevision[]> {
    if (!Number.isSafeInteger(offset) || offset<0 || limit<1 || limit>20) { throw new ParsedFailure('HistoryPageRange','history'); }
    const rows=await this.store().querySql('SELECT h.record,h.event,h.revision,h.wire,h.asset,h.hash,h.created FROM upd_history h WHERE h.revision=(SELECT MAX(x.revision) FROM upd_history x WHERE x.record=h.record) ORDER BY h.created DESC,h.record DESC LIMIT ? OFFSET ?',[limit,offset]); const result: UnifiedHistoryRevision[]=[];
    try { while (rows.goToNextRow()) { const r: UnifiedHistoryRevision=new UnifiedHistoryRevision(); r.recordId=rows.getString(0); r.eventId=rows.getString(1); r.revision=rows.getLong(2); r.wire=rows.getString(3); r.snapshotAsset=rows.getString(4); r.snapshotHash=rows.getString(5); r.createdAt=rows.getLong(6); result.push(r); } } finally { rows.close(); } return result;
  }
  async pendingHistoryAssets(): Promise<string[]> { const rows=await this.store().querySql("SELECT w.id FROM upd_asset_write w WHERE w.role='history' AND w.phase='Ready' AND w.id LIKE w.generation||'-r%' AND NOT EXISTS(SELECT 1 FROM upd_history h WHERE h.asset=w.id) ORDER BY w.id LIMIT 100"); const ids: string[]=[]; try { while (rows.goToNextRow()) { ids.push(rows.getString(0)); } } finally { rows.close(); } return ids; }
  async reusableImage(hash: string): Promise<ParsedImageAsset | undefined> {
    const rows=await this.store().querySql("SELECT id FROM upd_asset WHERE hash=? AND state='Ready' AND path LIKE 'images/%' AND NOT EXISTS(SELECT 1 FROM upd_cleanup c WHERE c.asset=upd_asset.id) ORDER BY id",[hash]);
    try { return rows.goToNextRow()?await this.asset(rows.getString(0)):undefined; } finally { rows.close(); }
  }
  async holdProcessingJob(job: UnifiedProcessingJob): Promise<void> {
    await this.write<void>(async (): Promise<void>=> { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void>=> {
      const doc=await this.get(job.documentKey); if (doc===undefined || doc.tombstone || doc.archived || doc.activeGeneration!==job.version || doc.epoch!==job.epoch) { throw new ParsedFailure('JobOwnerNoLongerCurrent','job-hold'); }
      await tx.execute('INSERT OR IGNORE INTO upd_asset_ref SELECT ?,doc,generation,asset,owner,? FROM upd_asset_ref WHERE doc=? AND generation=?',['task-'+job.id,'task',job.documentKey,job.version]);
      if (job.assetId.length>0) { await tx.execute('INSERT OR IGNORE INTO upd_asset_ref VALUES(?,?,?,?,?,?)',['task-'+job.id,job.documentKey,job.version,job.assetId,'ParsedDocumentAssets','task']); }
      job.resourcePhase='Held'; await tx.execute('UPDATE upd_job SET metadata=? WHERE id=?',[JSON.stringify(job),job.id]);
    }); });
  }
  async releaseProcessingJob(job: UnifiedProcessingJob, pending: boolean): Promise<void> {
    await this.write<void>(async (): Promise<void>=> { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void>=> {
      job.resourcePhase=pending?'OutcomeUnknownHeld':'Released'; if (!pending) { await tx.execute('DELETE FROM upd_asset_ref WHERE holder=?',['task-'+job.id]); }
      await tx.execute('UPDATE upd_job SET state=?,metadata=? WHERE id=?',[job.state,JSON.stringify(job),job.id]);
    }); });
  }
  async retryProcessingReleases(): Promise<void> { for (const job of await this.jobs()) { if (job.resourcePhase==='ReleasePending' || job.resourcePhase==='Held' && [UnifiedJobState.Complete,UnifiedJobState.Failed,UnifiedJobState.Canceled].indexOf(job.state)>=0) { await this.releaseProcessingJob(job,job.state===UnifiedJobState.Unknown); } } }
  async acknowledgeUnknownRelease(id: string): Promise<void> {
    await this.write<void>(async (): Promise<void>=> { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void>=> {
      const job=(await this.jobs()).find((j: UnifiedProcessingJob): boolean=>j.id===id); if (job===undefined || job.state!==UnifiedJobState.Unknown) { throw new ParsedFailure('UnknownJobRequired','release'); }
      const doc=await this.get(job.documentKey); if (doc!==undefined && !doc.tombstone) { throw new ParsedFailure('UnknownCurrentJobMustRemainHeld','release'); }
      job.failure='ExplicitLocalTrackingReleaseDoesNotCancelCloud'; job.state=UnifiedJobState.Canceled; job.resourcePhase='Released';
      await tx.execute('DELETE FROM upd_asset_ref WHERE holder=?',['task-'+job.id]); await tx.execute('UPDATE upd_job SET state=?,metadata=? WHERE id=?',[job.state,JSON.stringify(job),job.id]);
    }); });
  }
  async setUnifiedArchived(id: string, archived: boolean): Promise<void> {
    await this.write<void>(async (): Promise<void>=> { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void>=> {
      const doc=await this.get(id); if (doc===undefined || doc.tombstone) { throw new ParsedFailure('DocumentUnavailable','archive'); } if (doc.archived===archived) { return; }
      await tx.execute('UPDATE upd_document SET archived=?,epoch=epoch+1 WHERE id=?',[archived?1:0,id]);
      await tx.execute("UPDATE upd_index_binding SET state='Invalid' WHERE namespace='upd-body' AND owner=?",[id]); await this.reconcileOwnersTx(tx);
    }); });
  }
  async deleteUnified(id: string): Promise<void> {
    await this.write<void>(async (): Promise<void>=> { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void>=> {
      const doc=await this.get(id); if (doc===undefined || doc.tombstone) { return; }
      await tx.execute('UPDATE upd_document SET tombstone=1,epoch=epoch+1 WHERE id=?',[id]); await tx.execute("UPDATE upd_generation SET state='Retained' WHERE doc=?",[id]);
      await tx.execute("UPDATE upd_index_binding SET state='Invalid' WHERE namespace='upd-body' AND owner=?",[id]);
      // All new generations and legacy owner links release only this parent's facts.
      await tx.execute("DELETE FROM upd_asset_ref WHERE doc=? AND role<>'task'",[id]);
      await this.reconcileOwnersTx(tx);
    }); });
  }
  async reconcileUnifiedOwners(): Promise<void> { await this.write<void>(async (): Promise<void>=> { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void>=> { await this.reconcileOwnersTx(tx); }); }); }
  private async reconcileOwnersTx(tx: relationalStore.Transaction): Promise<void> {
    const records=await this.imageRecords(); const jobs=await this.jobs();
    for (const job of jobs) {
      const doc=await this.get(job.documentKey); const bodyCurrent=doc!==undefined && !doc.tombstone && !doc.archived && doc.activeGeneration===job.version && doc.epoch===job.epoch;
      if (job.stage==='ImageEmbedding') {
        const parents=records.filter((r: UnifiedImageRecord): boolean=>r.lineage===job.ownerId && r.effectiveId===job.annotationId);
        if (parents.length>0) {
          const current=parents.find((r: UnifiedImageRecord): boolean=>r.documentKey===job.documentKey && r.generation===job.version && r.occurrenceId===job.occurrenceId);
          if (current===undefined || !bodyCurrent) { const parent=parents[0]; const owner=await this.get(parent.documentKey); if (owner!==undefined) {
            if (job.state===UnifiedJobState.Running || job.state===UnifiedJobState.Unknown) { continue; }
            const canMove=job.origin!==UnifiedJobOrigin.ExplicitUpgrade || job.state===UnifiedJobState.Complete;
            if (canMove) { job.documentKey=parent.documentKey; job.version=parent.generation; job.assetId=parent.assetId; job.occurrenceId=parent.occurrenceId; job.epoch=owner.epoch; if (job.expected>0 && job.completed===job.expected && [UnifiedJobState.Canceled,UnifiedJobState.Failed].indexOf(job.state)>=0) { job.state=UnifiedJobState.Complete; } await tx.execute('UPDATE upd_job SET doc=?,state=?,metadata=? WHERE id=?',[job.documentKey,job.state,JSON.stringify(job),job.id]); continue; }
          } }
          if (current!==undefined && bodyCurrent) { continue; }
        }
        await tx.execute("UPDATE upd_index_binding SET state='Invalid' WHERE namespace='upd-image' AND owner=? AND version=?",[job.ownerId,job.annotationId]);
      } else if (bodyCurrent) { continue; }
      else if (job.stage==='BodyEmbedding' && doc!==undefined && !doc.tombstone && !doc.archived && doc.activeGeneration===job.version && job.state===UnifiedJobState.Complete) {
        job.epoch=doc.epoch; await tx.execute('UPDATE upd_job SET metadata=? WHERE id=?',[JSON.stringify(job),job.id]); continue;
      }
      if (job.state!==UnifiedJobState.Complete && job.state!==UnifiedJobState.Unknown && job.state!==UnifiedJobState.Running) { job.state=UnifiedJobState.Canceled; job.failure='OwnerRetired'; await tx.execute('UPDATE upd_job SET state=?,metadata=? WHERE id=?',[job.state,JSON.stringify(job),job.id]); }
    }
    const bindings=await tx.querySql("SELECT owner,version FROM upd_index_binding WHERE namespace='upd-image'"); const invalid: string[]=[];
    try { while (bindings.goToNextRow()) { const owner=bindings.getString(0),version=bindings.getString(1); if (!records.some((r: UnifiedImageRecord): boolean=>r.lineage===owner && r.effectiveId===version)) { invalid.push(owner); } } } finally { bindings.close(); }
    for (const owner of invalid) { await tx.execute("UPDATE upd_index_binding SET state='Invalid' WHERE namespace='upd-image' AND owner=?",[owner]); }
  }
  async unifiedCleanupAssets(): Promise<string[]> {
    const rows=await this.store().querySql("SELECT a.id FROM upd_asset a WHERE a.owner='ParsedDocumentAssets' AND a.state<>'Removed' AND NOT EXISTS(SELECT 1 FROM upd_asset_ref r WHERE r.asset=a.id AND r.owner=a.owner) ORDER BY a.id"); const ids: string[]=[]; try { while (rows.goToNextRow()) { ids.push(rows.getString(0)); } } finally { rows.close(); } return ids;
  }
  async retryReadReleases(): Promise<void> {
    const rows=await this.store().querySql("SELECT id,session FROM upd_read_lease WHERE holder LIKE 'ReleasePending%'"); const leases: string[]=[]; try { while (rows.goToNextRow()) { leases.push(rows.getString(0)); } } finally { rows.close(); } for (const id of leases) { await this.releaseLease(id); }
  }
  async recoverReadLeases(session: string): Promise<void> {
    await this.write<void>(async (): Promise<void>=> { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void>=> { const rows=await tx.querySql('SELECT id,asset,owner,session,holder FROM upd_read_lease WHERE session<>?',[session]); const ids: string[]=[]; try { while (rows.goToNextRow()) { ids.push(rows.getString(0)); } } finally { rows.close(); } for (const id of ids) { await tx.execute('INSERT OR REPLACE INTO upd_settings VALUES(?,0,?)',['internal:release:'+id,'PreviousProcessEnded']); await tx.execute('DELETE FROM upd_read_lease WHERE id=?',[id]); } }); });
  }
  async retiredGenerationIds(document: string): Promise<string[]> { const rows=await this.store().querySql("SELECT id FROM upd_generation WHERE doc=? AND state='Retained' ORDER BY id",[document]); const ids: string[]=[]; try { while (rows.goToNextRow()) { ids.push(rows.getString(0)); } } finally { rows.close(); } return ids; }
  async retireUnifiedGeneration(document: string, generation: string): Promise<void> {
    await this.write<void>(async (): Promise<void>=> { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void>=> {
      const doc=await this.get(document); if (doc===undefined || !doc.tombstone && doc.activeGeneration===generation) { throw new ParsedFailure('ActiveGenerationCannotRetire','retire'); }
      const held=await tx.querySql("SELECT id FROM upd_read_lease WHERE asset IN (SELECT asset FROM upd_asset_ref WHERE generation=?) UNION SELECT holder FROM upd_asset_ref WHERE generation=? AND role='task'",[generation,generation]);
      try { if (held.goToNextRow()) { throw new ParsedFailure('RetainedGenerationReadHeld','retire'); } } finally { held.close(); }
      await tx.execute("DELETE FROM upd_asset_ref WHERE doc=? AND generation=? AND role<>'task'",[document,generation]); await tx.execute("UPDATE upd_generation SET state='Removed' WHERE id=? AND doc=?",[generation,document]);
    }); });
  }
}
