import { common } from '@kit.AbilityKit';
import { pdfService } from '@kit.PDFKit';
import { fileIo } from '@kit.CoreFileKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { PdfMappingEvidence, PdfMappingTier, PdfBox, KnowledgeFailure, KnowledgeCancellation, PdfKnowledgeDocument, PdfIngestionJob, KnowledgePin, PdfStage } from '../domain/PdfKnowledgeModels';
import { PdfEvidenceContext } from '../domain/PdfLocalModels';
import { pdfEvidenceValid, pdfDisplayRegions } from '../pipeline/PdfMappingPolicy';
import { pdfDecodeEvidence } from '../pipeline/PdfEvidenceCodec';
import { PdfKnowledgeRepository } from '../infra/PdfKnowledgeRepository';
import { documentEnsureDirectory, documentHashFile } from '../infra/DocumentFileOperations';
import { DocumentParseCancellation } from '../domain/DocumentParseModels';
import { KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';

export async function pdfMappingFixtureCase(context: common.Context, scope: KnowledgeStorageScope, repository: PdfKnowledgeRepository, proof: PdfEvidenceContext): Promise<void> {
  scope.requireTestOwner(scope.key); const root: string = `${context.cacheDir}/${scope.derivedDirectory}`; await documentEnsureDirectory(root);
  const path: string = `${root}/mapping-fixture.pdf`; const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
  try {
    if (!doc.createDocument(300,500)) { throw new KnowledgeFailure('FixturePdfCreate','suite'); }
    const page: pdfService.PdfPage = doc.getPage(0); const crop: pdfService.PdfRect = new pdfService.PdfRect(); crop.left = 20; crop.bottom = 30; crop.right = 220; crop.top = 430;
    page.setBox(pdfService.BoxType.BOX_CROP,crop); page.setRotation(pdfService.RotationAngle.ANGLE_90);
    if (!doc.saveDocument(path)) { throw new KnowledgeFailure('FixturePdfSave','suite'); }
  } finally { doc.releaseDocument(); }
  const reopened: pdfService.PdfDocument = new pdfService.PdfDocument();
  const identity: KnowledgePlatformIdentity = new KnowledgePlatformIdentity(); const job: PdfIngestionJob = new PdfIngestionJob();
  try {
    if (reopened.loadDocument(path) !== pdfService.ParseResult.PARSE_SUCCESS) { throw new KnowledgeFailure('FixturePdfReopen','suite'); }
    const page: pdfService.PdfPage = reopened.getPage(0); const crop: pdfService.PdfRect = page.getBox(pdfService.BoxType.BOX_CROP); const media: pdfService.PdfRect = page.getBox(pdfService.BoxType.BOX_MEDIA);
    if (crop.left !== 20 || crop.bottom !== 30 || crop.right !== 220 || crop.top !== 430 || page.getRotation() !== pdfService.RotationAngle.ANGLE_90) { throw new KnowledgeFailure('FixturePdfGeometry','suite'); }
    const hash: string = await documentHashFile(path,20971520,new DocumentParseCancellation());
    const document: PdfKnowledgeDocument = new PdfKnowledgeDocument(); document.id = identity.id(); document.sourceKey = `mapping-${scope.key}`; document.binding.originalHash = hash; document.binding.originalId = `mapping-${scope.key}`; document.binding.originalAssetId = 'original-mapping'; document.binding.originalVersion = 1; document.binding.originalBytes = (await fileIo.stat(path)).size; document.binding.originalPages = 1; document.binding.resultAssetId = 'result-mapping'; document.binding.zipHash = '6'.repeat(64); document.binding.zipBytes = 128;
    job.id = identity.id(); job.generation = identity.id(); job.documentId = document.id; job.sourceId = document.binding.originalId; job.binding = document.binding; job.ownerSession = scope.key; job.processingKey = document.sourceKey;
    const pins: KnowledgePin[] = [];
    for (let at: number = 0; at < 2; at++) { const pin: KnowledgePin = new KnowledgePin(); pin.id = identity.id(); pin.sourceId = job.sourceId; pin.assetId = at === 0 ? document.binding.originalAssetId : document.binding.resultAssetId; pin.assetHash = at === 0 ? hash : document.binding.zipHash; pin.ownerId = job.id; pin.documentId = document.id; pin.generation = job.generation; pins.push(pin); }
    await repository.register(document,job,pins); job.snapshotId = identity.id(); job.snapshotHash = '5'.repeat(64); job.reportHash = '4'.repeat(64); job.stage = PdfStage.Review; job.checkpoint = PdfStage.Review; await repository.checkpoint(job);
    proof.originalHash = hash; proof.originalVersion = 1; proof.zipHash = document.binding.zipHash; proof.snapshotHash = job.snapshotHash; proof.snapshotId = job.snapshotId; proof.generation = job.generation;
    proof.rotation = 90; proof.originalPages = 1; proof.providerPage = 0; proof.media.left = media.left; proof.media.top = media.top; proof.media.right = media.right; proof.media.bottom = media.bottom;
    proof.crop.left = crop.left; proof.crop.top = crop.top; proof.crop.right = crop.right; proof.crop.bottom = crop.bottom;
    const item: PdfMappingEvidence = new PdfMappingEvidence(); item.id = `fixture-${scope.key}`; item.tier = PdfMappingTier.Region; item.originalHash = proof.originalHash; item.originalVersion = proof.originalVersion; item.zipHash = proof.zipHash; item.snapshotHash = proof.snapshotHash; item.snapshotId = proof.snapshotId; item.generation = proof.generation; item.nodeId = proof.nodeId; item.protocol = proof.protocol; item.providerPageIndex0 = 0; item.originalPageIndex0 = 0;
    item.unit = 'Points'; item.origin = 'BottomLeftYUp'; item.referenceBox = 'CropBox'; item.rotation = 90; item.transformVersion = 'PDF-CROP-ROTATE-1'; item.evidenceSource = 'IndependentSyntheticGold-1'; item.crop = proof.crop; item.media = proof.media;
    const first: PdfBox = new PdfBox(); first.left = 40; first.bottom = 70; first.right = 80; first.top = 150;
    const second: PdfBox = new PdfBox(); second.left = 120; second.bottom = 230; second.right = 180; second.top = 350; item.points = [first,second];
    const decoded: PdfMappingEvidence = pdfDecodeEvidence(JSON.stringify(item)); const regions: PdfBox[] = pdfDisplayRegions(decoded,proof);
    const golden: number[][] = [[0.1,0.1,0.3,0.3],[0.5,0.5,0.8,0.8]];
    for (let at: number = 0; at < 2; at++) { const values: number[] = [regions[at].left,regions[at].top,regions[at].right,regions[at].bottom]; for (let n: number = 0; n < 4; n++) { if (Math.abs(values[n]-golden[at][n]) > 0.00001) { throw new KnowledgeFailure('IndependentRegionGoldMismatch','suite'); } } }
    const rotations: number[] = [0,90,180,270];
    const allGold: number[][][] = [[[0.1,0.7,0.3,0.9],[0.5,0.2,0.8,0.5]],golden,[[0.7,0.1,0.9,0.3],[0.2,0.5,0.5,0.8]],[[0.7,0.7,0.9,0.9],[0.2,0.2,0.5,0.5]]];
    for (let rotation: number = 0; rotation < rotations.length; rotation++) {
      const goldItem: PdfMappingEvidence = pdfDecodeEvidence(JSON.stringify(item)); goldItem.rotation = rotations[rotation]; proof.rotation = rotations[rotation];
      const transformed: PdfBox[] = pdfDisplayRegions(goldItem,proof);
      for (let box: number = 0; box < 2; box++) { const values: number[] = [transformed[box].left,transformed[box].top,transformed[box].right,transformed[box].bottom]; for (let at: number = 0; at < 4; at++) { if (Math.abs(values[at]-allGold[rotation][box][at]) > 0.00001) { throw new KnowledgeFailure('RotationGoldMismatch','suite'); } } }
    } proof.rotation = 90;
    await repository.saveEvidence(decoded,proof); const stored: PdfMappingEvidence[] = await repository.evidence(proof.generation,proof.nodeId);
    if (stored.length !== 1 || stored[0].points.length !== 2) { throw new KnowledgeFailure('EvidenceReadback','suite'); }
    decoded.snapshotHash = 'f'.repeat(64); if (pdfEvidenceValid(decoded,proof)) { throw new KnowledgeFailure('StaleEvidenceAccepted','suite'); }
    let rejected: boolean = false; try { await repository.saveEvidence(decoded,proof); } catch { rejected = true; } if (!rejected) { throw new KnowledgeFailure('InvalidEvidenceStored','suite'); }
    await repository.removeEvidence(item.id,proof.generation); if ((await repository.evidence(proof.generation,proof.nodeId)).length !== 0) { throw new KnowledgeFailure('EvidenceDeleteFailed','suite'); }
    await repository.abandon(job.id);
  } finally { reopened.releaseDocument(); scope.requireTestOwner(scope.key); await fileIo.unlink(path); }
}
