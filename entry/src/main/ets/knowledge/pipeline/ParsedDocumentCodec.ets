import {
  PARSED_DOCUMENT_WIRE, ParsedDocument, ParsedBlock, ParsedInline, ParsedFormula, ParsedLocator, ParsedCoverage,
  ParsedCoverageSet, ParsedCoverageState, ParsedPrecision, ParsedFormat, ParsedKind, ParsedProvenance, ParsedAssetState,
  ParsedImageAsset, ParsedImageOccurrence, ParsedSnapshotManifest, ParsedPayloadPart, ParsedSnapshotBundle,
  ParsedLimits, ParsedCancellation, ParsedFailure, parsedId, parsedHash
} from '../domain/ParsedDocumentModels';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { BoundedDocumentJson, PdfJsonNode, PdfJsonField } from './BoundedDocumentJson';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';

export function parsedUtf8(text: string): Uint8Array {
  let length: number = 0;
  for (const c of text) { const n: number = c.codePointAt(0) ?? 0; length += n < 128 ? 1 : n < 2048 ? 2 : n < 65536 ? 3 : 4; }
  const bytes: Uint8Array = new Uint8Array(length); let at: number = 0;
  for (const c of text) {
    const n: number = c.codePointAt(0) ?? 0;
    if (n >= 0xd800 && n <= 0xdfff) { throw new ParsedFailure('InvalidUnicode','codec'); }
    if (n < 128) { bytes[at++] = n; }
    else if (n < 2048) { bytes[at++] = 192 | n >> 6; bytes[at++] = 128 | n & 63; }
    else if (n < 65536) { bytes[at++] = 224 | n >> 12; bytes[at++] = 128 | n >> 6 & 63; bytes[at++] = 128 | n & 63; }
    else { bytes[at++] = 240 | n >> 18; bytes[at++] = 128 | n >> 12 & 63; bytes[at++] = 128 | n >> 6 & 63; bytes[at++] = 128 | n & 63; }
  }
  return bytes;
}
export function parsedJson(bytes: Uint8Array, cancel: ParsedCancellation, maximum: number = ParsedLimits.payloadBytes): PdfJsonNode {
  cancel.check(); if (bytes.length < 1 || bytes.length > maximum) { throw new ParsedFailure('JsonBytes','codec'); }
  const token: KnowledgeCancellation = new KnowledgeCancellation(); token.deadline = cancel.deadline;
  const node: PdfJsonNode = new BoundedDocumentJson(bytes,token,ParsedLimits.payloadBytes).read(); cancel.check(); return node;
}
function ps(n: PdfJsonNode, key: string): string { return n.required(key).string(); }
function exact(n: PdfJsonNode, keys: string[]): void {
  if (n.kind !== 'object' || n.fields.length !== keys.length || n.fields.some((field: PdfJsonField): boolean => keys.indexOf(field.key) < 0)) { throw new ParsedFailure('WireFields','codec'); }
}
function pn(n: PdfJsonNode, key: string): number { return n.required(key).integer(); }
function pb(n: PdfJsonNode, key: string): boolean {
  const b: PdfJsonNode = n.required(key); if (b.kind !== 'true' && b.kind !== 'false') { throw new ParsedFailure('BooleanRequired','codec'); } return b.kind === 'true';
}
function strings(n: PdfJsonNode, key: string, maximum: number): string[] {
  const nodes: PdfJsonNode[] = n.required(key).array(); if (nodes.length > maximum) { throw new ParsedFailure('ArrayBudget','codec'); }
  return nodes.map((v: PdfJsonNode): string => v.string());
}
function kind(s: string): ParsedKind {
  const v: ParsedKind | undefined = [ParsedKind.Text,ParsedKind.Heading,ParsedKind.Image,ParsedKind.Formula,ParsedKind.Table,ParsedKind.Cell,ParsedKind.Container,ParsedKind.Unknown].find((k: ParsedKind): boolean => k === s);
  if (v === undefined) { throw new ParsedFailure('BlockKind','codec'); } return v;
}
function format(s: string): ParsedFormat {
  const v: ParsedFormat | undefined = [ParsedFormat.Text,ParsedFormat.Pdf,ParsedFormat.Image,ParsedFormat.Docx].find((k: ParsedFormat): boolean => k === s);
  if (v === undefined) { throw new ParsedFailure('Format','codec'); } return v;
}
function coverage(n: PdfJsonNode): ParsedCoverage {
  exact(n,['state','expected','recovered','reasons']);
  const c: ParsedCoverage = new ParsedCoverage(); const state: string = ps(n,'state');
  const k: ParsedCoverageState | undefined = [ParsedCoverageState.Complete,ParsedCoverageState.Partial,ParsedCoverageState.Unknown,ParsedCoverageState.Unsupported].find((v: ParsedCoverageState): boolean => v === state);
  if (k === undefined) { throw new ParsedFailure('CoverageState','codec'); }
  c.state = k; c.expected = pn(n,'expected'); c.recovered = pn(n,'recovered'); c.reasons = strings(n,'reasons',1000);
  if (!Number.isSafeInteger(c.expected) || !Number.isSafeInteger(c.recovered) || c.expected < 0 || c.recovered < 0 || c.recovered > c.expected || (k === ParsedCoverageState.Complete && c.recovered !== c.expected)) { throw new ParsedFailure('CoverageCounts','codec'); }
  return c;
}
function coverageSet(n: PdfJsonNode): ParsedCoverageSet {
  exact(n,['selectedOutput','nativeLocation','imageRecovery']);
  const c: ParsedCoverageSet = new ParsedCoverageSet(); c.selectedOutput = coverage(n.required('selectedOutput'));
  c.nativeLocation = coverage(n.required('nativeLocation')); c.imageRecovery = coverage(n.required('imageRecovery')); return c;
}
function locator(n: PdfJsonNode): ParsedLocator {
  exact(n,['precision','sourceHash','evidenceId','pageIndex0','paragraphId','cellId','limitations']);
  const l: ParsedLocator = new ParsedLocator(); const s: string = ps(n,'precision');
  const p: ParsedPrecision | undefined = [ParsedPrecision.Unknown,ParsedPrecision.File,ParsedPrecision.Block,ParsedPrecision.Page,ParsedPrecision.Paragraph,ParsedPrecision.Cell].find((v: ParsedPrecision): boolean => v === s);
  if (p === undefined) { throw new ParsedFailure('LocatorPrecision','codec'); }
  l.precision = p; l.sourceHash = ps(n,'sourceHash'); l.evidenceId = ps(n,'evidenceId'); l.pageIndex0 = pn(n,'pageIndex0');
  l.paragraphId = ps(n,'paragraphId'); l.cellId = ps(n,'cellId'); l.limitations = strings(n,'limitations',1000);
  if (l.pageIndex0 < -1 || (p === ParsedPrecision.Page && l.pageIndex0 < 0) ||
    (p === ParsedPrecision.Paragraph && l.paragraphId.length === 0) || (p === ParsedPrecision.Cell && l.cellId.length === 0) ||
    ([ParsedPrecision.Page,ParsedPrecision.Paragraph,ParsedPrecision.Cell].indexOf(p) >= 0 && (!parsedHash(l.sourceHash) || l.evidenceId.length === 0)) ||
    ([ParsedPrecision.Unknown,ParsedPrecision.File,ParsedPrecision.Block].indexOf(p) >= 0 && (l.pageIndex0 !== -1 || l.paragraphId.length > 0 || l.cellId.length > 0))) { throw new ParsedFailure('LocatorEvidence','codec'); }
  return l;
}
function formula(n: PdfJsonNode): ParsedFormula {
  exact(n,['text','latex','imageOccurrenceId','unsupportedReason']);
  const f: ParsedFormula = new ParsedFormula(); f.text = ps(n,'text'); f.latex = ps(n,'latex');
  f.imageOccurrenceId = ps(n,'imageOccurrenceId'); f.unsupportedReason = ps(n,'unsupportedReason'); return f;
}
function inline(n: PdfJsonNode): ParsedInline {
  exact(n,['id','order','kind','text','imageOccurrenceId','formula','limitation']);
  const r: ParsedInline = new ParsedInline(); r.id = ps(n,'id'); r.order = pn(n,'order'); r.kind = kind(ps(n,'kind')); r.text = ps(n,'text');
  r.imageOccurrenceId = ps(n,'imageOccurrenceId'); r.formula = formula(n.required('formula')); r.limitation = ps(n,'limitation'); return r;
}
function block(n: PdfJsonNode): ParsedBlock {
  exact(n,['id','parentId','order','kind','text','inlines','formula','imageOccurrenceId','evidenceType','locator','limitation','row','column','rowSpan','columnSpan']);
  const b: ParsedBlock = new ParsedBlock(); b.id = ps(n,'id'); b.parentId = ps(n,'parentId'); b.order = pn(n,'order'); b.kind = kind(ps(n,'kind'));
  b.text = ps(n,'text'); const rows: PdfJsonNode[] = n.required('inlines').array();
  if (rows.length > ParsedLimits.blocks) { throw new ParsedFailure('InlineBudget','codec'); } b.inlines = rows.map((v: PdfJsonNode): ParsedInline => inline(v));
  b.formula = formula(n.required('formula')); b.imageOccurrenceId = ps(n,'imageOccurrenceId'); b.evidenceType = ps(n,'evidenceType');
  b.locator = locator(n.required('locator')); b.limitation = ps(n,'limitation'); b.row = pn(n,'row'); b.column = pn(n,'column');
  b.rowSpan = pn(n,'rowSpan'); b.columnSpan = pn(n,'columnSpan'); return b;
}
export function parsedDecodeAsset(n: PdfJsonNode): ParsedImageAsset {
  exact(n,['id','owner','relativePath','payloadHash','bytes','mime','pixelWidth','pixelHeight','frames','state','legacyContainerHash','member','limitation']);
  const a: ParsedImageAsset = new ParsedImageAsset(); a.id = ps(n,'id'); a.owner = ps(n,'owner'); a.relativePath = ps(n,'relativePath');
  a.payloadHash = ps(n,'payloadHash'); a.bytes = pn(n,'bytes'); a.mime = ps(n,'mime'); a.pixelWidth = pn(n,'pixelWidth'); a.pixelHeight = pn(n,'pixelHeight'); a.frames = pn(n,'frames');
  const state: string = ps(n,'state'); const s: ParsedAssetState | undefined = [ParsedAssetState.Reserved,ParsedAssetState.Ready,ParsedAssetState.Missing,ParsedAssetState.Unsupported,ParsedAssetState.Removed].find((v: ParsedAssetState): boolean => v === state);
  if (s === undefined) { throw new ParsedFailure('AssetState','codec'); } a.state = s;
  a.legacyContainerHash = ps(n,'legacyContainerHash'); a.member = ps(n,'member'); a.limitation = ps(n,'limitation'); return a;
}
function occurrence(n: PdfJsonNode): ParsedImageOccurrence {
  exact(n,['id','documentKey','generation','blockId','inlineId','order','assetId','provenance','member','locator','ocr','ocrVersion','caption','annotationLineage','effectiveAnnotationId','limitation']);
  const o: ParsedImageOccurrence = new ParsedImageOccurrence(); o.id = ps(n,'id'); o.documentKey = ps(n,'documentKey'); o.generation = ps(n,'generation');
  o.blockId = ps(n,'blockId'); o.inlineId = ps(n,'inlineId'); o.order = pn(n,'order'); o.assetId = ps(n,'assetId');
  const raw: string = ps(n,'provenance'); const p: ParsedProvenance | undefined = [ParsedProvenance.Original,ParsedProvenance.Native,ParsedProvenance.Derived,ParsedProvenance.Unresolved].find((v: ParsedProvenance): boolean => v === raw);
  if (p === undefined) { throw new ParsedFailure('Provenance','codec'); } o.provenance = p; o.member = ps(n,'member'); o.locator = locator(n.required('locator'));
  o.ocr = ps(n,'ocr'); o.ocrVersion = ps(n,'ocrVersion'); o.caption = ps(n,'caption'); o.annotationLineage = ps(n,'annotationLineage');
  o.effectiveAnnotationId = ps(n,'effectiveAnnotationId'); o.limitation = ps(n,'limitation'); return o;
}
export function parsedValidate(document: ParsedDocument): void {
  format(document.format);
  if (document.wire !== PARSED_DOCUMENT_WIRE || !parsedId(document.documentKey) || !parsedId(document.generation) || document.generation.length > 100 ||
    !parsedHash(document.source_hash) || !Number.isSafeInteger(document.sourceVersion) || document.sourceVersion < 1 ||
    document.parser_signature.trim().length === 0 || document.engine.trim().length === 0 || document.title.length > 256) { throw new ParsedFailure('DocumentIdentity','codec'); }
  const blocks: ParsedBlock[] = document.blocks ?? []; const ids: Set<string> = new Set<string>(); const objects: Set<string> = new Set<string>();
  if (blocks.length > ParsedLimits.blocks || document.occurrences.length > ParsedLimits.occurrences || document.images.length > ParsedLimits.occurrences) { throw new ParsedFailure('DocumentBudget','codec'); }
  let last: number = -1; let cells: number = 0;
  for (const b of blocks) {
    if (!parsedId(b.id) || ids.has(b.id) || !Number.isSafeInteger(b.order) || b.order <= last || (b.parentId.length > 0 && !ids.has(b.parentId))) { throw new ParsedFailure('BlockOrderOrParent','codec'); }
    ids.add(b.id); last = b.order; if (b.kind === ParsedKind.Cell) { cells++; if (b.row < 0 || b.column < 0 || b.rowSpan < 1 || b.columnSpan < 1) { throw new ParsedFailure('CellRange','codec'); } }
    if (b.locator.sourceHash.length > 0 && b.locator.sourceHash !== document.source_hash) { throw new ParsedFailure('LocatorSourceBinding','codec'); }
    if (b.kind === ParsedKind.Image && b.imageOccurrenceId.length === 0 && b.limitation.length === 0) { throw new ParsedFailure('ImagePlaceholder','codec'); }
    if (b.kind === ParsedKind.Formula && b.formula.text.length+b.formula.latex.length+b.formula.imageOccurrenceId.length+b.formula.unsupportedReason.length === 0) { throw new ParsedFailure('FormulaPlaceholder','codec'); }
    if (b.kind === ParsedKind.Unknown && b.limitation.length === 0) { throw new ParsedFailure('UnknownPlaceholder','codec'); }
    let inlineOrder: number = -1;
    for (const r of b.inlines) {
      if (!parsedId(r.id) || objects.has(r.id) || !Number.isSafeInteger(r.order) || r.order <= inlineOrder) { throw new ParsedFailure('InlineOrder','codec'); }
      objects.add(r.id); inlineOrder = r.order;
      if (r.kind === ParsedKind.Image && r.imageOccurrenceId.length+r.limitation.length === 0) { throw new ParsedFailure('InlinePlaceholder','codec'); }
      if (r.kind === ParsedKind.Formula && r.formula.text.length+r.formula.latex.length+r.formula.imageOccurrenceId.length+r.formula.unsupportedReason.length === 0) { throw new ParsedFailure('InlineFormula','codec'); }
      if (r.kind === ParsedKind.Unknown && r.limitation.length === 0) { throw new ParsedFailure('InlineUnknown','codec'); }
    }
    // Typed roundtrip also validates enum and evidence-bearing locator fields.
    block(parsedJson(parsedUtf8(JSON.stringify(b)),new ParsedCancellation()));
  }
  if (cells > ParsedLimits.cells) { throw new ParsedFailure('CellBudget','codec'); }
  const assets: Set<string> = new Set<string>(); const occurrences: Set<string> = new Set<string>();
  for (const a of document.images) {
    parsedDecodeAsset(parsedJson(parsedUtf8(JSON.stringify(a)),new ParsedCancellation()));
    if (!parsedId(a.id) || assets.has(a.id) || a.bytes < 0 || !Number.isSafeInteger(a.bytes) || (a.payloadHash.length > 0 && !parsedHash(a.payloadHash)) ||
      (a.legacyContainerHash.length > 0 && !parsedHash(a.legacyContainerHash))) { throw new ParsedFailure('AssetIdentity','codec'); }
    if (a.state === ParsedAssetState.Ready && (a.owner !== 'ParsedDocumentAssets' || !parsedHash(a.payloadHash) || a.bytes < 1 || a.relativePath !== `images/${a.id}`)) { throw new ParsedFailure('ReadyAssetIdentity','codec'); }
    assets.add(a.id);
  }
  let occurrenceOrder: number = -1;
  for (const o of document.occurrences) {
    if (!parsedId(o.id) || occurrences.has(o.id) || o.documentKey !== document.documentKey || o.generation !== document.generation || !Number.isSafeInteger(o.order) || o.order <= occurrenceOrder ||
      (o.blockId.length > 0 && !ids.has(o.blockId)) || (o.inlineId.length > 0 && !objects.has(o.inlineId)) ||
      (o.assetId.length > 0 && !assets.has(o.assetId)) || (o.assetId.length === 0 && o.limitation.length === 0)) { throw new ParsedFailure('OccurrenceBinding','codec'); }
    if (o.locator.sourceHash.length > 0 && o.locator.sourceHash !== document.source_hash) { throw new ParsedFailure('OccurrenceSourceBinding','codec'); }
    if (o.inlineId.length > 0 && !blocks.some((b: ParsedBlock): boolean => b.id === o.blockId && b.inlines.some((r: ParsedInline): boolean => r.id === o.inlineId))) { throw new ParsedFailure('OccurrenceInlineParent','codec'); }
    occurrenceOrder = o.order; occurrences.add(o.id); occurrence(parsedJson(parsedUtf8(JSON.stringify(o)),new ParsedCancellation()));
  }
  for (const b of blocks) {
    const refs: string[] = [b.imageOccurrenceId,b.formula.imageOccurrenceId];
    for (const r of b.inlines) { refs.push(r.imageOccurrenceId,r.formula.imageOccurrenceId); }
    for (const ref of refs) { if (ref.length > 0 && !occurrences.has(ref)) { throw new ParsedFailure('OccurrenceMissing','codec'); } }
  }
  coverageSet(parsedJson(parsedUtf8(JSON.stringify(document.coverage)),new ParsedCancellation()));
  if (document.markdown.trim().length === 0 && blocks.length === 0 && document.occurrences.length === 0) { throw new ParsedFailure('EmptyProduct','codec'); }
}
class ParsedPayloadEnvelope {
  role: string = ''; markdown: string = ''; blocks: ParsedBlock[] = []; images: ParsedImageAsset[] = []; occurrences: ParsedImageOccurrence[] = [];
}
async function pushPayload(bundle: ParsedSnapshotBundle, payload: ParsedPayloadEnvelope, identity: ParsedIdentityPort, sink?: (part: ParsedPayloadPart, bytes: Uint8Array) => Promise<void>): Promise<void> {
  const bytes: Uint8Array = parsedUtf8(JSON.stringify(payload));
  if (bytes.length > ParsedLimits.payloadBytes) { throw new ParsedFailure('PayloadBudget','codec'); }
  const part: ParsedPayloadPart = new ParsedPayloadPart(); part.ordinal = bundle.manifest.parts.length; part.id = `${bundle.manifest.generation}-p${part.ordinal}`;
  part.hash = await identity.hash(bytes); part.bytes = bytes.length; part.role = payload.role;
  const total: number = bundle.manifest.parts.reduce((sum: number, p: ParsedPayloadPart): number => sum+p.bytes,bytes.length);
  if (total > ParsedLimits.generationBytes-ParsedLimits.manifestBytes) { throw new ParsedFailure('SnapshotPayloadBudget','codec'); }
  bundle.manifest.parts.push(part); if (sink !== undefined) { await sink(part,bytes); } else { bundle.payloads.push(bytes); }
}
export async function parsedEncodeSnapshot(document: ParsedDocument, identity: ParsedIdentityPort, cancel: ParsedCancellation, sink?: (part: ParsedPayloadPart, bytes: Uint8Array) => Promise<void>): Promise<ParsedSnapshotBundle> {
  cancel.check(); parsedValidate(document); const bundle: ParsedSnapshotBundle = new ParsedSnapshotBundle(); const m: ParsedSnapshotManifest = bundle.manifest;
  m.documentKey = document.documentKey; m.generation = document.generation; m.sourceVersion = document.sourceVersion;
  m.source_hash = document.source_hash; m.parser_signature = document.parser_signature; m.engine = document.engine;
  m.title = document.title; m.format = document.format; m.hasBlocks = document.blocks !== undefined; m.coverage = document.coverage; m.warnings = document.warnings.slice();
  let text: string = ''; let count: number = 0;
  for (const c of document.markdown) {
    text += c; if (++count >= 262144) { const p: ParsedPayloadEnvelope = new ParsedPayloadEnvelope(); p.role = 'markdown'; p.markdown = text; await pushPayload(bundle,p,identity,sink); text = ''; count = 0; cancel.check(); }
  }
  if (text.length > 0) { const p: ParsedPayloadEnvelope = new ParsedPayloadEnvelope(); p.role = 'markdown'; p.markdown = text; await pushPayload(bundle,p,identity,sink); }
  // Small bounded groups avoid a giant serialized copy of the whole document.
  let group: ParsedPayloadEnvelope = new ParsedPayloadEnvelope(); group.role = 'blocks'; let groupBytes: number = 256;
  for (const b of document.blocks ?? []) {
    cancel.check(); const size: number = parsedUtf8(JSON.stringify(b)).length+1;
    if (groupBytes+size > ParsedLimits.payloadBytes-1024) { if (group.blocks.length === 0) { throw new ParsedFailure('BlockPayloadBudget','codec'); } await pushPayload(bundle,group,identity,sink); group = new ParsedPayloadEnvelope(); group.role = 'blocks'; groupBytes = 256; }
    group.blocks.push(b); groupBytes += size;
  }
  if (group.blocks.length > 0) { await pushPayload(bundle,group,identity,sink); }
  for (const a of document.images) { const p: ParsedPayloadEnvelope = new ParsedPayloadEnvelope(); p.role = 'image'; p.images.push(a); await pushPayload(bundle,p,identity,sink); }
  for (const o of document.occurrences) { const p: ParsedPayloadEnvelope = new ParsedPayloadEnvelope(); p.role = 'occurrence'; p.occurrences.push(o); await pushPayload(bundle,p,identity,sink); }
  m.contentHash = await identity.hash(parsedUtf8(JSON.stringify(m))); bundle.manifestBytes = parsedUtf8(JSON.stringify(m));
  const total: number = m.parts.reduce((sum: number, p: ParsedPayloadPart): number => sum+p.bytes,bundle.manifestBytes.length);
  if (bundle.manifestBytes.length > ParsedLimits.manifestBytes || total > ParsedLimits.generationBytes) { throw new ParsedFailure('SnapshotBudget','codec'); }
  return bundle;
}
export async function parsedDecodeManifest(bytes: Uint8Array, identity: ParsedIdentityPort, cancel: ParsedCancellation): Promise<ParsedSnapshotManifest> {
  const n: PdfJsonNode = parsedJson(bytes,cancel,ParsedLimits.manifestBytes); const m: ParsedSnapshotManifest = new ParsedSnapshotManifest();
  exact(n,['wire','documentKey','generation','sourceVersion','source_hash','parser_signature','engine','title','format','hasBlocks','coverage','warnings','parts','contentHash']);
  m.wire = ps(n,'wire'); m.documentKey = ps(n,'documentKey'); m.generation = ps(n,'generation'); m.sourceVersion = pn(n,'sourceVersion');
  m.source_hash = ps(n,'source_hash'); m.parser_signature = ps(n,'parser_signature'); m.engine = ps(n,'engine'); m.title = ps(n,'title'); m.format = format(ps(n,'format'));
  m.hasBlocks = pb(n,'hasBlocks'); m.coverage = coverageSet(n.required('coverage')); m.warnings = strings(n,'warnings',1000);
  const rows: PdfJsonNode[] = n.required('parts').array(); if (rows.length > 22000) { throw new ParsedFailure('PartBudget','codec'); }
  let total: number = bytes.length; let roleOrder: number = -1;
  for (const r of rows) {
    exact(r,['id','hash','bytes','ordinal','role']);
    const p: ParsedPayloadPart = new ParsedPayloadPart(); p.id = ps(r,'id'); p.hash = ps(r,'hash'); p.bytes = pn(r,'bytes'); p.ordinal = pn(r,'ordinal'); p.role = ps(r,'role');
    if (p.id !== `${m.generation}-p${m.parts.length}` || p.ordinal !== m.parts.length || !parsedHash(p.hash) || p.bytes < 1 || p.bytes > ParsedLimits.payloadBytes || ['markdown','blocks','image','occurrence'].indexOf(p.role) < 0) { throw new ParsedFailure('PartIdentity','codec'); }
    const order: number = ['markdown','blocks','image','occurrence'].indexOf(p.role);
    if (order < roleOrder || (!m.hasBlocks && p.role === 'blocks')) { throw new ParsedFailure('PartRoleOrder','codec'); } roleOrder = order;
    total += p.bytes; m.parts.push(p);
  }
  const expected: string = ps(n,'contentHash'); m.contentHash = '';
  if (m.wire !== PARSED_DOCUMENT_WIRE || !parsedId(m.documentKey) || !parsedId(m.generation) || m.generation.length > 100 || m.sourceVersion < 1 || !parsedHash(m.source_hash) || m.parser_signature.trim().length === 0 || m.engine.trim().length === 0 || total > ParsedLimits.generationBytes || await identity.hash(parsedUtf8(JSON.stringify(m))) !== expected) { throw new ParsedFailure('ManifestHashOrIdentity','codec'); }
  m.contentHash = expected; return m;
}
export function parsedDocumentFromManifest(m: ParsedSnapshotManifest): ParsedDocument {
  const d: ParsedDocument = new ParsedDocument(); d.documentKey = m.documentKey; d.generation = m.generation; d.sourceVersion = m.sourceVersion;
  d.source_hash = m.source_hash; d.parser_signature = m.parser_signature; d.engine = m.engine; d.title = m.title; d.format = m.format;
  if (m.hasBlocks) { d.blocks = []; } d.coverage = m.coverage; d.warnings = m.warnings.slice(); return d;
}
export async function parsedApplyPayload(d: ParsedDocument, p: ParsedPayloadPart, bytes: Uint8Array, identity: ParsedIdentityPort, cancel: ParsedCancellation): Promise<void> {
  if (bytes.length !== p.bytes || await identity.hash(bytes) !== p.hash) { throw new ParsedFailure('PayloadHash','codec'); }
  const n: PdfJsonNode = parsedJson(bytes,cancel); if (ps(n,'role') !== p.role) { throw new ParsedFailure('PayloadRole','codec'); }
  exact(n,['role','markdown','blocks','images','occurrences']);
  if ((p.role !== 'markdown' && ps(n,'markdown').length > 0) || (p.role !== 'blocks' && n.required('blocks').array().length > 0) ||
    (p.role !== 'image' && n.required('images').array().length > 0) || (p.role !== 'occurrence' && n.required('occurrences').array().length > 0)) { throw new ParsedFailure('PayloadMixedRoles','codec'); }
  if (p.role === 'markdown') { d.markdown += ps(n,'markdown'); }
  else if (p.role === 'blocks') {
    if (d.blocks === undefined) { throw new ParsedFailure('UnexpectedBlocks','codec'); }
    for (const r of n.required('blocks').array()) { if (d.blocks.length >= ParsedLimits.blocks) { throw new ParsedFailure('BlocksBudget','codec'); } d.blocks.push(block(r)); }
  } else if (p.role === 'image') {
    const rows: PdfJsonNode[] = n.required('images').array(); if (rows.length !== 1 || d.images.length >= ParsedLimits.occurrences) { throw new ParsedFailure('ImagePayloadCount','codec'); } d.images.push(parsedDecodeAsset(rows[0]));
  } else {
    const rows: PdfJsonNode[] = n.required('occurrences').array(); if (rows.length !== 1 || d.occurrences.length >= ParsedLimits.occurrences) { throw new ParsedFailure('OccurrencePayloadCount','codec'); } d.occurrences.push(occurrence(rows[0]));
  }
}
