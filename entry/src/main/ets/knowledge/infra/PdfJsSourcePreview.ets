import { PdfKnowledgeRepository } from './PdfKnowledgeRepository';
import { PdfJsRuntime } from './PdfJsRuntime';
import { documentAssetPath } from './DocumentFileOperations';
import { KnowledgeLifecycleService } from '../application/KnowledgeLifecycleService';
import { KnowledgePageReferencePort } from '../domain/KnowledgePorts';
import { KnowledgeHit } from '../domain/KnowledgeSearchModels';
import { KnowledgeCancellation, KnowledgeReadLease } from '../domain/PdfKnowledgeModels';
import { DocumentOriginal, DocumentParseCancellation, DocumentParseFormat, DocumentParseFailure } from '../domain/DocumentParseModels';
import { PdfPageReferenceState } from '../domain/PdfLocalModels';

class PdfJsSourceCancellation extends KnowledgeCancellation {
  private preview: DocumentParseCancellation;
  constructor(preview: DocumentParseCancellation) { super(); this.preview=preview; this.deadline=preview.deadline; }
  check(): void { this.preview.check(); super.check(); }
}
// Legacy snapshots retain their reviewed page evidence and durable read lease.
// The preview engine is shared with the current document-detail entry.
export class PdfJsSourcePreview {
  private root: string;
  private repository: PdfKnowledgeRepository;
  private pages: KnowledgePageReferencePort;
  private lifecycle: KnowledgeLifecycleService;
  private lease: (source: string, generation: string) => KnowledgeReadLease;
  constructor(root: string, repository: PdfKnowledgeRepository, pages: KnowledgePageReferencePort, lifecycle: KnowledgeLifecycleService, lease: (source: string, generation: string) => KnowledgeReadLease) {
    this.root=root; this.repository=repository; this.pages=pages; this.lifecycle=lifecycle; this.lease=lease;
  }
  async open(hit: KnowledgeHit): Promise<void> {
    await PdfJsRuntime.shared.open(async (cancel: DocumentParseCancellation): Promise<void>=> {
      const sourceCancel: KnowledgeCancellation=new PdfJsSourceCancellation(cancel);
      try {
        cancel.check(); const reference=await this.pages.resolve(hit,sourceCancel); cancel.check();
        if (reference.state!==PdfPageReferenceState.Verified || reference.physicalPages1Based.length===0) { throw new Error('原页依据不完整，未跳转'); }
        const job=await this.repository.generationJob(hit.generation); cancel.check();
        const binding=job.binding;
        if (binding===undefined || job.snapshotId!==hit.snapshotId || job.snapshotHash!==hit.snapshotHash || binding.originalHash!==hit.originalHash || binding.originalVersion!==hit.originalVersion) { throw new Error('PDF来源版本已变化'); }
        const lease: KnowledgeReadLease=this.lease(job.sourceId,hit.generation);
        await this.lifecycle.withSource<void>(job.sourceId,async (): Promise<void>=> { cancel.check(); await this.repository.acquireRead(lease); });
        try {
          cancel.check(); const current=await this.repository.get(hit.documentId); cancel.check();
          if (current===undefined || current.tombstone || current.activeContentGeneration!==hit.generation || current.binding.originalHash!==hit.originalHash || current.binding.originalVersion!==hit.originalVersion) { throw new Error('PDF来源已变化'); }
          const original: DocumentOriginal=new DocumentOriginal(); original.id=binding.originalId; original.assetId=binding.originalAssetId; original.hash=binding.originalHash; original.version=binding.originalVersion; original.bytes=binding.originalBytes; original.format=DocumentParseFormat.Pdf; original.title=current.title;
          await PdfJsRuntime.shared.preview(documentAssetPath(this.root,binding.originalAssetId),original,cancel,reference.physicalPages1Based[0],binding.originalPages);
        } finally {
          try { await this.repository.releaseRead(lease.id); await this.repository.sourceRelease(lease,''); }
          catch { await this.repository.sourceRelease(lease,'PdfJsSourceReleaseUnconfirmed'); throw new DocumentParseFailure('PDF来源租约释放未确认，可重试释放','PDF预览'); }
        }
      } finally { sourceCancel.invalid=true; }
    });
  }
}
