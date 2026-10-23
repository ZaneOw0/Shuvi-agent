import { PdfPageAdapter } from './PdfPageAdapter';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
export class PdfSourceSession {
  private owned: PdfPageAdapter[] = []; private pending: Promise<void>[] = [];
  state: string = 'Idle';
  adopt(adapter: PdfPageAdapter): void { if (this.owned.some((item: PdfPageAdapter): boolean => item.releaseState === 'ReleaseUnconfirmed')) { throw new KnowledgeFailure('PreviousSourceReleaseUnconfirmed','source'); } this.owned.push(adapter); }
  release(adapter: PdfPageAdapter): Promise<void> {
    this.state = 'Releasing'; const operation = adapter.close().then((): void => { this.owned = this.owned.filter((item: PdfPageAdapter): boolean => item !== adapter); this.state = this.owned.length === 0 ? 'Released' : 'Reading'; },(): void => { this.state = 'ReleaseUnconfirmed'; });
    this.pending.push(operation); operation.then((): void => { this.pending = this.pending.filter((item: Promise<void>): boolean => item !== operation); }); return operation;
  }
  async retry(): Promise<void> { for (const adapter of this.owned.slice()) { await this.release(adapter); } await Promise.all<void>(this.pending); if (this.owned.length > 0) { throw new KnowledgeFailure('SourceReleaseUnconfirmed','source'); } }
  background(): void { for (const adapter of this.owned.slice()) { this.release(adapter); } }
}
