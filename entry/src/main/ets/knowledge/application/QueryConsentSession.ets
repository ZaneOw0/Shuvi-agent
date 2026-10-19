import { EmbeddingConfig, TokenEligibilityEvidence, QueryConsentSnapshot } from '../domain/EmbeddingModels';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { embeddingLocalEligible } from '../pipeline/EmbeddingBasisPolicy';
import { prepareTextQuery } from '../pipeline/QueryPreparation';
export class QueryConsentSession {
  epoch: number = 0; private reviewed: QueryConsentSnapshot | undefined;
  invalidate(): void { this.epoch++; this.reviewed = undefined; }
  review(text: string, proof: TokenEligibilityEvidence, config: EmbeddingConfig, purpose: string, space: string, trial: string = '', scopeHash: string = ''): void {
    if (prepareTextQuery(text).actualInput !== text || !embeddingLocalEligible(proof,config) || proof.role !== 'query' || proof.textHash.length !== 64 || space.length === 0 || !['query','trial'].includes(purpose) || scopeHash.length !== 64 || purpose === 'trial' && trial.length === 0 || purpose === 'query' && trial.length !== 0) { throw new KnowledgeFailure('QueryReviewBindingRequired','consent'); }
    const snap = new QueryConsentSnapshot(); snap.actual = text; snap.inputHash = proof.textHash; snap.bindingHash = proof.bindingHash; snap.config = embeddingFingerprint(config); snap.purpose = purpose; snap.space = space; snap.trial = trial; snap.scopeHash = scopeHash; snap.epoch = this.epoch; this.reviewed = snap;
  }
  approve(checked: boolean): void { if (this.reviewed !== undefined) { this.reviewed.approved = checked; } }
  confirmFree(checked: boolean): void { if (this.reviewed !== undefined) { this.reviewed.free = checked; } }
  consume(text: string, proof: TokenEligibilityEvidence, config: EmbeddingConfig, purpose: string, space: string, trial: string = '', scopeHash: string = ''): QueryConsentSnapshot {
    const snap = this.reviewed; this.invalidate();
    if (snap === undefined || !snap.approved || !snap.free || snap.epoch !== this.epoch-1 || snap.actual !== prepareTextQuery(text).actualInput || snap.actual !== text || snap.inputHash !== proof.textHash || snap.bindingHash !== proof.bindingHash || proof.role !== snap.role || !embeddingLocalEligible(proof,config) || snap.config !== embeddingFingerprint(config) || snap.purpose !== purpose || snap.space !== space || snap.trial !== trial || snap.scopeHash !== scopeHash) { throw new KnowledgeFailure('NoRequestStaleQueryConsent','consent'); }
    return snap;
  }
}
