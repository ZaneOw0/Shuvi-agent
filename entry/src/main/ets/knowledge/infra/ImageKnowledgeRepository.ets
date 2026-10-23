import { relationalStore } from '@kit.ArkData';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { IMAGE_STORE_DDL, IMAGE_STORE_LAYOUT, imageVerifyExisting, imagePublicationBudget } from './ImageStoreLayout';
import { docxVerifyExisting } from './DocxStoreLayout';
import { ImageSnapshot, ImageChunk, ImageOcrBlock } from '../domain/ImageKnowledgeModels';
import { imageDecodeSnapshot, imageReadLocator, imageVerifySnapshot } from '../pipeline/ImageSnapshotCodec';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { BoundedDocumentJson } from '../pipeline/BoundedDocumentJson';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { ImageRepositoryPort, ImageSnapshotAssetPort } from '../domain/ImageKnowledgePorts';
import { KnowledgeHit, KnowledgeSourceKind, KnowledgeChannel } from '../domain/KnowledgeSearchModels';
import { TextQueryInput } from '../domain/TextKnowledgeModels';
import { knowledgeLiteralScore } from '../pipeline/KnowledgeMatchPolicy';
import { KnowledgePhysicalBudgetPort, KnowledgeDerivedUsage } from './KnowledgeDerivedBudget';
import { ImageOriginal, ImageDocument, ImageJob, ImageAssetClaim, ImageReadLease, ImageReleaseReceipt, ImageCleanupIntent,
  ImageIngestionStage, ImageKnowledgeFailure, imageIdentity, imageHash, imageEncoding, imageStage, ImageLimits } from '../domain/ImageKnowledgeModels';

