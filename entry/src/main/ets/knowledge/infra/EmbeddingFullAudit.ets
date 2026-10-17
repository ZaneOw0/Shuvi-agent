import { KnowledgeAssembly, KnowledgePlatformIdentity } from './KnowledgeAssembly';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { EmbeddingJob, KnowledgeVectorRow } from '../domain/EmbeddingModels';
import { VectorInputState } from '../domain/VectorWorkflowModels';
import { vectorReadbackProjection } from '../application/EmbeddingWorkflow';
import { KnowledgeQueryResult, KnowledgeHit } from '../domain/KnowledgeSearchModels';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { KnowledgeDerivedBudget } from './KnowledgeDerivedBudget';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export async function embeddingFullAudit(assembly: KnowledgeAssembly, context: common.Context): Promise<void> {
  const id: string = 'kb-a559722e0fceb2006b145f2ad9e6c656'; const identity = new KnowledgePlatformIdentity();
  const job = (await assembly.vectorMetadata.jobs()).find((item: EmbeddingJob): boolean => item.id === id);
  if (job === undefined || job.vectorGeneration !== 'kb-9e20e7c45dff0f7ba8eede3e9f8db9a7' || job.spaceId !== 'kb-5f85a339550011dce2c68243d97e2b1f' || job.contentGeneration !== 'kb-e144c7dff2b309d638cfa10b14604e3b') { throw new KnowledgeFailure('AuthorizedFullJobIdentityChanged','full-audit'); }
  const document = await assembly.vectorMetadata.document(job.documentId); const source = await assembly.repository.generationJob(job.contentGeneration);
  if (source.snapshotId !== 'kb-68c7504281b1a324817d2390b5c021e6' || source.reportHash !== '6b57aaa8827b25325bf41c1a2f82fb4c81fb3a95f6c0af1ee4d92d06a55ac864' || document.activeContentGeneration !== job.contentGeneration || document.epoch !== job.epoch) { throw new KnowledgeFailure('AuthorizedFullSourceChanged','full-audit'); }
  const inputs = await assembly.vectorMetadata.inputs(job); const lease = assembly.sourceReadLease(source.sourceId,job.contentGeneration); await assembly.repository.acquireRead(lease);
  let read: number = 0; let visible: number = 0; const hashes: string[] = []; let dimension: number = 0;
  try {
    await assembly.vectors.open(); const space = assembly.vectors.registeredSpaces().find((item): boolean => item.id === job.spaceId); if (space === undefined || space.dimension !== 1024) { throw new KnowledgeFailure('FullSpaceDimensionChanged','full-audit'); } dimension = space.dimension;
    for (const input of inputs) { if (input.state !== VectorInputState.Verified) { continue; } const row: KnowledgeVectorRow | undefined = await assembly.vectors.read(job.spaceId,input.chunk.id,job.vectorGeneration);
      if (row === undefined || row.documentId !== job.documentId || row.contentGeneration !== job.contentGeneration || row.vectorGeneration !== job.vectorGeneration || row.spaceId !== job.spaceId || row.epoch !== job.epoch || row.inputHash !== input.chunk.inputHash || row.chunkId !== input.chunk.id || row.values.length !== dimension || await identity.hash(vectorReadbackProjection(row)) !== input.readbackHash) { throw new KnowledgeFailure('FullVectorReadbackChanged','full-audit'); }
      read++; if (row.eligible) { visible++; } hashes.push(`${row.chunkId}|${row.inputHash}|${input.readbackHash}`);
    }
  } finally { await assembly.repository.releaseRead(lease.id); }
  const unknown: number = inputs.filter((input): boolean => [VectorInputState.Unknown,VectorInputState.InFlight,VectorInputState.Received].includes(input.state)).length;
  const sets = await identity.hash(pdfCodecUtf8(hashes.join('\n'))); const review = assembly.workflow.review;
  const protection = await assembly.host.requireStore().querySql('SELECT (SELECT count(*) FROM text_query),(SELECT count(*) FROM kb_query),(SELECT count(*) FROM kb_query WHERE id=?),(SELECT count(*) FROM kb_citation WHERE query_id=? AND generation=? AND space=? AND original_hash=? AND snapshot_hash=?),(SELECT count(*) FROM r2v_grant_input WHERE grant_id=?),(SELECT count(*) FROM r2v_grant_input WHERE grant_id=? AND input_hash IN (SELECT input_hash FROM kb_chunk WHERE generation=? AND ordinal<3))',['kb-ce59e12169e3ee22353ae5baf49cc94f','kb-ce59e12169e3ee22353ae5baf49cc94f',job.contentGeneration,job.spaceId,document.binding.originalHash,job.snapshotHash,'kb-6952d071663c5bbb21d64b10a9878b20','kb-6952d071663c5bbb21d64b10a9878b20',job.contentGeneration]);
  try { if (!protection.goToNextRow()) { throw new KnowledgeFailure('FullHistoryAuditMissing','full-audit'); } hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_FULL_PROTECTION m1_history=${protection.getLong(0)} kb_history=${protection.getLong(1)} authorized_history=${protection.getLong(2)} citations_current=${protection.getLong(3)} grant_inputs=${protection.getLong(4)} grant_old_overlap=${protection.getLong(5)} chunks=${document.chunkCount} snapshot=${source.snapshotId} report=${source.reportHash}`); } finally { protection.close(); }
  const mirrorRows = await assembly.host.requireStore().querySql('SELECT state FROM kb_eligibility_mirror WHERE doc=?',[job.documentId]); let mirror: string = 'None'; try { if (mirrorRows.goToNextRow()) { mirror = mirrorRows.getString(0); } } finally { mirrorRows.close(); }
  hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_FULL_STATE job=${job.id} vector=${job.vectorGeneration} space=${job.spaceId} expected=${inputs.length} verified=${read} unknown=${unknown} remaining=${inputs.length-read} active=${document.activeVectorGeneration === job.vectorGeneration ? 1 : 0} eligible=${visible} stage=${job.stage} mirror=${mirror} dimension=${dimension} readback=${sets} review=${review.rows.length} review_set=${review.setHash || 'None'}`);
  const rows = await assembly.host.requireStore().querySql('SELECT grant_id,count(*),coalesce(sum(total),0),coalesce(sum(prompt),0),coalesce(sum(elapsed),0),min(dimension),max(dimension),count(DISTINCT chunk) FROM r2v_rpc_receipt WHERE job=? GROUP BY grant_id ORDER BY grant_id',[job.id]);
  try { while (rows.goToNextRow()) { hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_FULL_USAGE grant=${rows.getString(0)} count=${rows.getLong(1)} total=${rows.getLong(2)} prompt=${rows.getLong(3)} elapsed=${rows.getLong(4)} min_dim=${rows.getLong(5)} max_dim=${rows.getLong(6)} unique=${rows.getLong(7)}`); } } finally { rows.close(); }
  const budget = await new KnowledgeDerivedBudget(context).usage(); budget.metadataReserved = await assembly.vectorMetadata.metadataBytes();
  hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_FULL_BUDGET assets=${budget.assetsPhysical} vectors=${budget.vectorPhysical} shared=${budget.sharedNonReclaimable} metadata=${budget.metadataReserved} total=${budget.total()} limit=524288000`);
}
export function embeddingLogFullQuery(assembly: KnowledgeAssembly): void {
  const result: KnowledgeQueryResult = assembly.search.state.result; const receipt = assembly.workflow.queryReceipt;
  hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_FULL_QUERY history=${assembly.search.state.historyId || 'None'} hash=${receipt.hash || 'None'} grant=${receipt.grant || 'None'} space=${receipt.space || 'None'} bound=${receipt.bound} dimension=${receipt.dimension} elapsed=${receipt.elapsed} total=${receipt.total} prompt=${receipt.prompt} targets=${receipt.targets} keyword=${result.keywordHits.length} vector=${result.vectorHits.length} hybrid=${result.hits.length} failed=${result.failed ? 1 : 0} pending=${assembly.search.state.historyPending ? 1 : 0}`);
  for (const route of result.routes) { hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_FULL_ROUTE channel=${route.channel} state=${route.state} reason=${encodeURIComponent(route.reason)} egress=${route.actualEgress ? 1 : 0}`); }
  const routes: KnowledgeHit[][] = [result.keywordHits,result.vectorHits,result.hits]; const names: string[] = ['keyword','vector','hybrid'];
  for (let at: number = 0; at < routes.length; at++) { for (let rank: number = 0; rank < Math.min(5,routes[at].length); rank++) { const hit = routes[at][rank]; hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_FULL_HIT channel=${names[at]} rank=${rank+1} source=${hit.sourceKind} chunk=${hit.chunkId} content=${hit.generation} space=${hit.spaceId || 'None'} vector=${hit.vectorGeneration || 'None'} distance=${hit.vectorDistance ?? -1} rrf=${hit.rrfScore} keyword_rank=${hit.keywordRank} vector_rank=${hit.vectorRank}`); } }
}
