import { common } from '@kit.AbilityKit';
import { KnowledgeAssembly, KnowledgePlatformIdentity } from './KnowledgeAssembly';
import { PdfProcessingAdapter } from './PdfProcessingAdapter';
import { PdfChunk } from '../domain/PdfKnowledgeModels';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { taskpool } from '@kit.ArkTS';
import { pdfVerifySnapshotWorker } from './PdfSnapshotWorker';
import { PdfLocalMetadata } from '../domain/PdfLocalModels';
import { PdfNormalizedDocument, PdfIngestionJob, PdfKnowledgeDocument, PdfNodeKind, KnowledgeCancellation, KnowledgeFailure, KnowledgeReadLease } from '../domain/PdfKnowledgeModels';

export async function pdfAuditPublishedSnapshot(context: common.Context): Promise<PdfLocalMetadata> {
  const assembly: KnowledgeAssembly = KnowledgeAssembly.forContext(context); await assembly.acquire();
  const result: PdfLocalMetadata = new PdfLocalMetadata(); let lease: KnowledgeReadLease | undefined = undefined;
  try {
    const documents: PdfKnowledgeDocument[] = await assembly.repository.list();
    const document: PdfKnowledgeDocument | undefined = documents.find((item: PdfKnowledgeDocument): boolean => !item.tombstone && item.binding.taskId === 'm2-7eaa150e269374313fd776f12a2ae9fa');
    if (document === undefined) { throw new KnowledgeFailure('AuthorizedDocumentMissing','audit'); }
    const job: PdfIngestionJob = await assembly.repository.generationJob(document.activeContentGeneration);
    if (job.reportHash !== '6b57aaa8827b25325bf41c1a2f82fb4c81fb3a95f6c0af1ee4d92d06a55ac864') { throw new KnowledgeFailure('ApprovedReportChanged','audit'); }
    lease = assembly.sourceReadLease(job.sourceId,job.generation); await assembly.repository.acquireRead(lease);
    const snapshot: PdfNormalizedDocument = await assembly.assets.read(job.snapshotId,new KnowledgeCancellation());
    await taskpool.execute<[PdfNormalizedDocument,number],boolean>(pdfVerifySnapshotWorker,snapshot,Date.now()+120000);
    const chunks: PdfChunk[] = await new PdfProcessingAdapter().chunks(snapshot,job.generation,new KnowledgeCancellation());
    for (const chunk of chunks) { chunk.inputHash = await new KnowledgePlatformIdentity().hash(pdfCodecUtf8(chunk.embeddingText)); }
    await assembly.repository.bindExistingChunkSources(job.generation,chunks);
    if (snapshot.hash !== job.snapshotHash || snapshot.coverage.hash !== job.reportHash || snapshot.generation !== job.generation || snapshot.documentId !== document.id) { throw new KnowledgeFailure('SnapshotIdentityMismatch','audit'); }
    result.document = document.id; result.generation = job.generation; result.job = job.id; result.snapshot = snapshot.id; result.snapshotHash = snapshot.hash; result.reportHash = snapshot.coverage.hash;
    result.originalHash = snapshot.binding.originalHash; result.zipHash = snapshot.binding.zipHash; result.nodes = snapshot.nodes.length; result.images = snapshot.images.length; result.verifiedImages = snapshot.images.length; result.published = document.activeContentGeneration === job.generation;
    for (const node of snapshot.nodes) {
      if (node.parentId.length === 0) { result.primary++; }
      for (const run of node.runs) { if (run.kind === 'equation_inline') { result.inline++; } }
      if (node.kind === PdfNodeKind.Formula) { result.formulas++; }
      if (node.table !== undefined) { result.tables++; result.cells += node.table.cells.length; }
      if (!node.verified) { result.excluded++; }
    }
    const counts: number[] = await assembly.repository.localCounts(job.generation); result.chunks = counts[0]; result.assets = counts[1]; result.ledgerBytes = counts[2];
  } finally {
    if (lease !== undefined) { await assembly.repository.releaseRead(lease.id); result.readLeases = (await assembly.repository.localCounts(lease.generation))[3]; }
    await assembly.release();
  }
  return result;
}
