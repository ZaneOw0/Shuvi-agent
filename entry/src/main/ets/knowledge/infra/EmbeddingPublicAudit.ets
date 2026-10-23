import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KnowledgeAssembly, KnowledgePlatformIdentity } from './KnowledgeAssembly';
import { EmbeddingBudget } from '../domain/EmbeddingModels';
import { embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';

export async function embeddingPublicAudit(context: common.Context): Promise<void> {
  const assembly = KnowledgeAssembly.forContext(context);
  if (!assembly.repository.ready()) { throw new KnowledgeFailure('EmbeddingAuditNotReady','audit'); }
  const state = assembly.embedding.state; const config = state.config; const detection = state.detection;
  const identity = new KnowledgePlatformIdentity(); const fingerprint = await identity.hash(pdfCodecUtf8(embeddingFingerprint(config)));
  const basis = await assembly.embedding.baseline();
  const exact: string = config.modelId === 'BAAI/bge-m3' ? 'BAAI/bge-m3' : 'Other';
  const requested: string = detection.requestedModel === 'BAAI/bge-m3' ? 'BAAI/bge-m3' : detection.requestedModel.length === 0 ? 'None' : 'Other';
  const returned: string = detection.returnedModel === 'BAAI/bge-m3' ? 'BAAI/bge-m3' : detection.returnedModel.length === 0 ? 'None' : 'Other';
  const line: string = `R2_EMBED_STATE provider=${config.provider} model=${exact} credential=${state.credential} revision=${config.revision} credential_revision=${config.credentialRevision} pending=${config.mutationPending ? 1 : 0} busy=${state.busy ? 1 : 0} detection=${detection.status} basis=${basis.state} models=${state.models.length} target=${state.models.some((model): boolean => model.id === 'BAAI/bge-m3' && model.configFingerprint === embeddingFingerprint(config)) ? 1 : 0} fingerprint=${fingerprint}`;
  hilog.info(0x0001,'SHUVI_R2','%{public}s',line);
  const expectedProbe: string = await identity.hash(pdfCodecUtf8(EmbeddingBudget.probe));
  const probe: string = detection.probeHash.length === 64 ? detection.probeHash : 'None';
  const detail: string = `R2_EMBED_DETECTION requested=${requested} returned=${returned} dimension=${detection.dimension} elapsed=${detection.elapsedMs} total=${detection.usage.totalTokens ?? -1} prompt=${detection.usage.promptTokens ?? -1} probe=${probe} expected=${expectedProbe} current=${detection.configFingerprint === embeddingFingerprint(config) && detection.credentialRevision === config.credentialRevision ? 1 : 0} provider_revision=NotReported provider_consistency=UnverifiedRevisionAndHiddenProcessing`;
  hilog.info(0x0001,'SHUVI_R2','%{public}s',detail);
  const message: string = state.message; let category: string = 'None'; let http: number = 0;
  for (const item of ['ResponseJsonInvalid','ResponseShape','ResponseField','ResponseString','ResponseInteger','ResponseArray','ModelsObject','ModelsIdentity','VectorModelMismatch','VectorCountOrIndex','VectorDimension','VectorNonFinite','VectorZeroNorm','Timeout','ResponseIncomplete','NetworkTlsOrCredentialRejected','CredentialMissing','StaleOrMismatchedProbe','ProbeFailedNoRetry']) { if (message.startsWith(item+' /') || message === item) { category = item; } }
  if (message.startsWith('HttpRejected:')) { const code: number = Number.parseInt(message.slice('HttpRejected:'.length),10); if (Number.isSafeInteger(code) && code >= 100 && code <= 599) { http = code; category = 'HttpRejected'; } }
  hilog.info(0x0001,'SHUVI_R2','R2_EMBED_STATUS category=%{public}s http=%{public}d',category,http);
  const rows = await assembly.host.requireStore().querySql('SELECT (SELECT count(*) FROM kb_vector_generation),(SELECT count(*) FROM kb_embedding_grant WHERE purpose IN (?,?)),(SELECT count(*) FROM kb_input_attempt)', ['PdfCorpus','Query']);
  try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('EmbeddingAuditCountsMissing','audit'); } hilog.info(0x0001,'SHUVI_R2','R2_EMBED_PROTECTION vector_generations=%{public}d corpus_query_grants=%{public}d input_attempts=%{public}d',rows.getLong(0),rows.getLong(1),rows.getLong(2)); } finally { rows.close(); }
}
