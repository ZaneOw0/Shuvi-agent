import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
export class KnowledgeOperationSession {
  private epoch: number = 0; private stopped: boolean = false; private tokens: KnowledgeCancellation[] = [];
  private clock: () => number;
  constructor(clock: () => number = (): number => Date.now()) { this.clock = clock; }
  begin(): KnowledgeCancellation {
    if (this.stopped) { throw new KnowledgeFailure('SourceSessionClosed','source'); }
    const token = new KnowledgeCancellation(); token.epoch = ++this.epoch; token.now = this.clock; token.deadline = this.clock()+120000; this.tokens.push(token); return token;
  }
  current(token: KnowledgeCancellation): void { token.check(); if (this.stopped || token.epoch !== this.epoch) { throw new KnowledgeFailure('SourceOperationStale','source'); } }
  end(token: KnowledgeCancellation): void { this.tokens = this.tokens.filter((item: KnowledgeCancellation): boolean => item !== token); }
  stop(): void { this.stopped = true; this.epoch++; for (const token of this.tokens) { token.invalid = true; } }
}
