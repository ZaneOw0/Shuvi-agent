import { taskpool } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { PdfArchivePort, PdfNormalizationPort } from '../domain/KnowledgePorts';
import { PdfSourceBinding, PdfZipManifest, PdfZipMember, PdfNormalizedDocument, KnowledgeCancellation, KnowledgeFailure, PdfBudget, PdfChunk } from '../domain/PdfKnowledgeModels';
import { PdfWorkerResult } from '../domain/PdfWorkerModels';
import { MineruPdfNormalizer } from '../pipeline/MineruPdfNormalizer';
import { pdfCodecUtf8, pdfDecodeSnapshotHeader } from '../pipeline/PdfSnapshotCodec';
import { pdfStructureChunks } from '../pipeline/PdfStructureChunker';
import { pdfWorkerSuccess, pdfWorkerCaught, pdfWorkerPayload, pdfWorkerSnapshotParts, pdfWorkerReadSnapshot, pdfWorkerReadChunks, pdfWorkerRejected } from '../pipeline/PdfWorkerPolicy';
import { PdfWorkerCancellation, PdfWorkerArchive, pdfWorkerAwait } from './PdfWorkerSupport';
import { pdfVerifySnapshotWorker, pdfSealSnapshotWorker } from './PdfSnapshotWorker';

