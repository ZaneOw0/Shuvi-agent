import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { EmbeddingTokenAdapter } from '../infra/EmbeddingTokenAdapter';
import { KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { KnowledgeReadLease } from '../domain/PdfKnowledgeModels';
import { EmbeddingConfig, EmbeddingGrant, EmbeddingPurpose, EmbeddingFreeEligibility, TokenEligibilityEvidence } from '../domain/EmbeddingModels';
import { EmbeddingBaselineAcceptance, EmbeddingPinnedBasis } from '../domain/EmbeddingBasisModels';
import { embeddingAuthorize, embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { embeddingLocalEligible } from '../pipeline/EmbeddingBasisPolicy';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { PdfNativeCaseResult, PdfNativeSuiteResult } from './PdfNativeSuite';
import { KnowledgeStoreHost } from '../infra/KnowledgeStoreHost';
import { TextRdbRepository } from '../infra/TextRdbRepository';
import { PdfKnowledgeRepository } from '../infra/PdfKnowledgeRepository';
import { PdfVectorRepository } from '../infra/PdfVectorRepository';
import { KnowledgePhysicalBudgetPort, KnowledgeDerivedUsage } from '../infra/KnowledgeDerivedBudget';
import { embeddingSmallScopeCase } from './EmbeddingSmallScopeCase';
class BasisBudgetFixture implements KnowledgePhysicalBudgetPort { bytes: number = 0; async usage(): Promise<KnowledgeDerivedUsage> { const usage: KnowledgeDerivedUsage = new KnowledgeDerivedUsage(); usage.vectorPhysical = this.bytes; return usage; } }

function basisAssert(condition: boolean, reason: string): void { if (!condition) { throw new KnowledgeFailure(reason,'basis-suite'); } }
export async function embeddingRunBasisSuite(context: common.Context, scope: KnowledgeStorageScope): Promise<PdfNativeSuiteResult> {
  scope.requireTestOwner(scope.key); const result: PdfNativeSuiteResult = new PdfNativeSuiteResult(); result.version = 'R2-BASIS-1'; result.run = scope.key;
  const identity = new KnowledgePlatformIdentity(); const counter = new EmbeddingTokenAdapter(context,identity);
  const names: string[] = ['ascii','english','chinese','emoji','formula','compat-expansion','combining','whitespace','deletion','special-only','mask-lstrip','normalized-special','segment-prefixes','json-not-body','prefix-included','supplementary-expansion','pdf512','pdf512-expansion','bound8192','bound8193','special8192','unseen'];
  const texts: string[] = ['abc','What is BGE M3?','这是一条用于检测嵌入服务的非敏感短句。','😀👩‍💻🇨🇳','E=mc^2; ∫_0^1 x² dx = 1/3','ﬃ㍿ﷺ','é Å क्ष',' \t\n\r 　 a  b ','\u0000\u0001\u001f\u200b\ufeff','<s></s><unk><pad><mask>','a \t <mask>b','＜ｍａｓｋ＞','a<s>b</s>c<mask>d','a\n"b\\c','query: What is BGE M3?','𝅘𝅥𝅮🄐🈀','中'.repeat(512),'ﷺ'.repeat(512),'中'.repeat(8189),'中'.repeat(8190),'<s>'.repeat(8190),'\udbff\udfff\ue000\u0378'];
  const bounds: number[] = [6,18,22,9,28,28,12,15,8,7,10,9,13,9,25,11,515,9219,8192,8193,8192,6];
  for (let at: number = 0; at < texts.length; at++) {
    const row: PdfNativeCaseResult = new PdfNativeCaseResult(); row.id = names[at];
    try { const proof = await counter.evidence(EmbeddingPinnedBasis.model,'document',texts[at],await identity.hash(pdfCodecUtf8(texts[at]))); basisAssert(proof.upperBound === bounds[at] && proof.localState === (bounds[at] <= 8192 ? 'SafeUnderPinnedProfile' : 'BoundUnproven') && !proof.verified && proof.profileBoundProven && proof.providerConsistency === 'UnverifiedRevisionAndHiddenProcessing','GoldenOrKitHashMismatch'); row.passed = true; row.reason = 'ok'; row.output = proof.upperBound; }
    catch (error) { const native: BusinessError = error; row.reason = error instanceof KnowledgeFailure ? error.category : 'CounterOrPlatformFailed'; row.code = typeof native.code === 'number' ? native.code : 0; }
    result.cases.push(row);
  }
  const host = KnowledgeStoreHost.forContext(context,scope); const text = new TextRdbRepository(context,host); const pdf = new PdfKnowledgeRepository(host); const repository = new PdfVectorRepository(host,pdf);
  try {
    await text.open(); await pdf.open(); await repository.bootstrap();
    for (const name of ['baseline-not-egress','baseline-revision-reopen','wrong-model','invalid-unicode','hash-mismatch','unknown-free','budget-exact-boundary','release-receipt-crud','close-acquire','close-failure-retry','small-scope-contract-pause']) {
      const row: PdfNativeCaseResult = new PdfNativeCaseResult(); row.id = name;
      try {
        const config: EmbeddingConfig = new EmbeddingConfig(); config.modelId = EmbeddingPinnedBasis.model;
        const proof = await counter.evidence(config.modelId,'query','fixture',await identity.hash(pdfCodecUtf8('fixture')));
        const basis: EmbeddingBaselineAcceptance = new EmbeddingBaselineAcceptance(); basis.state = 'AcceptedEngineeringBaseline'; basis.configFingerprint = embeddingFingerprint(config); basis.configRevision = config.revision; basis.acceptedAt = Date.now(); proof.baseline = basis;
        if (name === 'baseline-not-egress' || name === 'unknown-free') { basisAssert(embeddingLocalEligible(proof,config),'LocalEligibilityRejected'); const grant: EmbeddingGrant = new EmbeddingGrant(); grant.purpose = EmbeddingPurpose.Query; grant.configFingerprint = embeddingFingerprint(config); grant.issuedAt = Date.now(); grant.expiresAt = Date.now()+10000; grant.spaceId = 'fixture'; grant.sessionId = scope.key; grant.inputHashes = [proof.textHash]; grant.inputEvidence = [proof]; let rejected: boolean = false; try { embeddingAuthorize(config,grant,EmbeddingPurpose.Query); } catch { rejected = true; } basisAssert(rejected,'BaselineGrantedFreeOrEgress'); }
        else if (name === 'baseline-revision-reopen') { await repository.saveBaseline(basis); const other = new PdfVectorRepository(host,pdf); basisAssert((await other.baseline(config)).state === 'AcceptedEngineeringBaseline','BaselineNotDurable'); config.revision++; basisAssert((await other.baseline(config)).state === 'NotAccepted' && !embeddingLocalEligible(proof,config),'RevisionReusedBasis'); }
        else if (name === 'wrong-model') { const wrong = await counter.evidence('Pro/BAAI/bge-m3','query','fixture',proof.textHash); basisAssert(wrong.localState === 'UnsupportedProfile' && !wrong.verified,'OtherModelAccepted'); }
        else if (name === 'invalid-unicode') { const invalid = await counter.evidence(config.modelId,'query','\ud800',''); basisAssert(invalid.localState === 'InvalidInput' && !invalid.profileBoundProven,'InvalidUnicodeAccepted'); }
        else if (name === 'hash-mismatch') { let rejected: boolean = false; try { await counter.evidence(config.modelId,'query','fixture','0'.repeat(64)); } catch { rejected = true; } basisAssert(rejected,'WrongHashAccepted'); }
        else if (name === 'budget-exact-boundary') { const physical = new BasisBudgetFixture(); physical.bytes = 4096; repository.attachPhysical(physical); const used: number = physical.bytes+await repository.metadataBytes(); repository.testBudgetLimit(scope.key,used+100); await repository.reserve('test-exact',100); let rejected: boolean = false; try { await repository.reserve('test-over',1); } catch { rejected = true; } basisAssert(rejected,'BudgetOneByteOverAccepted'); await repository.releaseReservation('test-exact'); repository.testBudgetLimit(scope.key,524288000); }
        else if (name === 'release-receipt-crud') { const lease: KnowledgeReadLease = new KnowledgeReadLease(); lease.id = identity.id(); lease.sessionId = scope.key; lease.generation = 'fixture'; await repository.releaseFailure(lease,'InjectedRelease'); basisAssert((await repository.pendingReleases(scope.key)).length === 1,'ReleaseReceiptWriteRead'); await repository.releaseFailure(lease,''); basisAssert((await repository.pendingReleases(scope.key)).length === 0,'ReleaseReceiptDelete'); }
        else if (name === 'close-acquire') { await pdf.close(); const closing = text.close(); const next = new TextRdbRepository(context,host); await Promise.all<void>([closing,next.open()]); basisAssert(host.m1Ready && (await next.list()).length === 0,'CloseAcquireRace'); await text.open(); await next.close(); await pdf.open(); }
        else if (name === 'close-failure-retry') { await pdf.close(); host.injectCloseFault(scope.key); let rejected: boolean = false; try { await text.close(); } catch { rejected = true; } basisAssert(rejected && host.m1Ready,'CloseFailureHidden'); await text.close(); await text.open(); await pdf.open(); }
        else if (name === 'small-scope-contract-pause') { await pdf.reconcile(scope.key); await embeddingSmallScopeCase(context,host,pdf,scope); }
        row.passed = true; row.reason = 'ok';
      } catch (error) { const native: BusinessError = error; row.reason = error instanceof KnowledgeFailure ? error.category : 'CounterOrPlatformFailed'; row.code = typeof native.code === 'number' ? native.code : 0; } result.cases.push(row);
    }
  } finally { await pdf.close(); await text.close(); if (result.cases.every((row: PdfNativeCaseResult): boolean => row.passed)) { const config: relationalStore.StoreConfig = { name: scope.databaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: false }; const vector: relationalStore.StoreConfig = { name: scope.vectorDatabaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: true }; await relationalStore.deleteRdbStore(context,config); await relationalStore.deleteRdbStore(context,vector); } }
  return result;
}
