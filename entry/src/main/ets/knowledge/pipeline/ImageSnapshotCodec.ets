import { ImageSnapshot, ImageOriginal, ImageOcrBlock, ImageLocator, ImageChunk, ImageCoverage, ImageLimits, ImageKnowledgeFailure, ImagePreviewState, imageEncoding, imageHash, imageIdentity } from '../domain/ImageKnowledgeModels';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { documentUtf8Bytes } from '../domain/DocumentParseModels';
import { BoundedDocumentJson, PdfJsonNode, PdfJsonField } from './BoundedDocumentJson';
import { pdfCodecUtf8 } from './PdfSnapshotCodec';
import { IMAGE_CONTROLLED_PROFILE, IMAGE_TEXT_PROFILE } from './ImageContentNormalizer';

export function imageExactFields(node: PdfJsonNode, keys: string[]): void {
  if (node.kind !== 'object' || node.fields.length !== keys.length || node.fields.some((f: PdfJsonField): boolean => keys.indexOf(f.key) < 0)) { throw new ImageKnowledgeFailure('ImageWireFields','image-codec'); }
}
function imageCodecBoolean(node: PdfJsonNode): boolean { if (node.kind !== 'true' && node.kind !== 'false') { throw new ImageKnowledgeFailure('ImageWireBoolean','image-codec'); } return node.kind === 'true'; }
function imageCodecNumber(node: PdfJsonNode): number { const n: number = node.integer(); if (n < 0) { throw new ImageKnowledgeFailure('ImageWireNegative','image-codec'); } return n; }
export function imageReadOriginal(node: PdfJsonNode): ImageOriginal {
  const modern: boolean = node.optional('basicQualified') !== undefined;
  imageExactFields(node,modern ? ['documentId','assetId','sourceId','version','title','suffix','hash','bytes','header','sdkVerified','frames','savedAt','basicQualified','preview','previewReason'] : ['documentId','assetId','sourceId','version','title','suffix','hash','bytes','header','sdkVerified','frames','savedAt']);
  const o: ImageOriginal = new ImageOriginal(); o.documentId = node.required('documentId').string(); o.assetId = node.required('assetId').string(); o.sourceId = node.required('sourceId').string(); o.version = imageCodecNumber(node.required('version'));
  o.title = node.required('title').string(); o.suffix = node.required('suffix').string(); o.hash = node.required('hash').string(); o.bytes = imageCodecNumber(node.required('bytes'));
  o.sdkVerified = imageCodecBoolean(node.required('sdkVerified')); o.frames = imageCodecNumber(node.required('frames')); o.savedAt = imageCodecNumber(node.required('savedAt'));
  if (modern) {
    o.basicQualified = imageCodecBoolean(node.required('basicQualified')); const preview: string = node.required('preview').string();
    const state = [ImagePreviewState.NotRequested,ImagePreviewState.Ready,ImagePreviewState.Failed,ImagePreviewState.Unavailable].find((s: ImagePreviewState): boolean => s === preview);
    if (state === undefined) { throw new ImageKnowledgeFailure('ImagePreviewWire','image-codec'); } o.preview = state; o.previewReason = node.required('previewReason').string();
  }
  const h: PdfJsonNode = node.required('header'); imageExactFields(h,modern ? ['encoding','mime','width','height','staticContainer','alpha','variant','orientation','orientationEvidence','warnings'] : ['encoding','mime','width','height','staticContainer','alpha','variant','orientation','orientationEvidence']);
  if (modern) { for (const warning of h.required('warnings').array()) { o.header.warnings.push(warning.string()); } }
  o.header.encoding = imageEncoding(h.required('encoding').string()); o.header.mime = h.required('mime').string(); o.header.width = imageCodecNumber(h.required('width')); o.header.height = imageCodecNumber(h.required('height'));
  o.header.staticContainer = imageCodecBoolean(h.required('staticContainer')); o.header.alpha = imageCodecBoolean(h.required('alpha')); o.header.variant = h.required('variant').string(); o.header.orientation = imageCodecNumber(h.required('orientation')); o.header.orientationEvidence = h.required('orientationEvidence').string();
  const expectedMime: string = o.header.encoding === 'JPEG' ? 'image/jpeg' : o.header.encoding === 'PNG' ? 'image/png' : 'image/webp';
  if (!imageIdentity(o.documentId) || !imageIdentity(o.assetId) || !imageIdentity(o.sourceId) || !imageHash(o.hash) || o.version < 1 || o.bytes < 1 || o.bytes > ImageLimits.bytes || o.frames > 1 || !o.header.staticContainer || o.header.width < 1 || o.header.height < 1 || o.header.width*o.header.height > ImageLimits.pixels || o.header.orientation > 8 || o.header.mime !== expectedMime || !modern && (!o.sdkVerified || o.frames !== 1 || o.header.orientation < 1)) { throw new ImageKnowledgeFailure('ImageOriginalWireIdentity','image-codec'); } return o;
}
export function imageReadLocator(node: PdfJsonNode): ImageLocator {
  imageExactFields(node,['originalAssetId','originalHash','originalVersion','width','height','orientation','blockId','paragraph','start','end']);
  const l: ImageLocator = new ImageLocator(); l.originalAssetId = node.required('originalAssetId').string(); l.originalHash = node.required('originalHash').string(); l.originalVersion = imageCodecNumber(node.required('originalVersion'));
  l.width = imageCodecNumber(node.required('width')); l.height = imageCodecNumber(node.required('height')); l.orientation = imageCodecNumber(node.required('orientation')); l.blockId = node.required('blockId').string(); l.paragraph = imageCodecNumber(node.required('paragraph')); l.start = imageCodecNumber(node.required('start')); l.end = imageCodecNumber(node.required('end'));
  if (!imageIdentity(l.originalAssetId) || !imageHash(l.originalHash) || l.originalVersion < 1 || l.width < 1 || l.height < 1 || l.width*l.height > ImageLimits.pixels || l.orientation > 8 || l.paragraph < 1 || l.end <= l.start || l.blockId.length === 0 || l.blockId.length > 128) { throw new ImageKnowledgeFailure('ImageLocatorRange','image-codec'); } return l;
}
export function imageDecodeSnapshot(bytes: Uint8Array, cancel: KnowledgeCancellation): ImageSnapshot {
   const node: PdfJsonNode = new BoundedDocumentJson(bytes,cancel,2097152).read(); const modern: boolean = node.required('wire').string() === 'IMAGE-NORMALIZED-2';
  imageExactFields(node,modern ? ['wire','profile','producer','documentId','generation','original','resultHash','contentHash','coverage','blocks','projection'] : ['wire','profile','producer','documentId','generation','original','resultHash','contentHash','coverage','blocks']);
  const s: ImageSnapshot = new ImageSnapshot();
  s.wire = node.required('wire').string(); if (s.wire !== 'IMAGE-NORMALIZED-1' && !modern) { throw new ImageKnowledgeFailure('UnknownImageSnapshotWire','image-codec'); }
  s.profile = node.required('profile').string(); s.producer = node.required('producer').string(); s.documentId = node.required('documentId').string(); s.generation = node.required('generation').string(); s.original = imageReadOriginal(node.required('original')); s.resultHash = node.required('resultHash').string(); s.contentHash = node.required('contentHash').string();
  if (!(s.profile === IMAGE_CONTROLLED_PROFILE && s.producer === 'ShuviControlledFixture-1' || modern && s.profile === IMAGE_TEXT_PROFILE && s.producer === 'MinerU-reported-unversioned') || s.documentId !== s.original.documentId || !imageIdentity(s.generation) || !imageHash(s.resultHash) || s.contentHash.length > 0 && !imageHash(s.contentHash)) { throw new ImageKnowledgeFailure('ImageSnapshotBinding','image-codec'); }
  if (modern) {
    const p = node.required('projection'); imageExactFields(p,['kind','member','memberHash','zipHash','taskId','dataId','text']);
    s.projection.kind = p.required('kind').string(); s.projection.member = p.required('member').string(); s.projection.memberHash = p.required('memberHash').string(); s.projection.zipHash = p.required('zipHash').string(); s.projection.taskId = p.required('taskId').string(); s.projection.dataId = p.required('dataId').string(); s.projection.text = p.required('text').string();
    if (s.profile === IMAGE_TEXT_PROFILE && (s.projection.kind !== IMAGE_TEXT_PROFILE || s.projection.zipHash !== s.resultHash || !imageHash(s.projection.memberHash) || s.projection.member.length < 1 || !imageIdentity(s.projection.taskId) || !imageIdentity(s.projection.dataId))) { throw new ImageKnowledgeFailure('ImageProjectionWireBinding','image-codec'); }
  }
  const coverage: PdfJsonNode = node.required('coverage'); imageExactFields(coverage,['identified','excluded','unknown','empty','fullDocument','hash','issues']);
  s.coverage.identified = imageCodecNumber(coverage.required('identified')); s.coverage.excluded = imageCodecNumber(coverage.required('excluded')); s.coverage.unknown = imageCodecNumber(coverage.required('unknown')); s.coverage.empty = imageCodecNumber(coverage.required('empty')); s.coverage.fullDocument = imageCodecBoolean(coverage.required('fullDocument')); s.coverage.hash = coverage.required('hash').string();
  for (const issue of coverage.required('issues').array()) { s.coverage.issues.push(issue.string()); }
  const blocks: PdfJsonNode[] = node.required('blocks').array(); if (blocks.length > ImageLimits.nodes) { throw new ImageKnowledgeFailure('ImageSnapshotNodeBudget','image-codec'); }
  for (const raw of blocks) {
    cancel.check(); imageExactFields(raw,modern ? ['id','ordinal','text','locator','sourceStart','sourceEnd'] : ['id','ordinal','text','locator']); const b: ImageOcrBlock = new ImageOcrBlock(); b.id = raw.required('id').string(); b.ordinal = imageCodecNumber(raw.required('ordinal')); b.text = raw.required('text').string(); b.locator = imageReadLocator(raw.required('locator'));
    if (modern) { b.sourceStart = imageCodecNumber(raw.required('sourceStart')); b.sourceEnd = imageCodecNumber(raw.required('sourceEnd')); }
    if (s.profile === IMAGE_TEXT_PROFILE && (b.sourceEnd-b.sourceStart !== b.text.length || s.projection.text.slice(b.sourceStart,b.sourceEnd) !== b.text)) { throw new ImageKnowledgeFailure('ImageProjectionTextRange','image-codec'); }
    if (s.blocks.some((prior: ImageOcrBlock): boolean => prior.id === b.id || prior.ordinal >= b.ordinal) || b.text.trim().length === 0 || b.locator.blockId !== b.id || b.locator.paragraph !== b.ordinal+1 || b.locator.start !== 0 || b.locator.end !== b.text.length || b.locator.originalAssetId !== s.original.assetId || b.locator.originalHash !== s.original.hash || b.locator.originalVersion !== s.original.version || b.locator.width !== s.original.header.width || b.locator.height !== s.original.header.height || b.locator.orientation !== s.original.header.orientation) { throw new ImageKnowledgeFailure('ImageBlockSourceOrOrder','image-codec'); } s.blocks.push(b);
  }
  if (!s.coverage.fullDocument || s.coverage.identified !== s.blocks.length || s.coverage.identified+s.coverage.empty+s.coverage.excluded+s.coverage.unknown > ImageLimits.nodes || s.coverage.identified+s.coverage.empty+s.coverage.excluded+s.coverage.unknown < 1) { throw new ImageKnowledgeFailure('ImageCoverageCounts','image-codec'); } return s;
}
// Ordered v1 serialization excludes every additive v2 field; historical digests remain byte-identical.
class ImageLegacyHeaderWire {
  encoding: string = ''; mime: string = ''; width: number = 0; height: number = 0; staticContainer: boolean = false;
  alpha: boolean = false; variant: string = ''; orientation: number = 0; orientationEvidence: string = '';
}
class ImageLegacyOriginalWire {
  documentId: string = ''; assetId: string = ''; sourceId: string = ''; version: number = 0; title: string = ''; suffix: string = ''; hash: string = ''; bytes: number = 0;
  header: ImageLegacyHeaderWire = new ImageLegacyHeaderWire(); sdkVerified: boolean = false; frames: number = 0; savedAt: number = 0;
}
class ImageLegacyBlockWire { id: string = ''; ordinal: number = 0; text: string = ''; locator: ImageLocator = new ImageLocator(); }
class ImageLegacySnapshotWire {
  wire: string = 'IMAGE-NORMALIZED-1'; profile: string = ''; producer: string = ''; documentId: string = ''; generation: string = '';
  original: ImageLegacyOriginalWire = new ImageLegacyOriginalWire(); resultHash: string = ''; contentHash: string = ''; coverage: ImageCoverage = new ImageCoverage(); blocks: ImageLegacyBlockWire[] = [];
  constructor(snapshot: ImageSnapshot) { this.coverage = snapshot.coverage; }
}
export function imageSnapshotWire(snapshot: ImageSnapshot): string {
  if (snapshot.wire !== 'IMAGE-NORMALIZED-1') { return JSON.stringify(snapshot); }
  const s: ImageLegacySnapshotWire = new ImageLegacySnapshotWire(snapshot); const o = snapshot.original; const h = o.header;
  s.profile = snapshot.profile; s.producer = snapshot.producer; s.documentId = snapshot.documentId; s.generation = snapshot.generation; s.resultHash = snapshot.resultHash; s.contentHash = snapshot.contentHash;
  s.original.documentId = o.documentId; s.original.assetId = o.assetId; s.original.sourceId = o.sourceId; s.original.version = o.version; s.original.title = o.title; s.original.suffix = o.suffix; s.original.hash = o.hash; s.original.bytes = o.bytes;
  s.original.sdkVerified = o.sdkVerified; s.original.frames = o.frames; s.original.savedAt = o.savedAt;
  s.original.header.encoding = h.encoding; s.original.header.mime = h.mime; s.original.header.width = h.width; s.original.header.height = h.height; s.original.header.staticContainer = h.staticContainer; s.original.header.alpha = h.alpha; s.original.header.variant = h.variant; s.original.header.orientation = h.orientation; s.original.header.orientationEvidence = h.orientationEvidence;
  for (const block of snapshot.blocks) { const b: ImageLegacyBlockWire = new ImageLegacyBlockWire(); b.id = block.id; b.ordinal = block.ordinal; b.text = block.text; b.locator = block.locator; s.blocks.push(b); }
  return JSON.stringify(s);
}
export async function imageSealSnapshot(snapshot: ImageSnapshot, identity: KnowledgeIdentityPort, cancel: KnowledgeCancellation): Promise<void> {
  snapshot.coverage.hash = ''; snapshot.contentHash = '';
  snapshot.coverage.hash = await identity.hash(pdfCodecUtf8(JSON.stringify(snapshot.coverage)));
  snapshot.contentHash = await identity.hash(pdfCodecUtf8(imageSnapshotWire(snapshot))); cancel.check();
}
export async function imageVerifySnapshot(snapshot: ImageSnapshot, identity: KnowledgeIdentityPort, cancel: KnowledgeCancellation): Promise<void> {
  const copy: ImageSnapshot = imageDecodeSnapshot(pdfCodecUtf8(imageSnapshotWire(snapshot)),cancel); const expectedContent: string = copy.contentHash; const expectedCoverage: string = copy.coverage.hash;
  await imageSealSnapshot(copy,identity,cancel);
  if (!imageHash(expectedContent) || copy.contentHash !== expectedContent || copy.coverage.hash !== expectedCoverage) { throw new ImageKnowledgeFailure('ImageSnapshotDigestMismatch','image-codec'); }
}
export async function imageSnapshotChunks(snapshot: ImageSnapshot, identity: KnowledgeIdentityPort, cancel: KnowledgeCancellation): Promise<ImageChunk[]> {
  const chunks: ImageChunk[] = [];
  for (const block of snapshot.blocks) {
    for (let start: number = 0; start < block.text.length;) {
      cancel.check(); let end: number = start; let scalars: number = 0; let bytes: number = 0;
      while (end < block.text.length && scalars < 512) {
        const code: number = block.text.charCodeAt(end); const units: number = code >= 0xd800 && code <= 0xdbff ? 2 : 1;
        const part: string = block.text.slice(end,end+units); const n: number = documentUtf8Bytes(part); if (bytes+n > 2048) { break; } bytes += n; end += units; scalars++;
      }
      if (end <= start || chunks.length >= ImageLimits.chunks) { throw new ImageKnowledgeFailure('ImageChunkBudget','image-chunk'); }
      const chunk: ImageChunk = new ImageChunk(); chunk.id = `${snapshot.generation}-c${chunks.length}`; chunk.documentId = snapshot.documentId; chunk.generation = snapshot.generation; chunk.ordinal = chunks.length; chunk.text = block.text.slice(start,end);
      chunk.locator = imageReadLocator(new BoundedDocumentJson(pdfCodecUtf8(JSON.stringify(block.locator)),cancel).read()); chunk.locator.start = start; chunk.locator.end = end;
      chunk.inputHash = await identity.hash(pdfCodecUtf8(chunk.text)); chunks.push(chunk); start = end;
    }
  } return chunks;
}
