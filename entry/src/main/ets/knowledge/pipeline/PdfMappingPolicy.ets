import { PdfLocator, PdfMappingEvidence, PdfMappingTier, PdfBox, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { PdfEvidenceContext } from '../domain/PdfLocalModels';

export function pdfEvidenceValid(item: PdfMappingEvidence, context: PdfEvidenceContext): boolean {
  if (![context.originalHash,context.zipHash,context.snapshotHash].every((hash: string): boolean => new RegExp('^[a-f0-9]{64}$').test(hash)) || context.originalVersion < 1 || !Number.isSafeInteger(context.originalVersion) || context.generation.length === 0 || context.snapshotId.length === 0 || context.nodeId.length === 0 || context.protocol.length === 0 || context.providerPage < 0 || context.providerPage >= context.originalPages) { return false; }
  if (item.wire !== 'PDF-MAPPING-1' || item.id.length === 0 || item.evidenceSource.length === 0 || item.originalHash !== context.originalHash || item.originalVersion !== context.originalVersion || item.zipHash !== context.zipHash || item.snapshotHash !== context.snapshotHash || item.snapshotId !== context.snapshotId || item.generation !== context.generation || item.nodeId !== context.nodeId || item.protocol !== context.protocol || item.providerPageIndex0 !== context.providerPage || item.originalPageIndex0 < 0 || item.originalPageIndex0 >= context.originalPages || item.unit !== 'Points' || item.origin !== 'BottomLeftYUp' || item.referenceBox !== 'CropBox' || item.rotation !== context.rotation || item.transformVersion !== 'PDF-CROP-ROTATE-1') { return false; }
  for (const pair of [[item.media,context.media],[item.crop,context.crop]]) { if (pair[0].left !== pair[1].left || pair[0].top !== pair[1].top || pair[0].right !== pair[1].right || pair[0].bottom !== pair[1].bottom) { return false; } }
  if ([0,90,180,270].indexOf(context.rotation) < 0 || context.crop.right <= context.crop.left || context.crop.top <= context.crop.bottom || context.crop.left < context.media.left || context.crop.right > context.media.right || context.crop.bottom < context.media.bottom || context.crop.top > context.media.top) { return false; }
  if (item.tier !== PdfMappingTier.Page && item.tier !== PdfMappingTier.Region) { return false; }
  if (item.tier === PdfMappingTier.Region && (item.points.length < 1 || item.points.length > 64)) { return false; }
  return item.points.every((box: PdfBox): boolean => [box.left,box.right,box.top,box.bottom].every((v: number): boolean => Number.isFinite(v)) && box.left >= context.crop.left && box.right <= context.crop.right && box.bottom >= context.crop.bottom && box.top <= context.crop.top && box.left < box.right && box.bottom < box.top);
}
export function pdfEvidenceLocator(locator: PdfLocator, evidence: PdfMappingEvidence[], context?: PdfEvidenceContext): PdfLocator {
  const result: PdfLocator = new PdfLocator(); result.originalHash = locator.originalHash; result.originalVersion = locator.originalVersion;
  result.providerPageIndex0 = locator.providerPageIndex0; result.candidatePhysicalPageIndex0 = locator.candidatePhysicalPageIndex0;
  result.printedLabel = locator.printedLabel; result.providerBoxes = locator.providerBoxes.slice(); result.coordinateSpace = locator.coordinateSpace;
  if (context === undefined || context.originalHash !== locator.originalHash || context.originalVersion !== locator.originalVersion || context.providerPage !== locator.providerPageIndex0) { return result; }
  const page: PdfMappingEvidence | undefined = evidence.find((item: PdfMappingEvidence): boolean => pdfEvidenceValid(item,context));
  if (page === undefined) { return result; }
  result.tier = PdfMappingTier.Page; result.pageEvidenceId = page.id; result.candidatePhysicalPageIndex0 = page.originalPageIndex0;
  const regions: PdfMappingEvidence[] = evidence.filter((item: PdfMappingEvidence): boolean => item.tier === PdfMappingTier.Region && item.originalPageIndex0 === page.originalPageIndex0 && pdfEvidenceValid(item,context));
  if (regions.length > 0) { result.tier = PdfMappingTier.Region; result.regionEvidenceIds = regions.map((item: PdfMappingEvidence): string => item.id); } return result;
}
export function pdfDisplayRegions(item: PdfMappingEvidence, context: PdfEvidenceContext): PdfBox[] {
  if (!pdfEvidenceValid(item,context) || item.tier !== PdfMappingTier.Region) { throw new KnowledgeFailure('MappingEvidenceInvalid','mapping'); }
  const output: PdfBox[] = []; const w: number = context.crop.right-context.crop.left; const h: number = context.crop.top-context.crop.bottom;
  for (const box of item.points) {
    const xs: number[] = []; const ys: number[] = [];
    for (const x of [box.left,box.right]) { for (const y of [box.bottom,box.top]) {
      const nx: number = (x-context.crop.left)/w; const ny: number = (context.crop.top-y)/h;
      xs.push(context.rotation === 90 ? 1-ny : context.rotation === 180 ? 1-nx : context.rotation === 270 ? ny : nx);
      ys.push(context.rotation === 90 ? nx : context.rotation === 180 ? 1-ny : context.rotation === 270 ? 1-nx : ny);
    } }
    const rect: PdfBox = new PdfBox(); rect.left = Math.min(...xs); rect.right = Math.max(...xs); rect.top = Math.min(...ys); rect.bottom = Math.max(...ys); output.push(rect);
  } return output;
}
