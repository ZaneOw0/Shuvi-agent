import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { KnowledgeStoreHost } from '../infra/KnowledgeStoreHost';
import { TextRdbRepository } from '../infra/TextRdbRepository';
import { PdfKnowledgeRepository } from '../infra/PdfKnowledgeRepository';
import { PdfVectorRepository } from '../infra/PdfVectorRepository';
import { VectorRdbRepository } from '../infra/VectorRdbRepository';
import { KnowledgeAssembly, KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';
import { EmbeddingCredentialStore } from '../infra/EmbeddingCredentialStore';
import { EmbeddingTransportAdapter } from '../infra/EmbeddingTransportAdapter';
import { EmbeddingTokenAdapter } from '../infra/EmbeddingTokenAdapter';
import { copyEmbeddingConfig } from '../application/EmbeddingService';
import { embeddingFingerprint, embeddingAuthorize } from '../pipeline/EmbeddingPolicy';
import { embeddingLocalEligible } from '../pipeline/EmbeddingBasisPolicy';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { EmbeddingConfig, EmbeddingSpace, EmbeddingGrant, EmbeddingPurpose, EmbeddingFreeEligibility, EmbeddingDetectionStatus, EmbeddingCredentialStatus, TokenEligibilityEvidence, KnowledgeVectorRow, EmbeddingVectorResponse } from '../domain/EmbeddingModels';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { VectorEligibility } from '../domain/VectorWorkflowModels';
import { KnowledgeHit } from '../domain/KnowledgeSearchModels';
import { vectorReadbackProjection } from '../application/EmbeddingWorkflow';
import { qualityManifest, QualityManifest, QualityCaseResult, QualityRule, QualityQuestion, QualityAttemptBudget, qualityHit, qualityEvaluate } from './SemanticQualityPolicy';
import { embeddingSpaceDecode } from '../pipeline/EmbeddingSpacePolicy';
import { KnowledgeDerivedBudget } from '../infra/KnowledgeDerivedBudget';

export const QUALITY_RUN: string = 'a220261017240001';
export class SemanticQualitySession {
  static stopped: boolean = false;
  static transport: EmbeddingTransportAdapter | undefined = undefined;
  static background(): void { SemanticQualitySession.stopped = true; SemanticQualitySession.transport?.cancel(); }
}
const QUALITY_RULES_HASH: string = 'de11199f48c05676167b84a1d0a05a005373a6fab2b3e71e969acf76835e2201';
const QUALITY_GOLD_HASH: string = '32daf3262db161944ec2f9da02ac1db683c8c46e75b092bd22b83ec95aa86b09';
class QualityPrepared {
  manifest: QualityManifest = new QualityManifest(); hashes: string[] = []; proofs: TokenEligibilityEvidence[] = []; setHash: string = '';
}
async function qualityPrepare(context: common.Context, config: EmbeddingConfig): Promise<QualityPrepared> {
  const identity = new KnowledgePlatformIdentity(); const rules = await context.resourceManager.getRawFileContent('quality/round2-semantic-manual-v1.md'); const gold = await context.resourceManager.getRawFileContent('quality/round2-semantic-gold-v1.json');
  if (await identity.hash(rules) !== QUALITY_RULES_HASH || await identity.hash(gold) !== QUALITY_GOLD_HASH) { throw new KnowledgeFailure('QualityFrozenResourceHash','quality'); }
  const prepared = new QualityPrepared(); prepared.manifest = qualityManifest(util.TextDecoder.create('utf-8',{ fatal: true }).decodeToString(rules),util.TextDecoder.create('utf-8',{ fatal: true }).decodeToString(gold)); const counter = new EmbeddingTokenAdapter(context,identity);
  const inputs: string[] = prepared.manifest.rules.map((rule: QualityRule): string => rule.text).concat(prepared.manifest.questions.map((q: QualityQuestion): string => q.text));
  for (let at: number = 0; at < inputs.length; at++) { const hash = await identity.hash(pdfCodecUtf8(inputs[at])); prepared.hashes.push(hash); prepared.proofs.push(await counter.evidence(config.modelId,at < 8 ? 'document' : 'query',inputs[at],hash)); }
  prepared.setHash = await identity.hash(pdfCodecUtf8(JSON.stringify([QUALITY_RULES_HASH,QUALITY_GOLD_HASH,embeddingFingerprint(config),prepared.hashes,prepared.proofs.map((proof: TokenEligibilityEvidence): string => proof.bindingHash)]))); return prepared;
}
function qualityScope(): KnowledgeStorageScope { const scope = KnowledgeStorageScope.isolated(QUALITY_RUN); scope.requireTestOwner(QUALITY_RUN); return scope; }
async function qualityTables(store: relationalStore.RdbStore): Promise<void> {
  await store.executeSql('CREATE TABLE IF NOT EXISTS quality_run (id TEXT PRIMARY KEY,set_hash TEXT NOT NULL,config TEXT NOT NULL,space TEXT NOT NULL,wire TEXT NOT NULL,state TEXT NOT NULL)');
  await store.executeSql('CREATE TABLE IF NOT EXISTS quality_input (id TEXT PRIMARY KEY,role TEXT NOT NULL,hash TEXT NOT NULL,binding TEXT NOT NULL,bound INTEGER NOT NULL,text TEXT NOT NULL,state TEXT NOT NULL,readback TEXT NOT NULL,total INTEGER NOT NULL,prompt INTEGER NOT NULL,elapsed INTEGER NOT NULL,grant_id TEXT NOT NULL)');
  await store.executeSql('CREATE TABLE IF NOT EXISTS quality_result (id TEXT PRIMARY KEY,wire TEXT NOT NULL)');
}
function qualityLogCase(row: QualityCaseResult): void {
  const text: string = `R2_QUALITY_CASE id=${row.id} kind=${row.kind} gold=${row.gold.join(',') || 'None'} keyword=${row.keyword.join(',') || 'None'} vector=${row.vector.join(',') || 'None'} hybrid=${row.hybrid.join(',') || 'None'} distances=${row.distances.join(',')} gold_distance=${row.goldDistance} kr=${row.keywordRank} vr=${row.vectorRank} hr=${row.hybridRank} forbidden_rank=${row.forbiddenRank} noanswer=${row.noAnswer ? 1 : 0} answer_generated=0`;
  hilog.info(0x0001,'SHUVI_R2','%{public}s',text);
}
function qualityLogMetrics(results: QualityCaseResult[]): string {
  const answer = results.filter((row: QualityCaseResult): boolean => !row.noAnswer); const recalled = answer.filter((row: QualityCaseResult): boolean => row.hybridRank > 0).length; let reciprocal: number = 0; for (const row of answer) { reciprocal += row.hybridRank > 0 ? 1/row.hybridRank : 0; }
  const recovered = results.filter((row: QualityCaseResult): boolean => row.kind === 'paraphrase' && row.keywordRank === 0 && row.vectorRank > 0).length;
  const negation = results.filter((row: QualityCaseResult): boolean => row.kind === 'negation' && row.hybridRank > 0 && (row.forbiddenRank === 0 || row.hybridRank < row.forbiddenRank)).length;
  const noanswer = results.filter((row: QualityCaseResult): boolean => row.noAnswer && row.vector.length > 0).length;
  const recall: number = recalled/12; const mrr: number = reciprocal/12; const pass: boolean = results.length === 16 && recall >= 0.8 && mrr >= 0.6 && recovered >= 2 && negation === 4;
  hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_QUALITY_METRICS cases=${results.length} answers=${answer.length} recalled=${recalled} recall=${recall} mrr=${mrr} paraphrase_recovered=${recovered} negation_correct=${negation} noanswer_nonempty=${noanswer} answers_generated=0 pass=${pass ? 1 : 0}`); return pass ? 'QualityPASS' : 'QualityFAIL';
}
export async function semanticQualityContract(context: common.Context): Promise<string> {
  const assembly = KnowledgeAssembly.forContext(context); await assembly.acquire();
  try {
    const config = copyEmbeddingConfig(assembly.embedding.state.config); const prepared = await qualityPrepare(context,config); const basis = await assembly.vectorMetadata.baseline(config);
    for (const proof of prepared.proofs) { proof.baseline = basis; if (!embeddingLocalEligible(proof,config)) { throw new KnowledgeFailure('QualityInputNotEligible','quality'); } }
    const grant = new EmbeddingGrant(); grant.id = 'contract'; grant.purpose = EmbeddingPurpose.Corpus; grant.provider = config.provider; grant.configFingerprint = embeddingFingerprint(config); grant.credentialRevision = config.credentialRevision; grant.issuedAt = Date.now(); grant.expiresAt = Date.now()+10000; grant.spaceId = 'quality'; grant.sessionId = QUALITY_RUN; grant.inputHashes = prepared.hashes.slice(0,8); grant.inputEvidence = prepared.proofs.slice(0,8);
    let rejected: boolean = false; try { embeddingAuthorize(config,grant,EmbeddingPurpose.Corpus); } catch { rejected = true; } if (!rejected) { throw new KnowledgeFailure('QualityFreeGuardFailed','quality'); } grant.free = EmbeddingFreeEligibility.Confirmed; embeddingAuthorize(config,grant,EmbeddingPurpose.Corpus); rejected = false; try { embeddingAuthorize(config,grant,EmbeddingPurpose.Query); } catch { rejected = true; } if (!rejected) { throw new KnowledgeFailure('QualityPurposeGuardFailed','quality'); }
    hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_QUALITY_CONTRACT docs=8 queries=16 hashes=24 set=${prepared.setHash} free_guard=1 purpose_guard=1 requests=0`); return 'QualityContractPASS';
  } finally { await assembly.release(); }
}
export async function semanticQualityRun(context: common.Context, consent: boolean, free: boolean): Promise<string> {
  if (!consent || !free) { throw new KnowledgeFailure('QualityExplicit24ConsentRequired','quality'); }
  SemanticQualitySession.stopped = false;
  const scope = qualityScope(); const assembly = KnowledgeAssembly.forContext(context); await assembly.acquire();
  const host = KnowledgeStoreHost.forContext(context,scope); const text = new TextRdbRepository(context,host); const pdf = new PdfKnowledgeRepository(host); const repository = new PdfVectorRepository(host,pdf); const vectors = new VectorRdbRepository(context,scope); const identity = new KnowledgePlatformIdentity();
  let store: relationalStore.RdbStore | undefined; let claimed: boolean = false; let activeId: string = ''; let starts: number = 0; const results: QualityCaseResult[] = []; const started: number = Date.now(); const budget = new QualityAttemptBudget();
  try {
    const state = assembly.embedding.state; const config = copyEmbeddingConfig(state.config);
    if (config.provider !== 'SiliconFlow' || config.modelId !== 'BAAI/bge-m3' || state.credential !== EmbeddingCredentialStatus.Configured || state.detection.status !== EmbeddingDetectionStatus.Passed || state.detection.dimension !== 1024 || state.detection.configFingerprint !== embeddingFingerprint(config) || state.detection.credentialRevision !== config.credentialRevision) { throw new KnowledgeFailure('QualityCurrentProviderDetectionRequired','quality'); }
    const prepared = await qualityPrepare(context,config); const basis = await assembly.vectorMetadata.baseline(config); for (const proof of prepared.proofs) { proof.baseline = basis; if (!embeddingLocalEligible(proof,config)) { throw new KnowledgeFailure('QualityInputNotEligible','quality'); } }
    await text.open(); await pdf.open(); await repository.bootstrap(); await repository.saveBaseline(basis); store = host.requireStore(); await qualityTables(store);
    const space = new EmbeddingSpace(); space.id = identity.id(); space.fingerprint = await identity.hash(pdfCodecUtf8(JSON.stringify([embeddingFingerprint(config),basis.profile,basis.revision,basis.tokenizer,basis.parameters,1024,'QualityScopeOnly']))); space.configFingerprint = embeddingFingerprint(config); space.provider = config.provider; space.requestedModel = config.modelId; space.returnedModel = config.modelId; space.dimension = 1024; space.profileId = basis.profile; space.profileRevision = basis.revision; space.tokenizerSha256 = basis.tokenizer; space.profileParameters = basis.parameters; space.rolePair = 'SingleStringNoInventedPrefix';
    // Exclusive durable run claim precedes grants or any request. Existing run
    // cannot be resumed/retried under this 24-call authorization.
    await store.executeSql('INSERT INTO quality_run VALUES(?,?,?,?,?,?)',[QUALITY_RUN,prepared.setHash,embeddingFingerprint(config),space.id,JSON.stringify(space),'Claimed']);
    claimed = true;
    const ids = prepared.manifest.rules.map((rule: QualityRule): string => rule.id).concat(prepared.manifest.questions.map((q: QualityQuestion): string => q.id)); const texts = prepared.manifest.rules.map((rule: QualityRule): string => rule.text).concat(prepared.manifest.questions.map((q: QualityQuestion): string => q.text));
    for (let at: number = 0; at < ids.length; at++) { await store.executeSql('INSERT INTO quality_input VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',[ids[at],at < 8 ? 'document' : 'query',prepared.hashes[at],prepared.proofs[at].bindingHash,prepared.proofs[at].upperBound,texts[at],'NotSent','',-1,-1,0,'']); hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_QUALITY_INPUT id=${ids[at]} role=${at < 8 ? 'document' : 'query'} hash=${prepared.hashes[at]} binding=${prepared.proofs[at].bindingHash} bound=${prepared.proofs[at].upperBound}`); }
    const credential = new EmbeddingCredentialStore(); const transport = new EmbeddingTransportAdapter(credential,identity); const counter = new EmbeddingTokenAdapter(context,identity); transport.attachInputPolicy(counter,repository);
    SemanticQualitySession.transport = transport;
    const grants: EmbeddingGrant[] = [];
    for (const purpose of [EmbeddingPurpose.Corpus,EmbeddingPurpose.Query]) { const grant = new EmbeddingGrant(); grant.id = identity.id(); grant.purpose = purpose; grant.provider = config.provider; grant.configFingerprint = embeddingFingerprint(config); grant.credentialRevision = config.credentialRevision; grant.documentId = `quality-${QUALITY_RUN}`; grant.generation = QUALITY_RUN; grant.snapshotHash = prepared.setHash; grant.spaceId = space.id; grant.sessionId = QUALITY_RUN; grant.free = EmbeddingFreeEligibility.Confirmed; grant.issuedAt = Date.now(); grant.expiresAt = grant.issuedAt+900000; const from: number = purpose === EmbeddingPurpose.Corpus ? 0 : 8; const to: number = purpose === EmbeddingPurpose.Corpus ? 8 : 24; grant.inputHashes = prepared.hashes.slice(from,to); grant.inputEvidence = prepared.proofs.slice(from,to); grant.inputChunkIds = ids.slice(from,to); embeddingAuthorize(config,grant,purpose); await pdf.saveGrant(grant); grants.push(grant); }
    await vectors.open(); await vectors.register(space);
    const targets: VectorEligibility[] = [];
    for (let at: number = 0; at < ids.length; at++) {
      if (SemanticQualitySession.stopped || embeddingFingerprint(assembly.embedding.state.config) !== embeddingFingerprint(config)) { throw new KnowledgeFailure('QualityStoppedOrConfigurationChanged','quality'); }
      activeId = ids[at]; const cancel = new KnowledgeCancellation(); cancel.deadline = Math.min(started+900000,Date.now()+120000); cancel.check(); const grant = grants[at < 8 ? 0 : 1]; embeddingAuthorize(config,grant,grant.purpose);
      budget.claim(ids[at],at < 8);
      await store.executeSql('UPDATE quality_input SET state=?,grant_id=? WHERE id=? AND state=?',['InFlight',grant.id,ids[at],'NotSent']); starts++; const requestAt: number = Date.now();
      hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_QUALITY_ATTEMPT id=${ids[at]} role=${at < 8 ? 'document' : 'query'} ordinal=${at} grant=${grant.id} count=${starts}`);
      const response: EmbeddingVectorResponse = await transport.embed(config,grant,grant.purpose,texts[at],cancel); cancel.check(); if (response.model !== config.modelId || response.index !== 0 || response.vector.length !== 1024) { throw new KnowledgeFailure('QualityResponseModelDimension','quality'); }
      const row = new KnowledgeVectorRow(); row.spaceId = space.id; row.chunkId = ids[at]; row.documentId = at < 8 ? ids[at] : 'QualityQueryOnly'; row.contentGeneration = QUALITY_RUN; row.vectorGeneration = QUALITY_RUN; row.inputHash = prepared.hashes[at]; row.values = response.vector; row.eligible = at < 8;
      await vectors.put(row); const read = await vectors.read(space.id,row.chunkId,row.vectorGeneration); if (read === undefined) { throw new KnowledgeFailure('QualityVectorMissing','quality'); } const readback = await identity.hash(vectorReadbackProjection(read));
      await store.executeSql('UPDATE quality_input SET state=?,readback=?,total=?,prompt=?,elapsed=? WHERE id=?',['ReadbackVerified',readback,response.usage.totalTokens ?? -1,response.usage.promptTokens ?? -1,Date.now()-requestAt,ids[at]]);
      hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_QUALITY_RECEIPT id=${ids[at]} dimension=1024 elapsed=${Date.now()-requestAt} total=${response.usage.totalTokens ?? -1} prompt=${response.usage.promptTokens ?? -1} readback=${readback}`);
      if (at < 8) { const target = new VectorEligibility(); target.chunkIds = [row.chunkId]; target.documentId = row.documentId; target.contentGeneration = QUALITY_RUN; target.vectorGeneration = QUALITY_RUN; target.spaceId = space.id; target.inputHash = row.inputHash; target.readbackHash = readback; targets.push(target); }
      else { const candidates = await vectors.filteredKnn(space,read.values,targets,cancel); const hits: KnowledgeHit[] = []; for (const candidate of candidates) { const rule = prepared.manifest.rules.find((rule: QualityRule): boolean => rule.id === candidate.row.chunkId); const target = targets.find((target: VectorEligibility): boolean => target.chunkIds[0] === candidate.row.chunkId); if (rule === undefined || target === undefined || candidate.row.documentId !== rule.id || candidate.row.spaceId !== space.id || candidate.row.contentGeneration !== QUALITY_RUN || candidate.row.vectorGeneration !== QUALITY_RUN || await identity.hash(vectorReadbackProjection(candidate.row)) !== target.readbackHash) { throw new KnowledgeFailure('QualityCandidateScopeOrHash','quality'); } const hit = qualityHit(rule,space.id,QUALITY_RUN); hit.vectorDistance = candidate.distance; hits.push(hit); }
        if (hits.length !== 8) { throw new KnowledgeFailure('QualityEightCandidateCoverage','quality'); } const evaluation = qualityEvaluate(prepared.manifest.questions[at-8],prepared.manifest.rules,hits); await store.executeSql('INSERT INTO quality_result VALUES(?,?)',[evaluation.id,JSON.stringify(evaluation)]); results.push(evaluation); qualityLogCase(evaluation);
      }
      response.vector.fill(0); activeId = '';
      if (at === 7) { await vectors.close(); await vectors.open(); for (const target of targets) { const read = await vectors.read(space.id,target.chunkIds[0],QUALITY_RUN); if (read === undefined || await identity.hash(vectorReadbackProjection(read)) !== target.readbackHash) { throw new KnowledgeFailure('QualityEightReopenReadback','quality'); } } }
    }
    await store.executeSql('UPDATE quality_run SET state=? WHERE id=?',['Complete',QUALITY_RUN]); const status = qualityLogMetrics(results); hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_QUALITY_DONE run=${QUALITY_RUN} docs=8 queries=16 attempts=${starts} elapsed=${Date.now()-started} set=${prepared.setHash}`); return status;
  } catch (error) {
    const native: BusinessError = error; const category: string = error instanceof KnowledgeFailure ? error.category.replace(new RegExp('[^A-Za-z0-9]','g'),'') : 'PlatformError';
    if (store !== undefined && claimed) { if (activeId.length > 0) { await store.executeSql('UPDATE quality_input SET state=? WHERE id=? AND state=?',['UnknownOrFailed',activeId,'InFlight']); } await store.executeSql('UPDATE quality_run SET state=? WHERE id=?',['FailedNoRetry',QUALITY_RUN]); }
    hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_QUALITY_ERROR id=${activeId || 'None'} category=${category} sdk=${typeof native.code === 'number' ? native.code : 0} attempts=${starts}`); return 'QualityStoppedNoRetry';
  } finally { SemanticQualitySession.transport?.cancel(); SemanticQualitySession.transport = undefined; await vectors.close(); await pdf.close(); await text.close(); await assembly.release(); }
}

export async function semanticQualityReadback(context: common.Context): Promise<string> {
  const scope = qualityScope(); const host = KnowledgeStoreHost.forContext(context,scope); const text = new TextRdbRepository(context,host); const vectors = new VectorRdbRepository(context,scope); const identity = new KnowledgePlatformIdentity(); const results: QualityCaseResult[] = [];
  try {
    await text.open(); const store = host.requireStore(); const run = await store.querySql('SELECT wire,state,set_hash,config FROM quality_run WHERE id=?',[QUALITY_RUN]); let space = new EmbeddingSpace(); let setHash: string = ''; let fingerprint: string = '';
    try { if (!run.goToNextRow() || run.getString(1) !== 'Complete') { throw new KnowledgeFailure('QualityNotComplete','quality'); } space = embeddingSpaceDecode(run.getString(0)); setHash = run.getString(2); fingerprint = run.getString(3); } finally { run.close(); }
    const config = new EmbeddingConfig(); config.modelId = 'BAAI/bge-m3'; const prepared = await qualityPrepare(context,config); await vectors.open(); const targets: VectorEligibility[] = []; let verified: number = 0;
    if (space.configFingerprint !== fingerprint || space.dimension !== 1024 || space.requestedModel !== config.modelId || space.returnedModel !== config.modelId || await identity.hash(pdfCodecUtf8(JSON.stringify([QUALITY_RULES_HASH,QUALITY_GOLD_HASH,fingerprint,prepared.hashes,prepared.proofs.map((proof: TokenEligibilityEvidence): string => proof.bindingHash)]))) !== setHash) { throw new KnowledgeFailure('QualityReopenFrozenSetMismatch','quality'); }
    const ids = prepared.manifest.rules.map((rule: QualityRule): string => rule.id).concat(prepared.manifest.questions.map((q: QualityQuestion): string => q.id)); const texts = prepared.manifest.rules.map((rule: QualityRule): string => rule.text).concat(prepared.manifest.questions.map((q: QualityQuestion): string => q.text));
    const inputs = await store.querySql('SELECT id,hash,readback,state,role,binding,bound,text FROM quality_input ORDER BY id');
    try { while (inputs.goToNextRow()) { const id = inputs.getString(0); const at: number = ids.indexOf(id); const document: boolean = at >= 0 && at < 8; const row = await vectors.read(space.id,id,QUALITY_RUN); if (at < 0 || row === undefined || inputs.getString(3) !== 'ReadbackVerified' || row.values.length !== 1024 || row.inputHash !== inputs.getString(1) || row.inputHash !== prepared.hashes[at] || row.documentId !== (document ? id : 'QualityQueryOnly') || row.eligible !== document || row.epoch !== 0 || row.contentGeneration !== QUALITY_RUN || inputs.getString(4) !== (document ? 'document' : 'query') || inputs.getString(5) !== prepared.proofs[at].bindingHash || inputs.getLong(6) !== prepared.proofs[at].upperBound || inputs.getString(7) !== texts[at] || await identity.hash(vectorReadbackProjection(row)) !== inputs.getString(2)) { throw new KnowledgeFailure('QualityReopenReadbackMismatch','quality'); } verified++; if (document) { const target = new VectorEligibility(); target.chunkIds = [id]; target.documentId = id; target.spaceId = space.id; target.contentGeneration = QUALITY_RUN; target.vectorGeneration = QUALITY_RUN; target.inputHash = row.inputHash; target.readbackHash = inputs.getString(2); targets.push(target); } } } finally { inputs.close(); }
    if (verified !== 24 || targets.length !== 8) { throw new KnowledgeFailure('QualityReopenCoverage','quality'); }
    for (const question of prepared.manifest.questions) { const query = await vectors.read(space.id,question.id,QUALITY_RUN); if (query === undefined || query.eligible) { throw new KnowledgeFailure('QualityQueryIsolation','quality'); } const candidates = await vectors.filteredKnn(space,query.values,targets,new KnowledgeCancellation()); const hits: KnowledgeHit[] = [];
      for (const candidate of candidates) { const rule = prepared.manifest.rules.find((rule: QualityRule): boolean => rule.id === candidate.row.chunkId); const target = targets.find((target: VectorEligibility): boolean => target.chunkIds[0] === candidate.row.chunkId); if (rule === undefined || target === undefined || await identity.hash(vectorReadbackProjection(candidate.row)) !== target.readbackHash) { throw new KnowledgeFailure('QualityReopenCandidate','quality'); } const hit = qualityHit(rule,space.id,QUALITY_RUN); hit.vectorDistance = candidate.distance; hits.push(hit); }
      const evaluation = qualityEvaluate(question,prepared.manifest.rules,hits); const saved = await store.querySql('SELECT wire FROM quality_result WHERE id=?',[question.id]); try { if (!saved.goToNextRow() || saved.getString(0) !== JSON.stringify(evaluation)) { throw new KnowledgeFailure('QualityReopenResultMismatch','quality'); } } finally { saved.close(); } results.push(evaluation); qualityLogCase(evaluation);
    }
    const usage = await new KnowledgeDerivedBudget(context,scope).usage();
    hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_QUALITY_STORAGE ordinary=${usage.sharedNonReclaimable} vectors=${usage.vectorPhysical} derived=${usage.assetsPhysical} total=${usage.total()} production=0`);
    hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_QUALITY_REOPEN vectors=${verified} results=${results.length} candidates=8 requests=0`); return qualityLogMetrics(results);
  } finally { await vectors.close(); await text.close(); }
}
