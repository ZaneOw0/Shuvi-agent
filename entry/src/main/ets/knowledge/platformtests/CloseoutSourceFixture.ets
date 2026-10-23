import { common } from '@kit.AbilityKit';
import { pdfService } from '@kit.PDFKit';
import { fileIo } from '@kit.CoreFileKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { KnowledgeStoreHost } from '../infra/KnowledgeStoreHost';
import { TextRdbRepository } from '../infra/TextRdbRepository';
import { PdfKnowledgeRepository } from '../infra/PdfKnowledgeRepository';
import { PdfAssetAdapter } from '../infra/PdfAssetAdapter';
import { PdfPageAdapter } from '../infra/PdfPageAdapter';
import { PdfSourceSession } from '../infra/PdfSourceSession';
import { KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';
import { documentEnsureDirectory, documentHashFile } from '../infra/DocumentFileOperations';
import { DocumentParseCancellation } from '../domain/DocumentParseModels';
import { PdfSourceBinding, PdfKnowledgeDocument, PdfIngestionJob, KnowledgePin, KnowledgeReadLease, PdfStage, PdfNormalizedDocument, PdfContentNode, PdfNodeKind, PdfTable, PdfTableCell, KnowledgeCancellation, PdfMappingEvidence, PdfMappingTier, PdfBox, PdfLocator } from '../domain/PdfKnowledgeModels';
export class CloseoutSourceFixture {
  scope: KnowledgeStorageScope; context: common.Context; host: KnowledgeStoreHost; text: TextRdbRepository; pdf: PdfKnowledgeRepository; assets: PdfAssetAdapter;
  binding: PdfSourceBinding = new PdfSourceBinding(); adapter: PdfPageAdapter; session: PdfSourceSession = new PdfSourceSession(); snapshot: PdfNormalizedDocument = new PdfNormalizedDocument(); locator: PdfLocator = new PdfLocator(); job: PdfIngestionJob = new PdfIngestionJob();
  constructor(context: common.Context, scope: KnowledgeStorageScope) { this.scope = scope; this.context = context; this.host = KnowledgeStoreHost.forContext(context,scope); this.text = new TextRdbRepository(context,this.host); this.pdf = new PdfKnowledgeRepository(this.host); this.assets = new PdfAssetAdapter(context.filesDir,context.cacheDir,this.pdf,scope); this.adapter = new PdfPageAdapter(context.filesDir); }
  async prepare(): Promise<void> {
    const id = new KnowledgePlatformIdentity(); const root = `${this.context.cacheDir}/source_r2_${this.scope.key}`; await documentEnsureDirectory(root); const path = `${root}/original-source-fixture`; const original = new pdfService.PdfDocument();
    try { if (!original.createDocument(300,500)) { throw new Error('FixtureCreate'); } const page = original.getPage(0); const crop = new pdfService.PdfRect(); crop.left = 20; crop.bottom = 30; crop.right = 220; crop.top = 430; page.setBox(pdfService.BoxType.BOX_CROP,crop); page.setRotation(pdfService.RotationAngle.ANGLE_90); if (!original.saveDocument(path)) { throw new Error('FixtureSave'); } } finally { original.releaseDocument(); }
    this.binding.originalId = 'closeout-source'; this.binding.originalAssetId = 'original-source-fixture'; this.binding.originalHash = await documentHashFile(path,20971520,new DocumentParseCancellation()); this.binding.originalVersion = 1; this.binding.originalPages = 1; this.binding.originalBytes = (await fileIo.stat(path)).size; this.binding.resultAssetId = 'result-closeout'; this.binding.zipHash = 'b'.repeat(64); this.binding.zipBytes = 128;
    await this.text.open(); await this.pdf.open(); await this.pdf.reconcile(this.scope.key); const document = new PdfKnowledgeDocument(); document.id = id.id(); document.sourceKey = this.scope.key; document.binding = this.binding;
    const job = this.job; job.id = id.id(); job.documentId = document.id; job.generation = id.id(); job.sourceId = this.binding.originalId; job.binding = this.binding; job.ownerSession = this.scope.key; job.processingKey = this.scope.key;
    const pins: KnowledgePin[] = []; for (let at: number = 0; at < 2; at++) { const pin = new KnowledgePin(); pin.id = id.id(); pin.ownerId = job.id; pin.documentId = document.id; pin.generation = job.generation; pin.sourceId = job.sourceId; pin.assetId = at === 0 ? this.binding.originalAssetId : this.binding.resultAssetId; pin.assetHash = at === 0 ? this.binding.originalHash : this.binding.zipHash; pins.push(pin); } await this.pdf.register(document,job,pins);
    const snap = this.snapshot; snap.id = id.id(); snap.documentId = document.id; snap.generation = job.generation; snap.binding = this.binding; snap.hash = 'c'.repeat(64); snap.coverage.hardPassed = true; snap.coverage.hash = 'd'.repeat(64); snap.coverage.snapshotHash = snap.hash;
    const formula = new PdfContentNode(); formula.id = 'source-formula'; formula.kind = PdfNodeKind.Formula; formula.pageIndex0 = 0; formula.rawLatex = 'E=mc^{2}'; formula.text = formula.rawLatex;
    const table = new PdfContentNode(); table.id = 'source-table'; table.kind = PdfNodeKind.Table; table.pageIndex0 = 0; table.table = new PdfTable(); table.table.rows = 14; table.table.columns = 2;
    for (let at: number = 0; at < 26; at++) { const cell = new PdfTableCell(); cell.id = `source-cell-${at}`; cell.row = Math.floor(at/2); cell.column = at%2; cell.rowSpan = at === 0 ? 2 : 1; cell.columnSpan = 1; cell.text = `synthetic cell ${at}`; table.table.cells.push(cell); } snap.nodes = [formula,table];
    await this.assets.save(snap,new KnowledgeCancellation()); job.snapshotId = snap.id; job.snapshotHash = snap.hash; job.reportHash = snap.coverage.hash; job.stage = PdfStage.Review; job.checkpoint = PdfStage.Review; await this.pdf.checkpoint(job);
    this.adapter.testOriginalRoot(this.scope,this.context.cacheDir); this.adapter.attachSnapshot(this.pdf,this.assets,snap.id,snap.hash); const lease = new KnowledgePlatformIdentity(); const read = new KnowledgeReadLease();
    read.id = lease.id(); read.sourceId = job.sourceId; read.generation = job.generation; read.sessionId = this.scope.key; this.adapter.attachLease(this.pdf,read); this.adapter.attachNodeIds([formula.id,table.id]); this.session.adopt(this.adapter);
  }
  async addEvidence(): Promise<void> {
    const node = this.snapshot.nodes[0]; const proof = this.adapter.evidenceContext(node,0); const item = new PdfMappingEvidence(); item.id = 'closeout-regions'; item.tier = PdfMappingTier.Region; item.originalHash = proof.originalHash; item.originalVersion = proof.originalVersion; item.zipHash = proof.zipHash; item.snapshotId = proof.snapshotId; item.snapshotHash = proof.snapshotHash; item.generation = proof.generation; item.nodeId = node.id; item.protocol = proof.protocol; item.providerPageIndex0 = 0; item.originalPageIndex0 = 0; item.unit = 'Points'; item.origin = 'BottomLeftYUp'; item.referenceBox = 'CropBox'; item.rotation = 90; item.transformVersion = 'PDF-CROP-ROTATE-1'; item.evidenceSource = 'IndependentSyntheticGold-1'; item.crop = proof.crop; item.media = proof.media;
    const a = new PdfBox(); a.left = 40; a.bottom = 70; a.right = 80; a.top = 150; const b = new PdfBox(); b.left = 120; b.bottom = 230; b.right = 180; b.top = 350; item.points = [a,b]; await this.pdf.saveEvidence(item,proof);
  }
  async close(): Promise<void> { await this.session.retry(); await this.pdf.close(); await this.text.close(); }
}
