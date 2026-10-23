import { fileIo } from '@kit.CoreFileKit';
import { ImageResultReaderPort } from '../domain/ImageKnowledgePorts';
import { DocumentImageResultSourcePort } from '../domain/DocumentParsePorts';
import { ImageOriginal, ImageTextProjection, ImageKnowledgeFailure, imageHash } from '../domain/ImageKnowledgeModels';
import { DocumentParseCancellation, DocumentParseTask, DocumentParseResultEnvelope } from '../domain/DocumentParseModels';
import { KnowledgeCancellation, PdfZipMember, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { documentAssetPath, documentHashFile, documentReadRange } from './DocumentFileOperations';
import { KnowledgeRangeReader } from '../domain/KnowledgePorts';
import { pdfInspectZip, pdfStrictUtf8, pdfZipReserve } from '../pipeline/SafeZipPolicy';
import { pdfNativeReadMember, PdfExpansionAccount, PdfMemberSink } from './PdfNativeReader';

class ImageZipRange implements KnowledgeRangeReader {
  length: number; private file: fileIo.File;
  constructor(file: fileIo.File, length: number) { this.file = file; this.length = length; }
  async read(at: number, length: number, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    cancel.check(); if (!Number.isSafeInteger(at) || !Number.isSafeInteger(length) || at < 0 || length < 0 || at+length > this.length || length > 1048576) { throw new ImageKnowledgeFailure('ImageZipRange','image-result'); }
    return documentReadRange(this.file.fd,at,length);
  }
  async close(): Promise<void> { await fileIo.close(this.file); }
}
class ImageBodySink implements PdfMemberSink {
  private blocks: Uint8Array[] = []; private length: number = 0;
  async accept(bytes: Uint8Array): Promise<void> { this.length = pdfZipReserve(this.length,bytes.length,2097152); this.blocks.push(bytes.slice()); }
  bytes(): Uint8Array { const bytes: Uint8Array = new Uint8Array(this.length); let at: number = 0; for (const block of this.blocks) { bytes.set(block,at); at += block.length; } return bytes; }
}

export class ImageResultReader implements ImageResultReaderPort {
  private root: string; private owner: DocumentImageResultSourcePort;
  constructor(filesDir: string, owner: DocumentImageResultSourcePort) { this.root = filesDir+'/knowledge_parse_v1'; this.owner = owner; }
  async read(original: ImageOriginal, taskId: string, cancel: KnowledgeCancellation): Promise<ImageTextProjection> {
    const state = this.owner.viewState().snapshot;
    const task = state.tasks.find((row: DocumentParseTask): boolean => row.id === taskId && row.originalId === original.sourceId && row.hash === original.hash && row.version === original.version);
    const result = state.results.find((row: DocumentParseResultEnvelope): boolean => row.taskId === taskId && row.dataId === task?.dataId && row.originalHash === original.hash && row.version === original.version);
    if (task === undefined || result === undefined || !result.completeTransport || !result.signature || !imageHash(result.hash)) { throw new ImageKnowledgeFailure('ImageReceivedResultBindingMissing','image-result'); }
    const path: string = documentAssetPath(this.root,result.assetId); const hashCancel: DocumentParseCancellation = new DocumentParseCancellation(); hashCancel.deadline = cancel.deadline;
    if (await documentHashFile(path,31457280,hashCancel) !== result.hash) { throw new ImageKnowledgeFailure('ImageZipHashChanged','image-result'); }
    const file = await fileIo.open(path,fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    let reader: ImageZipRange | undefined = undefined;
    try {
      const stat = await fileIo.stat(file.fd);
      if (!stat.isFile() || stat.size !== result.bytes) { throw new ImageKnowledgeFailure('ImageZipSizeChanged','image-result'); }
      reader = new ImageZipRange(file,stat.size); const manifest = await pdfInspectZip(reader,cancel);
      // Hosted full.md (legacy) and markdown.md (newer) are explicit text projections, not native blocks.
      let matches: PdfZipMember[] = [];
      for (const name of ['full.md','markdown.md']) {
        matches = manifest.members.filter((member: PdfZipMember): boolean => !member.directory && member.logicalName.split('/').pop() === name);
        if (matches.length > 0) { break; }
      }
      if (matches.length !== 1) { throw new ImageKnowledgeFailure('ImageBodyMemberMissingOrAmbiguous','image-result'); }
      const member: PdfZipMember = matches[0];
      if (member.declaredBytes > 2097152) { throw new ImageKnowledgeFailure('ImageBodyTextBudget','image-result'); }
      const sink: ImageBodySink = new ImageBodySink();
      await pdfNativeReadMember(reader,member,sink,new PdfExpansionAccount(),cancel);
      const projection: ImageTextProjection = new ImageTextProjection(); projection.kind = 'MinerU-Markdown-TextProjection-1'; projection.member = member.logicalName;
      projection.memberHash = member.sha256; projection.zipHash = result.hash; projection.taskId = task.id; projection.dataId = task.dataId;
      projection.text = pdfStrictUtf8(sink.bytes()); cancel.check(); return projection;
    } catch (error) {
      if (error instanceof ImageKnowledgeFailure) { throw error; }
      if (error instanceof KnowledgeFailure) { throw new ImageKnowledgeFailure(error.category,'image-result-'+error.stage); }
      throw new ImageKnowledgeFailure('ImageResultLocalReadFailed','image-result');
    } finally { if (reader !== undefined) { await reader.close(); } else { await fileIo.close(file); } }
  }
}
