import { taskpool } from '@kit.ArkTS';
import { KnowledgeCancellation, KnowledgeFailure, PdfBudget, PdfSourceBinding, PdfZipManifest, PdfZipMember } from '../domain/PdfKnowledgeModels';
import { PdfWorkerCancellation } from '../infra/PdfWorkerSupport';
import { BoundedDocumentJson } from '../pipeline/BoundedDocumentJson';
import { PdfWorkerResult } from '../domain/PdfWorkerModels';
import { pdfWorkerCaught, pdfWorkerSuccess, pdfWorkerPayload } from '../pipeline/PdfWorkerPolicy';
import { pdfWorkerAwait } from '../infra/PdfWorkerSupport';
import { pdfHydrateNodeWorker } from '../infra/PdfSnapshotWorker';
import { PdfProcessingAdapter } from '../infra/PdfProcessingAdapter';
import { PdfArchivePort } from '../domain/KnowledgePorts';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';

@Concurrent
export function pdfJsonProbe(bytes: Uint8Array, deadline: number): number {
  const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline;
  return new BoundedDocumentJson(bytes,cancel).read().fields.length;
}
export async function pdfWorkerCancellationCase(): Promise<void> {
  const bytes: Uint8Array = new Uint8Array(PdfBudget.jsonBytes); bytes.fill(32); bytes[bytes.length-2] = 123; bytes[bytes.length-1] = 125;
  const task: taskpool.GenericsTask<[Uint8Array,number],number> = new taskpool.GenericsTask<[Uint8Array,number],number>(pdfJsonProbe,bytes,Date.now()+120000);
  let started: boolean = false; task.onStartExecution((): void => { started = true; taskpool.cancel(task); });
  const execution: Promise<number> = taskpool.execute<[Uint8Array,number],number>(task);
  let rejected: boolean = false; try { await execution; } catch { rejected = true; }
  if (!rejected || !started) { throw new KnowledgeFailure('WorkerCancelNotObserved','suite'); }
  const oversized: Uint8Array = new Uint8Array(PdfBudget.jsonBytes+1); rejected = false;
  try { await taskpool.execute<[Uint8Array,number],number>(pdfJsonProbe,oversized,Date.now()+120000); } catch { rejected = true; }
  if (!rejected) { throw new KnowledgeFailure('WorkerBudgetNotObserved','suite'); }
  rejected = false; try { await taskpool.execute<[Uint8Array,number],number>(pdfJsonProbe,new Uint8Array([123,125]),Date.now()-1); } catch { rejected = true; }
  if (!rejected) { throw new KnowledgeFailure('WorkerDeadlineNotObserved','suite'); }
}

// Prepared only. Never called automatically by a production lifecycle or host suite.
@Concurrent
export function pdfWorkerFailureProbe(kind: string): PdfWorkerResult {
  try {
    if (kind === 'domain') { throw new KnowledgeFailure('ProtocolProfileUnrecognized','normalize'); }
    if (kind === 'unknown') { throw new Error('withheld'); }
    return pdfWorkerSuccess('verify',[new Uint8Array([1])]);
  } catch (error) { return pdfWorkerCaught('verify',error); }
}
class PdfWorkerRejectedProfileArchive implements PdfArchivePort {
  capability(): string { return 'SyntheticRejectedProfile'; }
  async inspect(_binding: PdfSourceBinding, _cancel: KnowledgeCancellation): Promise<PdfZipManifest> { throw new KnowledgeFailure('WorkerInspectForbidden','worker'); }
  async readMember(_manifest: PdfZipManifest, member: PdfZipMember, _cancel: KnowledgeCancellation): Promise<Uint8Array> {
    if (member.logicalName === 'layout.json') { return pdfCodecUtf8('{"_version_name":"unrecognized","_backend":"hybrid","_effort":"medium","_ocr_enable":false,"pdf_info":[{"page_idx":0}]}'); }
    return pdfCodecUtf8('[]');
  }
  async release(): Promise<void> {}
}
export async function pdfWorkerEnvelopePlatformCase(): Promise<void> {
  const binding: PdfSourceBinding = new PdfSourceBinding(); binding.zipHash = 'b'.repeat(64); binding.originalPages = 1;
  const manifest: PdfZipManifest = new PdfZipManifest(); manifest.hardPassed = true; manifest.zipHash = binding.zipHash;
  for (const name of ['fixture_content_list.json','layout.json','fixture_content_list_v2.json']) { const member: PdfZipMember = new PdfZipMember(); member.id = name; member.logicalName = name; member.verified = true; member.actualCrc32 = 0; manifest.members.push(member); }
  let profileRejected: boolean = false;
  try { await new PdfProcessingAdapter().normalize(binding,manifest,new PdfWorkerRejectedProfileArchive(),new KnowledgeCancellation()); }
  catch (error) { profileRejected = error instanceof KnowledgeFailure && error.category === 'ProtocolProfileUnrecognized' && error.stage === 'normalize'; }
  if (!profileRejected) { throw new KnowledgeFailure('WorkerProfileBoundaryMismatch','suite'); }
  for (const kind of ['domain','unknown','timeout']) {
    const cancel: KnowledgeCancellation = new KnowledgeCancellation();
    const pending: Promise<PdfWorkerResult> = kind === 'timeout' ? taskpool.execute<[Uint8Array,number],PdfWorkerResult>(pdfHydrateNodeWorker,new Uint8Array([123,125]),0) : taskpool.execute<[string],PdfWorkerResult>(pdfWorkerFailureProbe,kind);
    const result: PdfWorkerResult = await pdfWorkerAwait(pending,kind === 'timeout' ? 'hydrate-node' : 'verify',cancel);
    let category: string = ''; let stage: string = '';
    try { pdfWorkerPayload(result,kind === 'timeout' ? 'hydrate-node' : 'verify',cancel); }
    catch (error) { if (error instanceof KnowledgeFailure) { category = error.category; stage = error.stage; } }
    if (category !== (kind === 'domain' ? 'ProtocolProfileUnrecognized' : kind === 'timeout' ? 'Timeout' : 'WorkerOperationFailed') || stage !== (kind === 'domain' ? 'normalize' : kind === 'timeout' ? 'session' : 'pdf-verify')) { throw new KnowledgeFailure('WorkerEnvelopeBoundaryMismatch','suite'); }
  }
}
