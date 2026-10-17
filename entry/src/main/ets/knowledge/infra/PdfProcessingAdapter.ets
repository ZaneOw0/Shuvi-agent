import { taskpool } from '@kit.ArkTS';
import { PdfArchivePort, PdfNormalizationPort } from '../domain/KnowledgePorts';
import { PdfSourceBinding, PdfZipManifest, PdfZipMember, PdfNormalizedDocument, KnowledgeCancellation, KnowledgeFailure, PdfBudget, PdfChunk, PdfContentNode } from '../domain/PdfKnowledgeModels';
import { MineruPdfNormalizer } from '../pipeline/MineruPdfNormalizer';
import { pdfCodecUtf8, pdfDecodeSnapshotHeader, pdfDecodeSnapshotNode } from '../pipeline/PdfSnapshotCodec';
import { BoundedDocumentJson } from '../pipeline/BoundedDocumentJson';
import { pdfStructureChunks } from '../pipeline/PdfStructureChunker';
import { PdfWorkerCancellation, PdfWorkerArchive } from './PdfWorkerSupport';
import { pdfVerifySnapshotWorker, pdfSealSnapshotWorker } from './PdfSnapshotWorker';
@Concurrent
async function pdfNormalizeWorker(header: Uint8Array, ids: string[], payloads: Uint8Array[], deadline: number): Promise<PdfNormalizedDocument> {
  const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline; cancel.check();
  const source: PdfNormalizedDocument = pdfDecodeSnapshotHeader(header,cancel); const members: PdfZipMember[] = [];
  for (const id of ids) { const member: PdfZipMember | undefined = source.manifest.members.find((row: PdfZipMember): boolean => row.id === id); if (member === undefined) { throw new KnowledgeFailure('WorkerMemberMissing','worker'); } members.push(member); }
  const snapshot: PdfNormalizedDocument = await new MineruPdfNormalizer().normalize(source.binding,source.manifest,new PdfWorkerArchive(members,payloads),cancel);
  let total: number = 0;
  for (const node of snapshot.nodes) { cancel.check(); const bytes: Uint8Array = pdfCodecUtf8(JSON.stringify(node)); if (bytes.length > PdfBudget.jsonBytes || (total += bytes.length) > PdfBudget.expandedBytes) { throw new KnowledgeFailure('WorkerOutputBudget','worker'); } }
  return snapshot;
}
@Concurrent
function pdfChunkWorker(snapshot: PdfNormalizedDocument, generation: string, deadline: number): PdfChunk[] {
  const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline;
  let total: number = 0;
  for (const node of snapshot.nodes) { cancel.check(); const length: number = pdfCodecUtf8(JSON.stringify(node)).length; if (length > PdfBudget.jsonBytes || (total += length) > PdfBudget.expandedBytes) { throw new KnowledgeFailure('WorkerInputBudget','worker'); } }
  return pdfStructureChunks(snapshot,generation,cancel);
}
export class PdfProcessingAdapter implements PdfNormalizationPort {
  private active: taskpool.Task | undefined = undefined;
  cancel(): void { if (this.active !== undefined) { taskpool.cancel(this.active); } }
  async sealSnapshot(snapshot: PdfNormalizedDocument, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument> {
    const task: taskpool.GenericsTask<[PdfNormalizedDocument,number],PdfNormalizedDocument> = new taskpool.GenericsTask<[PdfNormalizedDocument,number],PdfNormalizedDocument>(pdfSealSnapshotWorker,snapshot,cancel.deadline); this.active = task;
    try { const result: PdfNormalizedDocument = await taskpool.execute<[PdfNormalizedDocument,number],PdfNormalizedDocument>(task); cancel.check(); return result; } finally { this.active = undefined; }
  }
  async verifySnapshot(snapshot: PdfNormalizedDocument, cancel: KnowledgeCancellation): Promise<void> {
    const task: taskpool.GenericsTask<[PdfNormalizedDocument,number],boolean> = new taskpool.GenericsTask<[PdfNormalizedDocument,number],boolean>(pdfVerifySnapshotWorker,snapshot,cancel.deadline); this.active = task;
    try { await taskpool.execute<[PdfNormalizedDocument,number],boolean>(task); cancel.check(); } finally { this.active = undefined; }
  }
  async normalize(binding: PdfSourceBinding, manifest: PdfZipManifest, archive: PdfArchivePort, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument> {
    const ids: string[] = []; const payloads: Uint8Array[] = [];
    for (const suffix of ['_content_list.json','layout.json','_content_list_v2.json']) {
      const member: PdfZipMember | undefined = manifest.members.find((row: PdfZipMember): boolean => row.logicalName.endsWith(suffix));
      if (member === undefined) { throw new KnowledgeFailure('ProtocolMemberMissingOrAmbiguous','worker'); }
      const bytes: Uint8Array = await archive.readMember(manifest,member,cancel); if (bytes.length > PdfBudget.jsonBytes) { throw new KnowledgeFailure('WorkerInputBudget','worker'); } ids.push(member.id); payloads.push(bytes);
    }
    const source: PdfNormalizedDocument = new PdfNormalizedDocument(); source.binding = binding; source.manifest = manifest;
    const task: taskpool.GenericsTask<[Uint8Array,string[],Uint8Array[],number],PdfNormalizedDocument> = new taskpool.GenericsTask<[Uint8Array,string[],Uint8Array[],number],PdfNormalizedDocument>(pdfNormalizeWorker,pdfCodecUtf8(JSON.stringify(source)),ids,payloads,cancel.deadline);
    this.active = task;
    try {
      const snapshot: PdfNormalizedDocument = await taskpool.execute<[Uint8Array,string[],Uint8Array[],number],PdfNormalizedDocument>(task); cancel.check();
      if (snapshot.nodes.length > PdfBudget.nodes || !snapshot.coverage.hardPassed || snapshot.binding.zipHash !== binding.zipHash) { throw new KnowledgeFailure('WorkerOutputBudget','worker'); } return snapshot;
    } finally { this.active = undefined; }
  }
  async chunks(snapshot: PdfNormalizedDocument, generation: string, cancel: KnowledgeCancellation): Promise<PdfChunk[]> {
    if (snapshot.nodes.length > PdfBudget.nodes) { throw new KnowledgeFailure('WorkerInputBudget','worker'); }
    const task: taskpool.GenericsTask<[PdfNormalizedDocument,string,number],PdfChunk[]> = new taskpool.GenericsTask<[PdfNormalizedDocument,string,number],PdfChunk[]>(pdfChunkWorker,snapshot,generation,cancel.deadline);
    this.active = task;
    try { const chunks: PdfChunk[] = await taskpool.execute<[PdfNormalizedDocument,string,number],PdfChunk[]>(task); cancel.check(); return chunks; } finally { this.active = undefined; }
  }
}
