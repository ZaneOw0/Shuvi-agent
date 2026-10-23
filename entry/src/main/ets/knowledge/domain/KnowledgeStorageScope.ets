import { KnowledgeFailure } from './PdfKnowledgeModels';

export class KnowledgeStorageScope {
  readonly key: string;
  readonly databaseName: string;
  readonly vectorDatabaseName: string;
  readonly derivedDirectory: string;
  readonly testing: boolean;
  private constructor(key: string, testing: boolean) {
    this.key = key; this.testing = testing;
    this.databaseName = testing ? `shuvi_r2_${key}.db` : 'shuvi_kb_user_v1.db';
    this.vectorDatabaseName = testing ? `shuvi_r2_vector_${key}.db` : 'shuvi_kb_vector_v1.db';
    this.derivedDirectory = testing ? `knowledge_r2_${key}` : 'knowledge_pdf_v1';
  }
  static production(): KnowledgeStorageScope { return new KnowledgeStorageScope('production',false); }
  static isolated(run: string): KnowledgeStorageScope {
    if (!new RegExp('^[a-f0-9]{16}$').test(run)) { throw new KnowledgeFailure('TestScopeRejected','scope'); }
    return new KnowledgeStorageScope(run,true);
  }
  requireTestOwner(owner: string): void {
    if (!this.testing || owner !== this.key) { throw new KnowledgeFailure('TestOwnershipRejected','scope'); }
  }
}
