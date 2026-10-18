import { KnowledgeCancellation, KnowledgeFailure } from '../main/ets/knowledge/domain/PdfKnowledgeModels';
import { PdfWorkerResult, PdfWorkerFailure } from '../main/ets/knowledge/domain/PdfWorkerModels';
import { pdfWorkerSuccess, pdfWorkerCaught, pdfWorkerPayload, pdfWorkerRejected, pdfWorkerStage } from '../main/ets/knowledge/pipeline/PdfWorkerPolicy';

export interface PdfWorkerTestCase { name: string; run: () => Promise<void>; }
function pdfWorkerExpectReject(result: PdfWorkerResult, operation: string = 'normalize'): void {
  let rejected: boolean = false;
  try { pdfWorkerPayload(result,operation,new KnowledgeCancellation()); } catch (error) { rejected = error instanceof KnowledgeFailure; }
  if (!rejected) { throw new Error('Expected controlled worker rejection'); }
}
export function pdfWorkerCases(): PdfWorkerTestCase[] {
  return [
    { name: 'seven operations survive data-only transport and reject operation drift', run: async (): Promise<void> => {
      for (const operation of ['normalize','chunks','seal','verify','encode-node','hydrate-node','hydrate-header']) {
        const result: PdfWorkerResult = pdfWorkerSuccess(operation,[new Uint8Array([1])]);
        if (pdfWorkerPayload(result,operation,new KnowledgeCancellation())[0][0] !== 1 || pdfWorkerStage(operation).length === 0) { throw new Error('Worker success data missing'); }
        pdfWorkerExpectReject(result,operation === 'verify' ? 'normalize' : 'verify');
      }
    } },
    { name: 'wire status branches missing fields and budgets fail closed', run: async (): Promise<void> => {
      const version: PdfWorkerResult = pdfWorkerSuccess('normalize',[]); version.wire = 'PDF-WORKER-RESULT-2'; pdfWorkerExpectReject(version);
      const status: PdfWorkerResult = pdfWorkerSuccess('normalize',[]); status.status = 'maybe'; pdfWorkerExpectReject(status);
      const missing: PdfWorkerResult = new PdfWorkerResult(); missing.operation = 'normalize'; missing.status = 'success'; pdfWorkerExpectReject(missing);
      const both: PdfWorkerResult = pdfWorkerSuccess('normalize',[]); both.failure = new PdfWorkerFailure(); pdfWorkerExpectReject(both);
      const big: PdfWorkerResult = pdfWorkerSuccess('normalize',[new Uint8Array(8388609)]); pdfWorkerExpectReject(big);
      const operation: PdfWorkerResult = pdfWorkerSuccess('normalize',[]); operation.operation = 'x'.repeat(1000); pdfWorkerExpectReject(operation);
    } },
    { name: 'domain whitelist includes parser codec table chunks and cancellation', run: async (): Promise<void> => {
      for (const category of ['ProtocolProfileUnrecognized','JsonGrammarOrBudget','TableGridBudget','SnapshotBox','NoPublishableChunks','Canceled','Timeout']) {
        const stage: string = category === 'TableGridBudget' ? 'table' : category === 'SnapshotBox' ? 'codec' : category === 'NoPublishableChunks' ? 'pdf-chunk' : category === 'JsonGrammarOrBudget' ? 'pdf-json' : category === 'Canceled' || category === 'Timeout' ? 'session' : 'normalize';
        const result: PdfWorkerResult = pdfWorkerCaught('normalize',new KnowledgeFailure(category,stage));
        try { pdfWorkerPayload(result,'normalize',new KnowledgeCancellation()); throw new Error('Expected domain failure'); }
        catch (error) { if (!(error instanceof KnowledgeFailure) || error.category !== category || error.stage !== stage) { throw new Error('Domain failure lost'); } }
      }
    } },
    { name: 'unknown exceptions and untrusted domain strings never echo messages', run: async (): Promise<void> => {
      for (const error of [new Error('sensitive-body'),new KnowledgeFailure('sensitive-body','normalize'),new KnowledgeFailure('Timeout','sensitive-stage')]) {
        const result: PdfWorkerResult = pdfWorkerCaught('seal',error);
        if (result.failure?.category !== 'WorkerOperationFailed' || result.failure.stage !== 'pdf-seal' || JSON.stringify(result).includes('sensitive')) { throw new Error('Unsafe worker failure'); }
      }
    } },
    { name: 'safe numeric codes only and invalid failure category stage rejected', run: async (): Promise<void> => {
      for (const code of [1.5,Number.NaN,Number.POSITIVE_INFINITY,9007199254740992]) {
        const result: PdfWorkerResult = pdfWorkerCaught('normalize',new KnowledgeFailure('Timeout','session'));
        if (result.failure !== undefined) { result.failure.code = code; } pdfWorkerExpectReject(result);
      }
      const category: PdfWorkerResult = pdfWorkerCaught('normalize',new Error()); if (category.failure !== undefined) { category.failure.category = 'x'.repeat(1024); } pdfWorkerExpectReject(category);
      const stage: PdfWorkerResult = pdfWorkerCaught('normalize',new Error()); if (stage.failure !== undefined) { stage.failure.stage = 'untrusted'; } pdfWorkerExpectReject(stage);
      const cancel: KnowledgeCancellation = new KnowledgeCancellation();
      const rejected: KnowledgeFailure = pdfWorkerRejected('hydrate-node',cancel,10200006);
      if (rejected.category !== 'WorkerOperationFailed' || rejected.stage !== 'pdf-hydrate-node' || rejected.code !== 10200006) { throw new Error('SDK rejection lost operation'); }
    } },
    { name: 'late success and taskpool rejection preserve cancel and deadline', run: async (): Promise<void> => {
      const cancel: KnowledgeCancellation = new KnowledgeCancellation(); cancel.invalid = true;
      const expired: KnowledgeCancellation = new KnowledgeCancellation(); expired.deadline = 0;
      for (const control of [cancel,expired]) {
        let category: string = '';
        try { pdfWorkerPayload(pdfWorkerSuccess('verify',[new Uint8Array([1])]),'verify',control); } catch (error) { if (error instanceof KnowledgeFailure) { category = error.category; } }
        if (category !== (control.invalid ? 'Canceled' : 'Timeout') || pdfWorkerRejected('verify',control,10200006).category !== category) { throw new Error('Cancel deadline lost'); }
      }
    } }
  ];
}