function imageStoreNumber(rows: relationalStore.ResultSet, column: number): number {
  const n: number = rows.getLong(column); if (!Number.isSafeInteger(n) || n < 0) { throw new ImageKnowledgeFailure('InvalidStoredNumber', 'image-store'); } return n;
}
function imageStoreBoolean(rows: relationalStore.ResultSet, column: number): boolean {
  const n: number = imageStoreNumber(rows,column); if (n > 1) { throw new ImageKnowledgeFailure('InvalidStoredBoolean', 'image-store'); } return n === 1;
}
export class ImageKnowledgeRepository implements ImageRepositoryPort {
  private host: KnowledgeStoreHost; private opened: boolean = false;
  private physical: KnowledgePhysicalBudgetPort | undefined = undefined;
  private identity: KnowledgeIdentityPort | undefined = undefined;
  private snapshotAssets: ImageSnapshotAssetPort | undefined = undefined;
  attachIdentity(identity: KnowledgeIdentityPort): void { this.identity = identity; }
  attachSnapshotAssets(assets: ImageSnapshotAssetPort): void { this.snapshotAssets = assets; }
  attachPhysicalBudget(port: KnowledgePhysicalBudgetPort): void { this.physical = port; }
  constructor(host: KnowledgeStoreHost) { this.host = host; }
  ready(): boolean { return this.opened && this.host.m1Ready; }
  private store(): relationalStore.RdbStore { if (!this.ready()) { throw new ImageKnowledgeFailure('ImageStoreUnavailable', 'image-store'); } return this.host.requireStore(); }
  async open(): Promise<void> {
    if (this.opened) { return; } await this.host.acquireExtension();
    try {
      await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
        if (!(await imageVerifyExisting(tx))) {
          for (const ddl of IMAGE_STORE_DDL) { await tx.execute(ddl); }
          await tx.execute('INSERT INTO kb_image_meta VALUES(?,?)',['layout',IMAGE_STORE_LAYOUT]);
          for (const kind of ['Text','Pdf','Image']) { await tx.execute('INSERT INTO kb_source_registry VALUES(?,?,?)',[kind,kind === 'Image' ? 'IMAGE-NORMALIZED-1' : kind === 'Pdf' ? 'PDF-NORMALIZED-1' : 'TEXT-SNAPSHOT-1','Enabled']); }
        }
        await imageVerifyExisting(tx);
      }); }); this.opened = true; this.host.imageReady = true;
    } catch (error) { await this.host.release(); if (error instanceof Error) { throw error; } throw new ImageKnowledgeFailure('ImageMigrationFailed', 'migration'); }
  }
  async close(): Promise<void> { if (this.opened) { await this.host.release(); this.opened = false; } }
  private async write(action: (tx: relationalStore.Transaction) => Promise<void>): Promise<void> {
    this.store(); await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(action); });
  }
  async reserve(id: string, owner: string, bytes: number): Promise<void> {
    if (!imageIdentity(id) || !imageIdentity(owner) || !Number.isSafeInteger(bytes) || bytes < 1 || this.physical === undefined) { throw new ImageKnowledgeFailure('ReservationEvidenceMissing', 'image-budget'); }
    const usage: KnowledgeDerivedUsage = await this.physical.usage();
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const docx: boolean = await docxVerifyExisting(tx);
      const rows: relationalStore.ResultSet = await tx.querySql("SELECT COALESCE((SELECT SUM(bytes) FROM kb_image_reservation WHERE state='Reserved'),0)+COALESCE((SELECT SUM(reserved) FROM kb_derived_reservation WHERE state='Reserved'),0)"+(docx ? "+COALESCE((SELECT SUM(bytes) FROM kb_docx_reservation WHERE state='Reserved'),0)" : ''));
      let reserved: number = 0; try { if (!rows.goToNextRow()) { throw new ImageKnowledgeFailure('BudgetReadIncomplete','image-budget'); } reserved = imageStoreNumber(rows,0); } finally { rows.close(); }
      if (usage.total()-usage.pendingReserved+reserved+bytes > 500*1024*1024) { throw new ImageKnowledgeFailure('SharedDerivedBudget','image-budget'); }
      await tx.execute('INSERT INTO kb_image_reservation VALUES(?,?,?,?)',[id,owner,bytes,'Reserved']);
    });
  }
  async releaseReservation(id: string, owner: string): Promise<void> { await this.write(async (tx: relationalStore.Transaction): Promise<void> => { await tx.execute('DELETE FROM kb_image_reservation WHERE id=? AND owner=?',[id,owner]); }); }
  private rowDocument(rows: relationalStore.ResultSet): ImageDocument {
    const doc: ImageDocument = new ImageDocument(); doc.id = rows.getString(0); doc.title = rows.getString(1);
    doc.epoch = imageStoreNumber(rows,2); doc.archived = imageStoreBoolean(rows,3); doc.tombstone = imageStoreBoolean(rows,4);
    doc.activeOriginal = rows.getString(5); doc.activeGeneration = rows.getString(6); doc.chunkCount = imageStoreNumber(rows,7); doc.stage = imageStage(rows.getString(8));
    if (!imageIdentity(doc.id) || doc.chunkCount > ImageLimits.chunks) { throw new ImageKnowledgeFailure('InvalidImageDocument', 'image-store'); } return doc;
  }
  async list(): Promise<ImageDocument[]> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM kb_image_document ORDER BY id'); const docs: ImageDocument[] = [];
    try { while (rows.goToNextRow()) { if (docs.length >= 10000) { throw new ImageKnowledgeFailure('DocumentCount', 'image-store'); } docs.push(this.rowDocument(rows)); } } finally { rows.close(); } return docs;
  }
  async get(id: string): Promise<ImageDocument | undefined> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM kb_image_document WHERE id=?',[id]);
    try { return rows.goToNextRow() ? this.rowDocument(rows) : undefined; } finally { rows.close(); }
  }
  async documentForSource(sourceId: string): Promise<ImageDocument | undefined> {
    const rows = await this.store().querySql('SELECT DISTINCT doc FROM kb_image_original WHERE source=?',[sourceId]); let id: string = '';
    try { if (rows.goToNextRow()) { id = rows.getString(0); if (rows.goToNextRow()) { throw new ImageKnowledgeFailure('ImageSourceOwnerAmbiguous','image-read'); } } } finally { rows.close(); }
    return id.length === 0 ? undefined : this.get(id);
  }
  async original(asset: string): Promise<ImageOriginal> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM kb_image_original WHERE asset=?',[asset]);
    try {
      if (!rows.goToNextRow()) { throw new ImageKnowledgeFailure('OriginalMissing', 'image-store'); }
      const o: ImageOriginal = new ImageOriginal(); o.assetId = rows.getString(0); o.documentId = rows.getString(1); o.sourceId = rows.getString(2);
      o.version = imageStoreNumber(rows,3); o.title = rows.getString(4); o.suffix = rows.getString(5); o.hash = rows.getString(6); o.bytes = imageStoreNumber(rows,7);
      o.header.encoding = imageEncoding(rows.getString(8)); o.header.mime = rows.getString(9); o.header.width = imageStoreNumber(rows,10); o.header.height = imageStoreNumber(rows,11);
      o.header.orientation = imageStoreNumber(rows,12); o.header.orientationEvidence = rows.getString(13); o.header.alpha = imageStoreBoolean(rows,14); o.header.variant = rows.getString(15);
      o.header.staticContainer = imageStoreBoolean(rows,16); o.sdkVerified = imageStoreBoolean(rows,17); o.frames = imageStoreNumber(rows,18); o.savedAt = imageStoreNumber(rows,19);
      if (!imageIdentity(o.assetId) || !imageIdentity(o.documentId) || !imageHash(o.hash) || o.bytes < 1 || o.bytes > ImageLimits.bytes || o.version < 1 || o.header.width < 1 || o.header.height < 1 || o.header.width*o.header.height > ImageLimits.pixels || o.header.orientation > 8 || !o.header.staticContainer || o.frames > 1) { throw new ImageKnowledgeFailure('InvalidImageOriginal', 'image-store'); }
      o.basicQualified = true; if (o.suffix !== (o.header.encoding === 'JPEG' ? '.jpg' : o.header.encoding === 'PNG' ? '.png' : '.webp') && !(o.header.encoding === 'JPEG' && o.suffix === '.jpeg')) { o.header.warnings.push('SuffixEncodingConflict'); } return o;
    } finally { rows.close(); }
  }
  async latestOriginal(documentId: string): Promise<ImageOriginal> {
    const rows = await this.store().querySql('SELECT asset FROM kb_image_original WHERE doc=? ORDER BY version DESC,saved DESC LIMIT 1',[documentId]);
    let asset: string = ''; try { if (!rows.goToNextRow()) { throw new ImageKnowledgeFailure('ImageOriginalMissing','image-replace'); } asset = rows.getString(0); } finally { rows.close(); } return this.original(asset);
  }
  async register(o: ImageOriginal, assets: ImageAssetClaim[]): Promise<void> {
    if (!imageIdentity(o.documentId) || !imageIdentity(o.assetId) || !imageHash(o.hash) || o.version < 1 || o.bytes < 1 || o.bytes > ImageLimits.bytes || o.header.width < 1 || o.header.height < 1 || o.header.width*o.header.height > ImageLimits.pixels || o.frames > 1 || !o.header.staticContainer || assets.length < 1 || assets.length > 32 || assets.filter((a: ImageAssetClaim): boolean => a.assetId === o.assetId && a.hash === o.hash && a.role === 'Original').length !== 1 || assets.some((a: ImageAssetClaim): boolean => a.documentId !== o.documentId || !imageIdentity(a.assetId) || !imageIdentity(a.owner) || !imageHash(a.hash) || !Number.isSafeInteger(a.pins) || a.pins < 1)) { throw new ImageKnowledgeFailure('AssetOwnershipOrEvidenceInvalid', 'image-register'); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const prior: relationalStore.ResultSet = await tx.querySql('SELECT tombstone FROM kb_image_document WHERE id=?',[o.documentId]); let found: boolean = false;
      try { if (prior.goToNextRow()) { found = true; if (prior.getLong(0) !== 0) { throw new ImageKnowledgeFailure('DeletedDocument', 'image-register'); } } } finally { prior.close(); }
      if (!found) { await tx.execute('INSERT INTO kb_image_document VALUES(?,?,0,0,0,?,?,0,?)',[o.documentId,o.title,o.assetId,'',ImageIngestionStage.Saved]); }
      await tx.execute('INSERT INTO kb_image_original VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[o.assetId,o.documentId,o.sourceId,o.version,o.title,o.suffix,o.hash,o.bytes,o.header.encoding,o.header.mime,o.header.width,o.header.height,o.header.orientation,o.header.orientationEvidence,o.header.alpha ? 1 : 0,o.header.variant,o.header.staticContainer ? 1 : 0,o.sdkVerified ? 1 : 0,o.frames,o.savedAt]);
      for (const a of assets) { await tx.execute('INSERT INTO kb_image_asset VALUES(?,?,?,?,?,?,?,?)',[a.assetId,a.documentId,a.owner,a.hash,a.bytes,a.generation,a.role,a.pins]); }
    });
  }
  async begin(job: ImageJob): Promise<void> {
    if (!imageIdentity(job.id) || !imageIdentity(job.generation)) { throw new ImageKnowledgeFailure('InvalidJobIdentity', 'image-job'); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJobDocument(tx,job);
      const original: relationalStore.ResultSet = await tx.querySql('SELECT asset FROM kb_image_original WHERE asset=? AND doc=?',[job.originalAssetId,job.documentId]);
      try { if (!original.goToNextRow()) { throw new ImageKnowledgeFailure('CandidateOriginalMissing', 'image-job'); } } finally { original.close(); }
      await tx.execute('INSERT INTO kb_image_job VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[job.id,job.documentId,job.generation,job.originalAssetId,job.epoch,job.expectedActive,job.reportHash,job.snapshotHash,job.stage,job.checkpoint,job.failure,job.serviceTaskId,job.resultAssetId,job.resultHash]);
      await tx.execute('INSERT INTO kb_image_generation VALUES(?,?,?,?,?,?,?,?,?)',[job.generation,job.documentId,job.originalAssetId,job.epoch,'Staging','','','',0]);
    });
  }
  private async assertJobDocument(tx: relationalStore.Transaction, job: ImageJob): Promise<void> {
    const rows: relationalStore.ResultSet = await tx.querySql('SELECT epoch,tombstone,active_generation FROM kb_image_document WHERE id=?',[job.documentId]);
    try { if (!rows.goToNextRow() || rows.getLong(0) !== job.epoch || rows.getLong(1) !== 0 || rows.getString(2) !== job.expectedActive) { throw new ImageKnowledgeFailure('StaleImageJob', 'image-write'); } } finally { rows.close(); }
  }
  async checkpoint(job: ImageJob): Promise<void> {
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJobDocument(tx,job);
      const rows: relationalStore.ResultSet = await tx.querySql('SELECT state FROM kb_image_generation WHERE id=? AND doc=? AND epoch=?',[job.generation,job.documentId,job.epoch]);
      try { if (!rows.goToNextRow() || ['Staging','Prepared'].indexOf(rows.getString(0)) < 0) { throw new ImageKnowledgeFailure('RetiredImageJob', 'image-checkpoint'); } } finally { rows.close(); }
      await tx.execute('UPDATE kb_image_job SET report=?,snapshot=?,stage=?,checkpoint=?,failure=?,task=?,result_asset=?,result_hash=? WHERE id=? AND generation=?',[job.reportHash,job.snapshotHash,job.stage,job.checkpoint,job.failure,job.serviceTaskId,job.resultAssetId,job.resultHash,job.id,job.generation]);
    });
  }
  async jobs(): Promise<ImageJob[]> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM kb_image_job ORDER BY id'); const jobs: ImageJob[] = [];
    try { while (rows.goToNextRow()) {
      if (jobs.length >= 10000) { throw new ImageKnowledgeFailure('JobCount', 'image-store'); }
      const j: ImageJob = new ImageJob(); j.id = rows.getString(0); j.documentId = rows.getString(1); j.generation = rows.getString(2); j.originalAssetId = rows.getString(3);
      j.epoch = imageStoreNumber(rows,4); j.expectedActive = rows.getString(5); j.reportHash = rows.getString(6); j.snapshotHash = rows.getString(7);
      j.stage = imageStage(rows.getString(8)); j.checkpoint = imageStage(rows.getString(9)); j.failure = rows.getString(10); j.serviceTaskId = rows.getString(11); j.resultAssetId = rows.getString(12); j.resultHash = rows.getString(13); jobs.push(j);
    } } finally { rows.close(); } return jobs;
  }
  async snapshot(generation: string): Promise<ImageSnapshot> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT wire,hash,report FROM kb_image_generation WHERE id=?',[generation]);
    try {
      if (!rows.goToNextRow()) { throw new ImageKnowledgeFailure('ImageCheckpointMissing','image-read'); }
      if (this.snapshotAssets === undefined) { throw new ImageKnowledgeFailure('SnapshotAssetPortMissing','image-read'); }
      const snapshot: ImageSnapshot = imageDecodeSnapshot(await this.snapshotAssets.read(rows.getString(0),rows.getString(1),new KnowledgeCancellation()),new KnowledgeCancellation());
      if (snapshot.generation !== generation || snapshot.contentHash !== rows.getString(1) || snapshot.coverage.hash !== rows.getString(2) || this.identity === undefined) { throw new ImageKnowledgeFailure('ImageCheckpointDigestBinding','image-read'); }
      await imageVerifySnapshot(snapshot,this.identity,new KnowledgeCancellation()); return snapshot;
    } finally { rows.close(); }
  }
  async chunks(generation: string): Promise<ImageChunk[]> {
    if (this.identity === undefined) { throw new ImageKnowledgeFailure('ImageReadIdentityUnavailable','image-read'); }
    const snapshot: ImageSnapshot = await this.snapshot(generation);
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM kb_image_chunk WHERE generation=? ORDER BY ordinal',[generation]); const chunks: ImageChunk[] = [];
    try { while (rows.goToNextRow()) {
      const c: ImageChunk = new ImageChunk(); c.id = rows.getString(0); c.documentId = rows.getString(1); c.generation = rows.getString(2); c.ordinal = imageStoreNumber(rows,3); c.text = rows.getString(4); c.inputHash = rows.getString(5); c.locator = imageReadLocator(new BoundedDocumentJson(pdfCodecUtf8(rows.getString(6)),new KnowledgeCancellation()).read());
      const block = snapshot.blocks.find((b: ImageOcrBlock): boolean => b.id === c.locator.blockId);
      if (c.ordinal !== chunks.length || chunks.length >= ImageLimits.chunks || !imageHash(c.inputHash) || c.locator.end-c.locator.start !== c.text.length || block === undefined || block.text.slice(c.locator.start,c.locator.end) !== c.text || c.locator.originalHash !== snapshot.original.hash || await this.identity.hash(pdfCodecUtf8(c.text)) !== c.inputHash) { throw new ImageKnowledgeFailure('ImageChunkReadInvalid','image-read'); } chunks.push(c);
    } } finally { rows.close(); } return chunks;
  }
  async prepare(job: ImageJob, snapshot: ImageSnapshot, chunks: ImageChunk[]): Promise<void> {
    if (snapshot.generation !== job.generation || snapshot.documentId !== job.documentId || snapshot.original.assetId !== job.originalAssetId || snapshot.coverage.hash !== job.reportHash || snapshot.contentHash !== job.snapshotHash || !snapshot.coverage.fullDocument || snapshot.coverage.unknown !== 0 || snapshot.coverage.excluded !== 0 || snapshot.coverage.issues.length !== 0 || !imageHash(snapshot.contentHash) || !imageHash(snapshot.coverage.hash) || chunks.length > ImageLimits.chunks || (chunks.length === 0) !== (snapshot.blocks.length === 0)) { throw new ImageKnowledgeFailure('ImagePrepareCoverageOrBinding','image-prepare'); }
    const wire: string = JSON.stringify(snapshot); const reservedBytes: number = pdfCodecUtf8(wire).length*3+chunks.length*12288+1048576;
    if (this.snapshotAssets === undefined) { throw new ImageKnowledgeFailure('SnapshotAssetPortMissing','image-prepare'); }
    if (this.physical !== undefined) { await this.reserve('snapshot-'+job.id,job.id,reservedBytes); }
    try {
      const plannedAsset: string = 'snapshot-'+snapshot.generation;
      await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
        await this.assertJobDocument(tx,job);
        const prior = await tx.querySql('SELECT hash,owner,generation FROM kb_image_asset WHERE id=?',[plannedAsset]); let found: boolean = false;
        try { if (prior.goToNextRow()) { found = true; if (prior.getString(0) !== snapshot.contentHash || prior.getString(1) !== 'ImageSnapshotAssets' || prior.getString(2) !== job.generation) { throw new ImageKnowledgeFailure('SnapshotAssetOwnerConflict','image-prepare'); } } } finally { prior.close(); }
        if (!found) { await tx.execute('INSERT INTO kb_image_asset VALUES(?,?,?,?,?,?,?,?)',[plannedAsset,job.documentId,'ImageSnapshotAssets',snapshot.contentHash,pdfCodecUtf8(wire).length,job.generation,'SnapshotPreparing',1]); }
      });
      const asset: string = await this.snapshotAssets.save(snapshot,new KnowledgeCancellation());
      if (asset !== plannedAsset) { throw new ImageKnowledgeFailure('SnapshotAssetPublicationIdentity','image-prepare'); }
      await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJobDocument(tx,job); await imagePublicationBudget(tx,job.documentId,chunks.length);
      const rows: relationalStore.ResultSet = await tx.querySql('SELECT state,hash FROM kb_image_generation WHERE id=? AND epoch=? AND doc=?',[job.generation,job.epoch,job.documentId]);
      try { if (!rows.goToNextRow() || rows.getString(0) !== 'Staging') { throw new ImageKnowledgeFailure('ImageCandidateNotStaging','image-prepare'); } } finally { rows.close(); }
      for (const c of chunks) {
        if (c.documentId !== job.documentId || c.generation !== job.generation || !imageHash(c.inputHash) || c.locator.originalAssetId !== job.originalAssetId) { throw new ImageKnowledgeFailure('ImageChunkBinding','image-prepare'); }
        await tx.execute('INSERT INTO kb_image_chunk VALUES(?,?,?,?,?,?,?)',[c.id,c.documentId,c.generation,c.ordinal,c.text,c.inputHash,JSON.stringify(c.locator)]);
      }
      await tx.execute('UPDATE kb_image_generation SET state=?,wire=?,hash=?,report=?,expected=? WHERE id=?',['Prepared',asset,snapshot.contentHash,snapshot.coverage.hash,chunks.length,job.generation]);
      await tx.execute("UPDATE kb_image_asset SET role='Snapshot' WHERE id=? AND owner='ImageSnapshotAssets' AND hash=?",[asset,snapshot.contentHash]);
      await tx.execute('UPDATE kb_image_job SET stage=?,checkpoint=?,snapshot=?,report=? WHERE id=?',[ImageIngestionStage.Review,ImageIngestionStage.Review,job.snapshotHash,job.reportHash,job.id]);
    }); } finally { if (this.physical !== undefined) { await this.releaseReservation('snapshot-'+job.id,job.id); } }
  }
  async publish(job: ImageJob, reportHash: string): Promise<boolean> {
    let published: boolean = false;
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJobDocument(tx,job);
      const rows: relationalStore.ResultSet = await tx.querySql('SELECT expected,wire FROM kb_image_generation WHERE id=? AND doc=? AND original=? AND epoch=? AND state=? AND hash=? AND report=?',[job.generation,job.documentId,job.originalAssetId,job.epoch,'Prepared',job.snapshotHash,reportHash]);
      let expected: number = 0;
      try { if (!rows.goToNextRow() || reportHash !== job.reportHash) { return; } expected = imageStoreNumber(rows,0); const snapshot = await this.snapshot(job.generation); if (expected === 0 && snapshot.coverage.empty < 1) { throw new ImageKnowledgeFailure('NoTextEvidenceMissing','image-publish'); } } finally { rows.close(); }
      await imagePublicationBudget(tx,job.documentId,expected);
      const count: relationalStore.ResultSet = await tx.querySql('SELECT count(*) FROM kb_image_chunk WHERE generation=?',[job.generation]); try { if (!count.goToNextRow() || count.getLong(0) !== expected) { throw new ImageKnowledgeFailure('ImageChunkCoverageIncomplete','image-publish'); } } finally { count.close(); }
      const stage: ImageIngestionStage = expected === 0 ? ImageIngestionStage.Empty : ImageIngestionStage.Published;
      await tx.execute("UPDATE kb_image_generation SET state='Retained' WHERE doc=? AND state='Active'",[job.documentId]);
      await tx.execute("UPDATE kb_image_generation SET state='Active' WHERE id=?",[job.generation]);
      await tx.execute("UPDATE kb_image_vector SET state='Retained' WHERE doc=? AND state='SemanticReady'",[job.documentId]); await tx.execute("UPDATE kb_image_vector_mirror SET state='Invalid' WHERE doc=?",[job.documentId]);
      await tx.execute('UPDATE kb_image_document SET active_original=?,active_generation=?,chunks=?,stage=? WHERE id=?',[job.originalAssetId,job.generation,expected,stage,job.documentId]);
      await tx.execute('UPDATE kb_image_job SET stage=?,checkpoint=? WHERE id=?',[stage,stage,job.id]); published = true;
    }); return published;
  }
  async directCandidates(input: TextQueryInput, archived: boolean, _extras: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeHit[]> {
    const hits: KnowledgeHit[] = []; let scanned: number = 0;
    for (const document of await this.list()) {
      cancel.check(); if (document.tombstone || !archived && document.archived || document.activeGeneration.length === 0) { continue; }
      const snapshot = await this.snapshot(document.activeGeneration); const chunks = await this.chunks(document.activeGeneration);
      if (chunks.length !== document.chunkCount || snapshot.original.assetId !== document.activeOriginal) { throw new ImageKnowledgeFailure('ImageActiveCoverageIncomplete','image-scan'); }
      for (const c of chunks) {
        cancel.check(); if (++scanned > ImageLimits.activeChunks) { throw new ImageKnowledgeFailure('ImageActiveScanBudget','image-scan'); }
        const score: number = knowledgeLiteralScore(c.text,input); if (score === 0) { continue; }
        const hit: KnowledgeHit = new KnowledgeHit(); hit.id = 'image:'+c.id; hit.documentId = document.id; hit.sourceKind = KnowledgeSourceKind.Image; hit.actualFormat = snapshot.original.header.encoding;
        hit.chunkId = c.id; hit.generation = c.generation; hit.snapshotId = snapshot.generation; hit.snapshotHash = snapshot.contentHash; hit.originalHash = snapshot.original.hash; hit.originalVersion = snapshot.original.version;
        hit.title = document.title; hit.text = c.text; hit.retrievalText = c.text; hit.locator.kind = KnowledgeSourceKind.Image; hit.locator.image = c.locator; hit.channels = [KnowledgeChannel.Keyword]; hit.keywordScore = score; hit.epoch = document.epoch; hits.push(hit);
      }
    } return hits;
  }
  async visible(hit: KnowledgeHit, archived: boolean): Promise<boolean> {
    const doc = await this.get(hit.documentId); if (doc === undefined || doc.tombstone || !archived && doc.archived || doc.activeGeneration !== hit.generation || doc.epoch !== hit.epoch) { return false; }
    const original = await this.original(doc.activeOriginal); return original.hash === hit.originalHash && original.version === hit.originalVersion;
  }
  async acquireRead(lease: ImageReadLease): Promise<void> {
    if (!imageIdentity(lease.id) || !imageIdentity(lease.owner)) { throw new ImageKnowledgeFailure('LeaseIdentity', 'image-read'); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const rows: relationalStore.ResultSet = await tx.querySql('SELECT a.id FROM kb_image_asset a JOIN kb_image_document d ON d.id=a.doc WHERE a.id=? AND a.doc=? AND a.pins>0 AND d.epoch=? AND d.tombstone=0',[lease.assetId,lease.documentId,lease.epoch]);
      try { if (!rows.goToNextRow()) { throw new ImageKnowledgeFailure('OriginalReadIneligible', 'image-read'); } } finally { rows.close(); }
      await tx.execute('INSERT INTO kb_image_lease VALUES(?,?,?,?,?)',[lease.id,lease.documentId,lease.assetId,lease.owner,lease.epoch]);
    });
  }
  async releaseRead(receipt: ImageReleaseReceipt): Promise<void> {
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const complete: boolean = receipt.failure.length === 0 && [receipt.pixel,receipt.source,receipt.file].every((state: string): boolean => state === 'Released' || state === 'NotAcquired');
      await tx.execute('INSERT OR REPLACE INTO kb_image_release VALUES(?,?,?,?,?,?)',[receipt.leaseId,receipt.pixel,receipt.source,receipt.file,complete ? 'Released' : 'Held',receipt.failure]);
      if (complete) { await tx.execute('DELETE FROM kb_image_lease WHERE id=?',[receipt.leaseId]); }
    });
  }
  async archive(id: string, archived: boolean): Promise<void> {
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await tx.execute('UPDATE kb_image_document SET archived=?,epoch=epoch+1 WHERE id=? AND tombstone=0',[archived ? 1 : 0,id]);
      await tx.execute("UPDATE kb_image_vector SET epoch=(SELECT epoch FROM kb_image_document WHERE id=?) WHERE doc=? AND state='SemanticReady'",[id,id]);
      await tx.execute("UPDATE kb_image_vector_mirror SET epoch=(SELECT epoch FROM kb_image_document WHERE id=?),revision=revision+1,state='Pending' WHERE doc=?",[id,id]);
    });
  }
  async deleteDocument(id: string): Promise<void> {
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await tx.execute('UPDATE kb_image_document SET tombstone=1,epoch=epoch+1,stage=? WHERE id=? AND tombstone=0',[ImageIngestionStage.Deleted,id]);
      await tx.execute("UPDATE kb_image_generation SET state='Retained' WHERE doc=?",[id]);
      await tx.execute("UPDATE kb_image_vector SET state='Retiring' WHERE doc=?",[id]); await tx.execute("UPDATE kb_image_vector_mirror SET state='Invalid' WHERE doc=?",[id]);
      await tx.execute("INSERT OR IGNORE INTO kb_image_cleanup SELECT 'delete-'||id,doc,id,owner,'Pending','' FROM kb_image_asset WHERE doc=?",[id]);
    });
  }
  async cleanups(): Promise<ImageCleanupIntent[]> {
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT * FROM kb_image_cleanup ORDER BY id'); const intents: ImageCleanupIntent[] = [];
    try { while (rows.goToNextRow()) { const c: ImageCleanupIntent = new ImageCleanupIntent(); c.id = rows.getString(0); c.documentId = rows.getString(1); c.assetId = rows.getString(2); c.owner = rows.getString(3); c.state = rows.getString(4); c.failure = rows.getString(5); intents.push(c); } } finally { rows.close(); } return intents;
  }
  async assertUnpinned(assets: string[]): Promise<void> {
    for (const asset of assets) {
      const rows = await this.store().querySql('SELECT (SELECT count(*) FROM kb_image_asset WHERE id=? AND pins>0)+(SELECT count(*) FROM kb_image_lease WHERE asset=?)',[asset,asset]);
      try { if (!rows.goToNextRow() || rows.getLong(0) !== 0) { throw new ImageKnowledgeFailure('ImageAssetPinnedOrRead','image-cleanup'); } } finally { rows.close(); }
    }
  }
  async claimCleanup(id: string): Promise<ImageCleanupIntent | undefined> {
    let claimed: ImageCleanupIntent | undefined = undefined;
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const rows = await tx.querySql("SELECT c.id,c.doc,c.asset,c.owner,c.state,c.failure FROM kb_image_cleanup c JOIN kb_image_document d ON d.id=c.doc JOIN kb_image_asset a ON a.id=c.asset AND a.owner=c.owner WHERE c.id=? AND d.tombstone=1 AND NOT EXISTS(SELECT 1 FROM kb_image_lease l WHERE l.doc=c.doc) AND NOT EXISTS(SELECT 1 FROM kb_image_vector v WHERE v.doc=c.doc AND v.state<>'Removed')",[id]);
      try { if (!rows.goToNextRow()) { return; } const c: ImageCleanupIntent = new ImageCleanupIntent(); c.id = rows.getString(0); c.documentId = rows.getString(1); c.assetId = rows.getString(2); c.owner = rows.getString(3); c.state = rows.getString(4); c.failure = rows.getString(5); if (c.owner !== 'DocumentParseService' && c.owner !== 'ImageSnapshotAssets') { throw new ImageKnowledgeFailure('UnknownAssetOwnerQuarantined','image-cleanup'); } claimed = c; } finally { rows.close(); }
      await this.host.assertUnifiedUnheld(claimed?.owner ?? '',[claimed?.assetId ?? '']);
      await tx.execute("UPDATE kb_image_cleanup SET state='Claimed' WHERE id=?",[id]);
      await tx.execute('UPDATE kb_image_asset SET pins=0 WHERE id=? AND owner=?',[claimed?.assetId ?? '',claimed?.owner ?? '']);
    }); return claimed;
  }
  async finishCleanup(c: ImageCleanupIntent, failure: string): Promise<void> {
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await tx.execute('UPDATE kb_image_cleanup SET state=?,failure=? WHERE id=? AND owner=?',[failure.length === 0 ? 'Done' : 'Pending',failure,c.id,c.owner]);
      if (failure.length === 0) {
        await tx.execute('DELETE FROM kb_image_asset WHERE id=? AND pins=0 AND owner=?',[c.assetId,c.owner]); await tx.execute('DELETE FROM kb_image_chunk WHERE doc=?',[c.documentId]);
        await tx.execute('DELETE FROM kb_image_vector_input WHERE generation IN (SELECT id FROM kb_image_vector WHERE doc=? AND state=?)',[c.documentId,'Removed']);
        await tx.execute('DELETE FROM kb_image_vector WHERE doc=? AND state=?',[c.documentId,'Removed']);
        await tx.execute("UPDATE kb_image_generation SET wire='',state='Removed' WHERE doc=? AND NOT EXISTS(SELECT 1 FROM kb_image_asset WHERE doc=?)",[c.documentId,c.documentId]);
      }
    });
  }
  async removeSnapshotClaim(claim: ImageCleanupIntent): Promise<void> {
    if (claim.owner !== 'ImageSnapshotAssets' || this.snapshotAssets === undefined) { throw new ImageKnowledgeFailure('SnapshotOwnerRequired','image-cleanup'); }
    const rows = await this.store().querySql("SELECT id FROM kb_image_cleanup WHERE id=? AND asset=? AND owner=? AND state='Claimed'",[claim.id,claim.assetId,claim.owner]);
    try { if (!rows.goToNextRow()) { throw new ImageKnowledgeFailure('SnapshotCleanupClaimMissing','image-cleanup'); } } finally { rows.close(); }
    await this.snapshotAssets.remove(claim.assetId);
  }
}
