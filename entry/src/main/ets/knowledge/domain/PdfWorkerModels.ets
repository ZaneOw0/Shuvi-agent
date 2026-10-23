// Data only: neither the envelope nor its failure needs a prototype after transfer.
export class PdfWorkerFailure {
  category: string = 'WorkerOperationFailed';
  stage: string = 'pdf-worker';
  code?: number;
}
export class PdfWorkerResult {
  wire: string = 'PDF-WORKER-RESULT-1';
  operation: string = '';
  status: string = '';
  payload?: Uint8Array[];
  failure?: PdfWorkerFailure;
}
