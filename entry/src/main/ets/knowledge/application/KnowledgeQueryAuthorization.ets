import { ParsedCancellation } from '../domain/ParsedDocumentModels';
class QueryPermission {
  session: string = ''; epoch: number = 0; revision: number = 0; cancel: ParsedCancellation = new ParsedCancellation();
}
/** Live query-only permits. Persisted approvals cannot revive this authority after a restart. */
export class KnowledgeQueryAuthorization {
  private readonly permits: Map<string, QueryPermission> = new Map<string, QueryPermission>();
  allow(session: string, epoch: number, revision: number, cancel: ParsedCancellation): void {
    cancel.check(); if (!session || revision < 1) { throw new Error('QUERY_CONSENT_REQUIRED'); }
    const p: QueryPermission = new QueryPermission(); p.session = session; p.epoch = epoch; p.revision = revision; p.cancel = cancel;
    this.permits.set(session, p);
  }
  revision(session: string, epoch: number): number {
    const p: QueryPermission | undefined = this.permits.get(session);
    if (p === undefined || p.epoch !== epoch) { return 0; }
    try { p.cancel.check(); return p.revision; } catch { return 0; }
  }
  revoke(session: string, epoch: number): void {
    const p: QueryPermission | undefined = this.permits.get(session);
    if (p !== undefined && p.epoch <= epoch) { this.permits.delete(session); }
  }
}