@Concurrent
export async function pdfNormalizeWorker(header: Uint8Array, ids: string[], payloads: Uint8Array[], deadline: number): Promise<PdfWorkerResult> {
  try {
    const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline; cancel.check();
    const source: PdfNormalizedDocument = pdfDecodeSnapshotHeader(header,cancel); const members: PdfZipMember[] = [];
    if (ids.length !== 3 || payloads.length !== 3) { throw new KnowledgeFailure('WorkerInputBudget','worker'); }
    for (const id of ids) { const member: PdfZipMember | undefined = source.manifest.members.find((row: PdfZipMember): boolean => row.id === id); if (member === undefined) { throw new KnowledgeFailure('WorkerMemberMissing','worker'); } members.push(member); }
    const snapshot: PdfNormalizedDocument = await new MineruPdfNormalizer().normalize(source.binding,source.manifest,new PdfWorkerArchive(members,payloads),cancel);
    return pdfWorkerSuccess('normalize',pdfWorkerSnapshotParts(snapshot,cancel));
  } catch (error) { const system: BusinessError = error; return pdfWorkerCaught('normalize',error,system?.code); }
}
@Concurrent
export function pdfChunkWorker(snapshot: PdfNormalizedDocument, generation: string, deadline: number): PdfWorkerResult {
  try {
    const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline;
    pdfWorkerSnapshotParts(snapshot,cancel);
    const chunks: PdfChunk[] = pdfStructureChunks(snapshot,generation,cancel);
    const parts: Uint8Array[] = chunks.map((chunk: PdfChunk): Uint8Array => pdfCodecUtf8(JSON.stringify(chunk)));
    pdfWorkerPayload(pdfWorkerSuccess('chunks',parts),'chunks',cancel); return pdfWorkerSuccess('chunks',parts);
  } catch (error) { const system: BusinessError = error; return pdfWorkerCaught('chunks',error,system?.code); }
}
export class PdfProcessingAdapter implements PdfNormalizationPort {
  private active: taskpool.Task | undefined = undefined;
  cancel(): void { if (this.active !== undefined) { taskpool.cancel(this.active); } }
  async sealSnapshot(snapshot: PdfNormalizedDocument, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument> {
    try {
      const task: taskpool.GenericsTask<[PdfNormalizedDocument,number],PdfWorkerResult> = new taskpool.GenericsTask<[PdfNormalizedDocument,number],PdfWorkerResult>(pdfSealSnapshotWorker,snapshot,cancel.deadline); this.active = task;
      const result: PdfWorkerResult = await pdfWorkerAwait(taskpool.execute<[PdfNormalizedDocument,number],PdfWorkerResult>(task),'seal',cancel);
      const sealed: PdfNormalizedDocument = pdfWorkerReadSnapshot(pdfWorkerPayload(result,'seal',cancel),cancel,'seal');
      if (sealed.id !== snapshot.id || sealed.documentId !== snapshot.documentId || sealed.generation !== snapshot.generation || sealed.profile !== snapshot.profile || JSON.stringify(sealed.binding) !== JSON.stringify(snapshot.binding) || sealed.nodes.length !== snapshot.nodes.length || sealed.hash.length !== 64 || sealed.coverage.hash.length !== 64 || sealed.coverage.snapshotHash !== sealed.hash) { throw new KnowledgeFailure('WorkerResultInvalid','pdf-seal'); }
      return sealed;
    } catch (error) { const system: BusinessError = error; throw error instanceof KnowledgeFailure ? error : pdfWorkerRejected('seal',cancel,system?.code); }
    finally { this.active = undefined; }
  }
  async verifySnapshot(snapshot: PdfNormalizedDocument, cancel: KnowledgeCancellation): Promise<void> {
    try {
      const task: taskpool.GenericsTask<[PdfNormalizedDocument,number],PdfWorkerResult> = new taskpool.GenericsTask<[PdfNormalizedDocument,number],PdfWorkerResult>(pdfVerifySnapshotWorker,snapshot,cancel.deadline); this.active = task;
      const result: PdfWorkerResult = await pdfWorkerAwait(taskpool.execute<[PdfNormalizedDocument,number],PdfWorkerResult>(task),'verify',cancel);
      const parts: Uint8Array[] = pdfWorkerPayload(result,'verify',cancel);
      if (parts.length !== 1 || parts[0].length !== 1 || parts[0][0] !== 1) { throw new KnowledgeFailure('WorkerResultInvalid','pdf-verify'); }
    } catch (error) { const system: BusinessError = error; throw error instanceof KnowledgeFailure ? error : pdfWorkerRejected('verify',cancel,system?.code); }
    finally { this.active = undefined; }
  }
  async normalize(binding: PdfSourceBinding, manifest: PdfZipManifest, archive: PdfArchivePort, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument> {
    const ids: string[] = []; const payloads: Uint8Array[] = [];
    for (const suffix of ['_content_list.json','layout.json','_content_list_v2.json']) {
      const members: PdfZipMember[] = manifest.members.filter((row: PdfZipMember): boolean => row.logicalName.endsWith(suffix));
      if (members.length !== 1) { throw new KnowledgeFailure('ProtocolMemberMissingOrAmbiguous','normalize'); }
      const member: PdfZipMember = members[0]; const bytes: Uint8Array = await archive.readMember(manifest,member,cancel);
      if (bytes.length > PdfBudget.jsonBytes) { throw new KnowledgeFailure('WorkerInputBudget','worker'); } ids.push(member.id); payloads.push(bytes);
    }
    const source: PdfNormalizedDocument = new PdfNormalizedDocument(); source.binding = binding; source.manifest = manifest;
    try {
      const task: taskpool.GenericsTask<[Uint8Array,string[],Uint8Array[],number],PdfWorkerResult> = new taskpool.GenericsTask<[Uint8Array,string[],Uint8Array[],number],PdfWorkerResult>(pdfNormalizeWorker,pdfCodecUtf8(JSON.stringify(source)),ids,payloads,cancel.deadline); this.active = task;
      const result: PdfWorkerResult = await pdfWorkerAwait(taskpool.execute<[Uint8Array,string[],Uint8Array[],number],PdfWorkerResult>(task),'normalize',cancel);
      const snapshot: PdfNormalizedDocument = pdfWorkerReadSnapshot(pdfWorkerPayload(result,'normalize',cancel),cancel,'normalize');
      if (snapshot.nodes.length > PdfBudget.nodes || !snapshot.coverage.hardPassed || JSON.stringify(snapshot.binding) !== JSON.stringify(binding) || JSON.stringify(snapshot.manifest) !== JSON.stringify(manifest)) { throw new KnowledgeFailure('WorkerOutputBudget','worker'); }
      return snapshot;
    } catch (error) { const system: BusinessError = error; throw error instanceof KnowledgeFailure ? error : pdfWorkerRejected('normalize',cancel,system?.code); }
    finally { this.active = undefined; }
  }
  async chunks(snapshot: PdfNormalizedDocument, generation: string, cancel: KnowledgeCancellation): Promise<PdfChunk[]> {
    if (snapshot.nodes.length > PdfBudget.nodes) { throw new KnowledgeFailure('WorkerInputBudget','worker'); }
    try {
      const task: taskpool.GenericsTask<[PdfNormalizedDocument,string,number],PdfWorkerResult> = new taskpool.GenericsTask<[PdfNormalizedDocument,string,number],PdfWorkerResult>(pdfChunkWorker,snapshot,generation,cancel.deadline); this.active = task;
      const result: PdfWorkerResult = await pdfWorkerAwait(taskpool.execute<[PdfNormalizedDocument,string,number],PdfWorkerResult>(task),'chunks',cancel);
      return pdfWorkerReadChunks(pdfWorkerPayload(result,'chunks',cancel),snapshot,generation,cancel);
    } catch (error) { const system: BusinessError = error; throw error instanceof KnowledgeFailure ? error : pdfWorkerRejected('chunks',cancel,system?.code); }
    finally { this.active = undefined; }
  }
}
