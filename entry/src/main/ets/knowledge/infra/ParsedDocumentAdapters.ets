import {
  ParsedDocument, ParsedImageAsset, ParsedImageOccurrence, ParsedAssetWrite, ParsedAssetState, ParsedProvenance,
  ParsedCoverageState, ParsedCancellation, ParsedFailure, ParsedLimits, ParsedBlock, ParsedInline, ParsedPrecision
} from '../domain/ParsedDocumentModels';
import { ParsedProducerPort, ParsedIdentityPort, ParsedAssetPort, ParsedImportRequest, ParsedImageBytesPort } from '../domain/ParsedDocumentPorts';
import { parsedUtf8 } from '../pipeline/ParsedDocumentCodec';
import { parsedMarkdownProjection, parsedContentProjection, ParsedOutputProjection, ParsedOutputImageLink } from '../pipeline/ParsedOutputDecoder';
import { imageInspectHeader } from '../pipeline/ImageHeaderPolicy';
import { ImageHeaderReader } from '../domain/ImageKnowledgePorts';
import { ImageHeaderEvidence } from '../domain/ImageKnowledgeModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { parsedBlockText } from '../pipeline/ParsedDocumentChunker';

class ParsedBufferedImage implements ParsedImageBytesPort, ImageHeaderReader {
  length: number; private bytes: Uint8Array;
  constructor(bytes: Uint8Array) { this.bytes = bytes; this.length = bytes.length; }
  async read(at: number | ParsedCancellation, length?: number): Promise<Uint8Array> {
    if (typeof at === 'number') { return this.bytes.slice(at,at+(length ?? 0)); }
    at.check(); return this.bytes;
  }
}
export class ParsedImageProduction {
  member: string = ''; reader: ParsedImageBytesPort; provenance: ParsedProvenance = ParsedProvenance.Derived;
  legacyContainerHash: string = ''; ocr: string = ''; caption: string = ''; nativeBlockId: string = ''; limitation: string = '';
  constructor(reader: ParsedImageBytesPort) { this.reader = reader; }
}
export class ParsedDocumentAdapters implements ParsedProducerPort {
  private identity: ParsedIdentityPort; private markdown: string = ''; private content: Uint8Array | undefined;
  private outputId: string = ''; private images: ParsedImageProduction[] = []; private native: ParsedOutputProjection | undefined;
  private ocrBody: boolean = false;
  private outputBase: string = '';
  private warnings: string[] = [];
  private projected: ParsedOutputProjection | undefined;
  setProjectedBlocks(blocks: ParsedBlock[], markdown: string, outputId: string): void { this.projected=new ParsedOutputProjection(); this.projected.blocks=blocks; this.markdown=markdown; this.outputId=outputId; }
  absorb(other: ParsedDocumentAdapters): void { this.images.push(...other.images.filter((image: ParsedImageProduction): boolean=>!this.images.some((row: ParsedImageProduction): boolean=>row.member===image.member && row.provenance===image.provenance))); this.warnings.push(...other.warnings); if (this.native===undefined) { this.native=other.native; } }
  addWarning(warning: string): void { this.warnings.push(warning); }
  setOutputBase(member: string): void { this.outputBase = member.slice(0,member.lastIndexOf('/')+1); }
  markBodyAsOcr(): void { this.ocrBody = true; }
  constructor(identity: ParsedIdentityPort) { this.identity = identity; }
  setOutput(markdown: string, content: Uint8Array | undefined, outputId: string): void { this.markdown = markdown; this.content = content; this.outputId = outputId; }
  setNative(projection: ParsedOutputProjection): void { this.native = projection; }
  addProduction(image: ParsedImageProduction): void {
    if (this.images.length >= ParsedLimits.occurrences) { throw new ParsedFailure('ImageProductionBudget','producer'); } this.images.push(image);
  }
  addImage(member: string, bytes: Uint8Array, provenance: ParsedProvenance): void {
    const image: ParsedImageProduction = new ParsedImageProduction(new ParsedBufferedImage(bytes)); image.member = member; image.provenance = provenance; this.addProduction(image);
  }
  async produce(request: ParsedImportRequest, documentKey: string, generation: string, assets: ParsedAssetPort, cancel: ParsedCancellation): Promise<ParsedDocument> {
    cancel.check(); const d: ParsedDocument = new ParsedDocument(); d.documentKey = documentKey; d.generation = generation;
    d.source_hash = request.sourceHash; d.sourceVersion = request.sourceVersion; d.title = request.title; d.format = request.format;
    d.parser_signature = request.parserSignature; d.engine = request.engine; d.markdown = this.markdown;
    let projection: ParsedOutputProjection;
    if (this.projected!==undefined) { projection=this.projected; }
    else if (this.content !== undefined) {
      try { projection = parsedContentProjection(this.content,cancel); }
      catch (error) { cancel.check(); if (this.markdown.trim().length === 0) { throw error; } projection = parsedMarkdownProjection(this.markdown,cancel); projection.warnings.push('StructuredOutputUnusableMarkdownPreserved'); }
    } else { projection = parsedMarkdownProjection(this.markdown,cancel); }
    if (this.markdown.trim().length > 0 && projection.blocks.some((b: ParsedBlock): boolean => b.kind === 'Unknown')) {
      const selected: ParsedOutputProjection = parsedMarkdownProjection(this.markdown,cancel);
      for (const b of projection.blocks) { if (b.kind !== 'Unknown') { continue; } b.id = `unsupported-${selected.blocks.length}`; b.order = selected.blocks.length; b.evidenceType = 'SourceContextOnly'; selected.blocks.push(b); }
      selected.warnings.push('PartialStructureMarkdownPreserved'); projection = selected;
    }
    if (projection.blocks.length === 0 && this.markdown.trim().length > 0) { projection = parsedMarkdownProjection(this.markdown,cancel); }
    if (this.outputBase.length > 0) {
      for (const link of projection.links) {
        if (new RegExp('^[A-Za-z][A-Za-z0-9+.-]*:').test(link.member) || link.member.startsWith('/') || link.member.split('/').some((s: string): boolean => s === '..' || s === '.')) { continue; }
        const direct: boolean = this.images.some((image: ParsedImageProduction): boolean => image.member === link.member);
        if (!direct && this.images.some((image: ParsedImageProduction): boolean => image.member === this.outputBase+link.member)) { link.member = this.outputBase+link.member; }
      }
    }
    d.blocks = projection.blocks; d.warnings = projection.warnings.concat(this.warnings);
    if (this.ocrBody) { for (const b of d.blocks) { b.evidenceType = 'Ocr'; } }
    const native: ParsedOutputProjection | undefined = this.native;
    if (native !== undefined) {
      // Source object order is known within OOXML, not guessed into service text.
      for (const b of native.blocks) { b.order = d.blocks.length; b.evidenceType = 'SourceContextOnly'; b.locator.precision = ParsedPrecision.Block; b.locator.limitations.push('NativeSequenceNotAlignedToParserOutput'); d.blocks.push(b); }
      for (const link of native.links) { projection.links.push(link); }
      d.warnings.push(...native.warnings);
    }
    const recovered: Map<string, ParsedImageAsset> = new Map<string, ParsedImageAsset>();
    for (const image of this.images) {
      cancel.check(); const a: ParsedImageAsset = new ParsedImageAsset(); a.id = this.identity.id(); a.member = image.member; a.legacyContainerHash = image.legacyContainerHash;
      const matching: ParsedOutputImageLink[] = projection.links.filter((l: ParsedOutputImageLink): boolean => l.member === image.member && (image.provenance === ParsedProvenance.Native ? image.nativeBlockId.length === 0 || l.blockId === image.nativeBlockId : !l.blockId.startsWith('native-')));
      try {
        if (image.limitation.length > 0) { throw new ParsedFailure(image.limitation,'image-source'); }
        const bytes: Uint8Array = await image.reader.read(cancel); cancel.check();
        if (bytes.length < 1 || bytes.length > ParsedLimits.imageBytes) { throw new ParsedFailure('ImageBytesOutsideScope','image'); }
        a.payloadHash = await this.identity.hash(bytes); a.bytes = bytes.length;
        a.id = 'upd-'+(await this.identity.hash(parsedUtf8(`${generation}\n${a.payloadHash}`))).slice(0,32);
        const token: KnowledgeCancellation = new KnowledgeCancellation(); token.deadline = cancel.deadline;
        const header: ImageHeaderEvidence = await imageInspectHeader(new ParsedBufferedImage(bytes),'',token); cancel.check();
        a.mime = header.mime; a.pixelWidth = header.width; a.pixelHeight = header.height; a.frames = 1;
        const existing: ParsedImageAsset | undefined = recovered.get(a.payloadHash) ?? await assets.reuseImage?.(a.payloadHash,documentKey,generation,cancel);
        if (existing !== undefined) { a.id = existing.id; a.relativePath = existing.relativePath; a.state = existing.state; if (!recovered.has(a.payloadHash)) { recovered.set(a.payloadHash,a); d.images.push(a); } }
        else {
          a.relativePath = `images/${a.id}`; const w: ParsedAssetWrite = new ParsedAssetWrite(); w.id = a.id; w.documentKey = documentKey; w.generation = generation; w.role = 'image'; w.hash = a.payloadHash; w.bytes = a.bytes; w.relativePath = a.relativePath;
          const ready: ParsedImageAsset = await assets.save(a,w,bytes,cancel); a.state = ready.state; recovered.set(a.payloadHash,a); d.images.push(a);
        }
      } catch (error) {
        cancel.check();
        a.id = 'upd-'+(await this.identity.hash(parsedUtf8(`${generation}\nmissing\n${image.member}\n${image.provenance}`))).slice(0,32);
        a.state = image.limitation.startsWith('Unsupported') ? ParsedAssetState.Unsupported : ParsedAssetState.Missing;
        a.limitation = error instanceof ParsedFailure ? error.category : 'ImageRecoveryFailed'; a.relativePath = ''; d.images.push(a); d.warnings.push(a.limitation);
      }
      const links: ParsedOutputImageLink[] = matching.length > 0 ? matching : [new ParsedOutputImageLink()];
      for (const link of links) {
        const o: ParsedImageOccurrence = new ParsedImageOccurrence(); o.id = matching.length > 0 ? link.occurrenceId : `unlinked-${d.occurrences.length}`;
        if (d.occurrences.some((prior: ParsedImageOccurrence): boolean => prior.id === o.id)) { o.id = `additional-${d.occurrences.length}`; }
        o.documentKey = documentKey; o.generation = generation; o.blockId = link.blockId; o.inlineId = link.inlineId; o.order = d.occurrences.length; o.assetId = a.id;
        o.provenance = image.provenance; o.member = image.member; o.caption = link.caption || image.caption; o.ocr = image.ocr; o.ocrVersion = image.ocr.length > 0 ? this.outputId : '';
        o.locator.precision = link.blockId.length > 0 ? ParsedPrecision.Block : ParsedPrecision.Unknown; o.limitation = a.state === ParsedAssetState.Ready ? matching.length > 0 ? '' : 'DocumentLevelLocationUnknown' : a.limitation;
        d.occurrences.push(o);
      }
    }
    for (const link of projection.links) {
      if (d.occurrences.some((o: ParsedImageOccurrence): boolean => o.id === link.occurrenceId)) { continue; }
      const o: ParsedImageOccurrence = new ParsedImageOccurrence(); o.id = link.occurrenceId; o.documentKey = documentKey; o.generation = generation; o.blockId = link.blockId; o.inlineId = link.inlineId; o.order = d.occurrences.length;
      o.member = link.member; o.caption = link.caption; o.limitation = 'UnresolvedImageReferenceNoExternalRead'; d.occurrences.push(o);
    }
    if (this.ocrBody) {
      const original: ParsedImageOccurrence | undefined = d.occurrences.find((o: ParsedImageOccurrence): boolean => o.provenance === ParsedProvenance.Original);
      if (original !== undefined) { original.ocr = d.blocks.filter((b: ParsedBlock): boolean => b.evidenceType === 'Ocr').map((b: ParsedBlock): string => parsedBlockText(b)).join('\n\n'); original.ocrVersion = this.outputId;
        for (const b of d.blocks) { if (b.evidenceType === 'Ocr') { b.imageOccurrenceId = original.id; } } }
    }
    d.occurrences.sort((a: ParsedImageOccurrence, b: ParsedImageOccurrence): number => {
      const left: ParsedBlock | undefined = d.blocks?.find((block: ParsedBlock): boolean => block.id === a.blockId);
      const right: ParsedBlock | undefined = d.blocks?.find((block: ParsedBlock): boolean => block.id === b.blockId);
      const blockOrder: number = (left?.order ?? ParsedLimits.blocks)-(right?.order ?? ParsedLimits.blocks);
      if (blockOrder !== 0) { return blockOrder; }
      const leftInline: number = left?.inlines.find((r: ParsedInline): boolean => r.id === a.inlineId)?.order ?? 0;
      const rightInline: number = right?.inlines.find((r: ParsedInline): boolean => r.id === b.inlineId)?.order ?? 0;
      return leftInline-rightInline || a.order-b.order;
    });
    for (let at: number = 0; at < d.occurrences.length; at++) { d.occurrences[at].order = at; }
    for (const o of d.occurrences) { o.id = `${generation}-${o.id}`; }
    for (const b of d.blocks) {
      if (b.imageOccurrenceId.length > 0) { b.imageOccurrenceId = `${generation}-${b.imageOccurrenceId}`; }
      if (b.formula.imageOccurrenceId.length > 0) { b.formula.imageOccurrenceId = `${generation}-${b.formula.imageOccurrenceId}`; }
      for (const r of b.inlines) { if (r.imageOccurrenceId.length > 0) { r.imageOccurrenceId = `${generation}-${r.imageOccurrenceId}`; } if (r.formula.imageOccurrenceId.length > 0) { r.formula.imageOccurrenceId = `${generation}-${r.formula.imageOccurrenceId}`; } }
    }
    d.coverage.selectedOutput.state = d.warnings.some((w: string): boolean => w.includes('Preserved')) || d.blocks.some((b: ParsedBlock): boolean => b.kind === 'Unknown') ? ParsedCoverageState.Partial : ParsedCoverageState.Complete;
    d.coverage.selectedOutput.expected = d.blocks.length; d.coverage.selectedOutput.recovered = d.blocks.length;
    d.coverage.nativeLocation.reasons = ['NoExactNativeAlignment']; d.coverage.imageRecovery.expected = d.occurrences.length;
    d.coverage.imageRecovery.recovered = d.occurrences.filter((o: ParsedImageOccurrence): boolean => d.images.some((a: ParsedImageAsset): boolean => a.id === o.assetId && a.state === ParsedAssetState.Ready)).length;
    d.coverage.imageRecovery.state = d.coverage.imageRecovery.recovered === d.occurrences.length ? ParsedCoverageState.Complete : ParsedCoverageState.Partial;
    if (d.coverage.imageRecovery.state === ParsedCoverageState.Partial) { d.coverage.imageRecovery.reasons = ['ImagesMissingOrUnsupported']; }
    return d;
  }
}
