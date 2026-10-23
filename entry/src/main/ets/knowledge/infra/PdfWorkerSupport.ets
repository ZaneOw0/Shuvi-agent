import { taskpool } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { PdfArchivePort } from '../domain/KnowledgePorts';
import { PdfSourceBinding, PdfZipManifest, PdfZipMember, KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { PdfWorkerResult } from '../domain/PdfWorkerModels';
import { pdfWorkerRejected } from '../pipeline/PdfWorkerPolicy';

export function pdfWorkerAwait(pending: Promise<PdfWorkerResult>, operation: string, cancel: KnowledgeCancellation): Promise<PdfWorkerResult> {
  return pending.catch((error: BusinessError): PdfWorkerResult => { throw pdfWorkerRejected(operation,cancel,error?.code); });
}

export class PdfWorkerCancellation extends KnowledgeCancellation {
  check(): void { super.check(); if (taskpool.Task.isCanceled()) { throw new KnowledgeFailure('Canceled','pdf-worker'); } }
}
export class PdfWorkerArchive implements PdfArchivePort {
  private members: PdfZipMember[]; private payloads: Uint8Array[];
  constructor(members: PdfZipMember[], payloads: Uint8Array[]) { this.members = members; this.payloads = payloads; }
  capability(): string { return 'VerifiedMemberTransfer'; }
  async inspect(_binding: PdfSourceBinding, _cancel: KnowledgeCancellation): Promise<PdfZipManifest> { throw new KnowledgeFailure('WorkerInspectForbidden','worker'); }
  async readMember(_manifest: PdfZipManifest, member: PdfZipMember, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    cancel.check(); const at: number = this.members.indexOf(member); if (at < 0) { throw new KnowledgeFailure('WorkerMemberMissing','worker'); } return this.payloads[at];
  }
  async release(): Promise<void> {}
}
