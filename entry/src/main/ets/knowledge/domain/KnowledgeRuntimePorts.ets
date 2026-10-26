import { ParsedCancellation } from './ParsedDocumentModels';

export class KnowledgeRuntimeSearchRequest {
  query: string = '';
  maxResults: number = 5;
}

export class KnowledgeRuntimeCitation {
  citationId: number = 0;
  evidenceId: string = '';
  documentId: string = '';
  generation: string = '';
  title: string = '';
  excerpt: string = '';
  kind: string = 'Text';
  evidence: string = 'BodyDirect';
}

export class KnowledgeRuntimeSearchResult {
  schemaVersion: string = '1.0';
  provider: string = 'shuvi-local-knowledge';
  query: string = '';
  route: string = 'local-direct';
  citations: KnowledgeRuntimeCitation[] = [];
}

export class KnowledgeRagReadiness {
  ready: boolean = false;
  code: string = 'NotChecked';
  message: string = '知识库 RAG 尚未检查。';
}

export interface KnowledgeRuntimeSearchPort {
  search(request: KnowledgeRuntimeSearchRequest, cancel: ParsedCancellation): Promise<KnowledgeRuntimeSearchResult>;
}

export interface KnowledgeRagSearchPort extends KnowledgeRuntimeSearchPort {
  open(): Promise<void>;
  readiness(): Promise<KnowledgeRagReadiness>;
  close(): Promise<void>;
}
