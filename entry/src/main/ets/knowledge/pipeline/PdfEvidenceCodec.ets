import { PdfMappingEvidence, PdfMappingTier, PdfBox, KnowledgeFailure, KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { BoundedDocumentJson, PdfJsonNode } from './BoundedDocumentJson';
import { pdfCodecUtf8 } from './PdfSnapshotCodec';
function pdfEvidenceBox(raw: PdfJsonNode): PdfBox {
  const box: PdfBox = new PdfBox(); box.left = raw.required('left').numeric; box.top = raw.required('top').numeric; box.right = raw.required('right').numeric; box.bottom = raw.required('bottom').numeric;
  for (const name of ['left','top','right','bottom']) { if (raw.required(name).kind !== 'number') { throw new KnowledgeFailure('EvidenceBoxType','codec'); } } return box;
}
export function pdfDecodeEvidence(wire: string): PdfMappingEvidence {
  const raw: PdfJsonNode = new BoundedDocumentJson(pdfCodecUtf8(wire),new KnowledgeCancellation()).read(); const item: PdfMappingEvidence = new PdfMappingEvidence();
  item.wire = raw.required('wire').string(); item.id = raw.required('id').string(); const tier: string = raw.required('tier').string();
  if (item.wire !== 'PDF-MAPPING-1' || (tier !== PdfMappingTier.Page && tier !== PdfMappingTier.Region)) { throw new KnowledgeFailure('EvidenceWire','codec'); } item.tier = tier === PdfMappingTier.Page ? PdfMappingTier.Page : PdfMappingTier.Region;
  item.originalHash = raw.required('originalHash').string(); item.originalVersion = raw.required('originalVersion').integer(); item.zipHash = raw.required('zipHash').string(); item.snapshotHash = raw.required('snapshotHash').string(); item.snapshotId = raw.required('snapshotId').string(); item.generation = raw.required('generation').string(); item.nodeId = raw.required('nodeId').string(); item.protocol = raw.required('protocol').string();
  item.providerPageIndex0 = raw.required('providerPageIndex0').integer(); item.originalPageIndex0 = raw.required('originalPageIndex0').integer(); item.rotation = raw.required('rotation').integer();
  item.unit = raw.required('unit').string(); item.origin = raw.required('origin').string(); item.referenceBox = raw.required('referenceBox').string(); item.transformVersion = raw.required('transformVersion').string(); item.evidenceSource = raw.required('evidenceSource').string();
  item.media = pdfEvidenceBox(raw.required('media')); item.crop = pdfEvidenceBox(raw.required('crop')); const boxes: PdfJsonNode[] = raw.required('points').array();
  if (boxes.length > 64) { throw new KnowledgeFailure('EvidenceRegionBudget','codec'); } item.points = boxes.map((box: PdfJsonNode): PdfBox => pdfEvidenceBox(box)); return item;
}
