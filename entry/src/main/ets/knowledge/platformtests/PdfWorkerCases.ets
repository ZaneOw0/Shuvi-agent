import { taskpool } from '@kit.ArkTS';
import { KnowledgeCancellation, KnowledgeFailure, PdfBudget } from '../domain/PdfKnowledgeModels';
import { PdfWorkerCancellation } from '../infra/PdfWorkerSupport';
import { BoundedDocumentJson } from '../pipeline/BoundedDocumentJson';

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
