import { KnowledgeAssembly, KnowledgePlatformIdentity } from './KnowledgeAssembly';
import { EmbeddingJob, EmbeddingJobStage } from '../domain/EmbeddingModels';
import { EmbeddingDryReview } from '../domain/EmbeddingBasisModels';
import { EmbeddingTrialResult } from '../domain/VectorWorkflowModels';
import { VectorInputState } from '../domain/VectorWorkflowModels';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { hilog } from '@kit.PerformanceAnalysisKit';

export async function embeddingTrialAudit(assembly: KnowledgeAssembly): Promise<void> {
  const doc = await assembly.vectorMetadata.document('kb-60986788281e094aff01063dfcf764f1');
  const plan = await assembly.vectorMetadata.corpus(doc.id); const review = assembly.workflow.review;
  const jobs = (await assembly.vectorMetadata.jobs()).filter((job: EmbeddingJob): boolean => job.documentId === doc.id); const job = jobs[jobs.length-1];
  const inputs = job === undefined ? [] : await assembly.vectorMetadata.inputs(job);
  const verified: number = inputs.filter((input): boolean => input.state === VectorInputState.Verified).length;
  const unknown: number = inputs.filter((input): boolean => input.state === VectorInputState.Unknown || input.state === VectorInputState.InFlight || input.state === VectorInputState.Received).length;
  const line: string = `R2_TRIAL_STATE doc=${doc.id} content=${doc.activeContentGeneration} job=${job?.id ?? 'None'} vector=${job?.vectorGeneration ?? 'None'} space=${job?.spaceId ?? 'None'} expected=${plan.inputs.length} verified=${verified} unknown=${unknown} remaining=${plan.inputs.length-verified} active=${doc.activeVectorGeneration.length === 0 ? 0 : 1} stage=${job?.stage ?? 'Off'} review=${review.rows.length} eligible=${review.eligible}`;
  hilog.info(0x0001,'SHUVI_R2','%{public}s',line);
  for (const input of plan.inputs.slice(0,3)) {
    const proof = review.rows.find((row): boolean => row.chunkId === input.chunk.id); const attempt = inputs.find((row): boolean => row.chunk.id === input.chunk.id);
    const item: string = `R2_TRIAL_INPUT ordinal=${input.chunk.ordinal} chunk=${input.chunk.id} hash=${input.chunk.inputHash} bound=${proof?.bound ?? -1} state=${attempt?.state ?? 'NotSent'} readback=${attempt?.readbackHash.length === 64 ? attempt.readbackHash : 'None'}`;
    hilog.info(0x0001,'SHUVI_R2','%{public}s',item);
  }
  const receipts = await assembly.host.requireStore().querySql('SELECT job,vector_generation,space,chunk,input_hash,readback_hash,bound,dimension,elapsed,total,prompt,grant_id FROM r2v_rpc_receipt ORDER BY chunk');
  try { while (receipts.goToNextRow()) { const receipt: string = `R2_TRIAL_RECEIPT job=${receipts.getString(0)} vector=${receipts.getString(1)} space=${receipts.getString(2)} chunk=${receipts.getString(3)} hash=${receipts.getString(4)} readback=${receipts.getString(5)} bound=${receipts.getLong(6)} dimension=${receipts.getLong(7)} elapsed=${receipts.getLong(8)} total=${receipts.getLong(9)} prompt=${receipts.getLong(10)} grant=${receipts.getString(11)}`; hilog.info(0x0001,'SHUVI_R2','%{public}s',receipt); } } finally { receipts.close(); }
}
export function embeddingLogTrialResult(result: EmbeddingTrialResult): void {
  const line: string = `R2_TRIAL_QUERY trial=${result.trialId} query=${result.queryHash} scope=${result.scopeHash} grant=${result.grantId} bound=${result.bound} dimension=${result.dimension} elapsed=${result.elapsed} total=${result.usage.totalTokens ?? -1} prompt=${result.usage.promptTokens ?? -1} vector_hits=${result.vectorHits.length} keyword_hits=${result.keywordHits.length} fused=${result.hits.length} expected=${result.expectedFull}`;
  hilog.info(0x0001,'SHUVI_R2','%{public}s',line);
  for (let at: number = 0; at < result.vectorHits.length; at++) { const hit = result.vectorHits[at]; const candidate: string = `R2_TRIAL_CANDIDATE rank=${at+1} chunk=${hit.chunkId} distance=${hit.vectorDistance} content=${hit.generation} space=${hit.spaceId} vector=${hit.vectorGeneration} source_checked=1`; hilog.info(0x0001,'SHUVI_R2','%{public}s',candidate); }
}
