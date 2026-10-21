import { ImageOriginal, ImageSnapshot, ImageOcrBlock, ImageParseConsent, ImageKnowledgeFailure, ImageLimits, ImageTextProjection, imageHash, imageIdentity } from '../domain/ImageKnowledgeModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { BoundedDocumentJson, PdfJsonNode, PdfJsonField } from './BoundedDocumentJson';

export const IMAGE_CONTROLLED_PROFILE: string = 'IMAGE-CONTROLLED-TEXT-1';
export const IMAGE_DOCVORTEX_PROFILE: string = 'DOCVORTEX-MIDDLE-2.0-DOCUMENTED-1';
export const IMAGE_TEXT_PROFILE: string = 'MinerU-Markdown-TextProjection-1';
export function imageNormalizeProjection(original: ImageOriginal, projection: ImageTextProjection, generation: string, cancel: KnowledgeCancellation): ImageSnapshot {
  if (projection.kind !== IMAGE_TEXT_PROFILE || !imageHash(projection.zipHash) || !imageHash(projection.memberHash) || projection.member.length < 1 || projection.member.length > 512 || !imageIdentity(projection.taskId) || !imageIdentity(projection.dataId) || projection.text.length > 2097152) { throw new ImageKnowledgeFailure('ImageProjectionBinding','image-normalize'); }
  const s: ImageSnapshot = new ImageSnapshot(); s.original = original; s.documentId = original.documentId; s.generation = generation;
  s.profile = IMAGE_TEXT_PROFILE; s.producer = 'MinerU-reported-unversioned'; s.resultHash = projection.zipHash; s.projection = projection;
  // Full coverage of the selected text member only; no claim of native table/pixel or all provider objects.
  s.coverage.fullDocument = true; let offset: number = 0;
  for (const text of projection.text.split(/\r?\n[ \t]*\r?\n/)) {
    cancel.check(); const start: number = projection.text.indexOf(text,offset); offset = start+text.length;
    if (text.trim().length === 0) { continue; }
    if (s.blocks.length >= ImageLimits.nodes) { throw new ImageKnowledgeFailure('ImageProjectionNodeBudget','image-normalize'); }
    const b: ImageOcrBlock = new ImageOcrBlock(); b.id = 'text-'+s.blocks.length; b.ordinal = s.blocks.length; b.text = text; b.sourceStart = start; b.sourceEnd = offset;
    b.locator.originalAssetId = original.assetId; b.locator.originalHash = original.hash; b.locator.originalVersion = original.version; b.locator.width = original.header.width; b.locator.height = original.header.height; b.locator.orientation = original.header.orientation;
    b.locator.blockId = b.id; b.locator.paragraph = b.ordinal+1; b.locator.end = text.length; s.blocks.push(b);
  }
  s.coverage.identified = s.blocks.length;
  if (projection.text.trim().length === 0) { s.coverage.empty = 1; }
  return s;
}
export function imageConsentReason(original: ImageOriginal, consent: ImageParseConsent, now: number, session: string, revision: number): string {
  if (consent.revoked || !consent.fullFile || !consent.free || consent.purpose !== 'ImageParse') { return 'ImageParseConsentMissing'; }
  if (consent.sourceId !== original.sourceId || consent.hash !== original.hash || consent.version !== original.version || consent.configRevision !== revision || consent.session !== session) { return 'ImageParseInputConfigOrSessionChanged'; }
  if (!Number.isSafeInteger(consent.issued) || consent.issued <= 0 || now < consent.issued || now-consent.issued >= 120000) { return 'ImageParseStartupConsentExpired'; }
  return '';
}
function imageBoolean(node: PdfJsonNode): boolean {
  if (node.kind !== 'true' && node.kind !== 'false') { throw new ImageKnowledgeFailure('BooleanRequired','image-normalize'); } return node.kind === 'true';
}
function imageFields(node: PdfJsonNode, keys: string[]): void {
  if (node.kind !== 'object' || node.fields.some((field: PdfJsonField): boolean => keys.indexOf(field.key) < 0)) { throw new ImageKnowledgeFailure('UnsupportedProfileField','image-normalize'); }
}
export function imageNormalizeContent(original: ImageOriginal, bytes: Uint8Array, profile: string, generation: string, cancel: KnowledgeCancellation): ImageSnapshot {
  const root: PdfJsonNode = new BoundedDocumentJson(bytes,cancel,2097152).read();
  if (profile === IMAGE_TEXT_PROFILE) {
    const p: ImageTextProjection = new ImageTextProjection(); p.kind = root.required('kind').string(); p.member = root.required('member').string(); p.memberHash = root.required('memberHash').string(); p.zipHash = root.required('zipHash').string(); p.taskId = root.required('taskId').string(); p.dataId = root.required('dataId').string(); p.text = root.required('text').string();
    return imageNormalizeProjection(original,p,generation,cancel);
  }
  if (profile === IMAGE_DOCVORTEX_PROFILE) {
    if (root.required('schema').string() !== 'docvortex.middle' || root.required('schema_version').string() !== '2.0') { throw new ImageKnowledgeFailure('DocvortexSchemaMismatch','image-normalize'); }
    const producer: string = root.required('metadata').required('producer').required('version').string();
    const mineru: PdfJsonNode = root.required('extensions').required('mineru'); mineru.required('tier').string(); mineru.required('parse_mode').string();
    if (!imageBoolean(root.required('is_full_document')) || producer.length === 0) { throw new ImageKnowledgeFailure('DocvortexCoverageOrProducerMissing','image-normalize'); }
    root.required('pages').array();
    throw new ImageKnowledgeFailure('DocvortexNativeBlocksOutsideTextProjectionUseMarkdownMember','image-normalize');
  }
  if (profile !== IMAGE_CONTROLLED_PROFILE) { throw new ImageKnowledgeFailure('UnknownImageProfile','image-normalize'); }
  imageFields(root,['wire','original_hash','original_version','complete','blocks']);
  if (root.required('wire').string() !== IMAGE_CONTROLLED_PROFILE || root.required('original_hash').string() !== original.hash || root.required('original_version').integer() !== original.version || !imageBoolean(root.required('complete'))) { throw new ImageKnowledgeFailure('ControlledSourceOrCoverageMismatch','image-normalize'); }
  const nodes: PdfJsonNode[] = root.required('blocks').array(); if (nodes.length > ImageLimits.nodes || !imageHash(original.hash)) { throw new ImageKnowledgeFailure('ImageNodeBudgetOrIdentity','image-normalize'); }
  const result: ImageSnapshot = new ImageSnapshot(); result.profile = profile; result.producer = 'ShuviControlledFixture-1'; result.documentId = original.documentId;
  result.original = original; result.generation = generation; result.coverage.fullDocument = true;
  for (let ordinal: number = 0; ordinal < nodes.length; ordinal++) {
    cancel.check(); const node: PdfJsonNode = nodes[ordinal]; imageFields(node,['id','ordinal','kind','text']);
    const id: string = node.required('id').string(); const kind: string = node.required('kind').string();
    if (id.length < 1 || id.length > 128 || result.blocks.some((b: ImageOcrBlock): boolean => b.id === id) || node.required('ordinal').integer() !== ordinal) { throw new ImageKnowledgeFailure('ImageBlockIdentityOrOrder','image-normalize'); }
    const text: string = node.required('text').string();
    if (kind === 'empty') { if (text.length !== 0) { throw new ImageKnowledgeFailure('EmptyBlockHasText','image-normalize'); } result.coverage.empty++; continue; }
    if (kind !== 'text') { result.coverage.unknown++; result.coverage.issues.push('UnsupportedControlledBlockKind'); continue; }
    if (text.trim().length === 0) { throw new ImageKnowledgeFailure('TextBlockEmpty','image-normalize'); }
    const block: ImageOcrBlock = new ImageOcrBlock(); block.id = id; block.ordinal = ordinal; block.text = text;
    block.locator.originalAssetId = original.assetId; block.locator.originalHash = original.hash; block.locator.originalVersion = original.version;
    block.locator.width = original.header.width; block.locator.height = original.header.height; block.locator.orientation = original.header.orientation;
    block.locator.blockId = id; block.locator.paragraph = ordinal+1; block.locator.end = text.length; result.blocks.push(block); result.coverage.identified++;
  }
  if (nodes.length === 0) { throw new ImageKnowledgeFailure('ExplicitEmptyEvidenceRequired','image-normalize'); }
  return result;
}
