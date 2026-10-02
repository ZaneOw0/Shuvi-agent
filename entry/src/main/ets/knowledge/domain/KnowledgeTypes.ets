export enum KnowledgeDocStatus {
  Imported = 'IMPORTED',
  Indexing = 'INDEXING',
  Indexed = 'INDEXED',
  Failed = 'FAILED'
}

export enum RecallChannel {
  Inverted = 'INVERTED',
  Vector = 'VECTOR',
  Fused = 'FUSED',
  SqlLike = 'SQL_LIKE'
}

export interface KnowledgeDocumentRef {
  title: string;
  text: string;
}

export interface ChunkSlice {
  text: string;
  charOffset: number;
}

export interface IndexOutcome {
  documentId: string;
  title: string;
  chunkCount: number;
  vectorCount: number;
}

export interface KnowledgeHit {
  chunkId: string;
  documentId: string;
  documentTitle: string;
  text: string;
  channel: RecallChannel;
  rrfScore: number;
  distance: number;
}

export interface KnowledgeCounts {
  documents: number;
  chunks: number;
  invertedRows: number;
  vectorRows: number;
  orphans: number;
  sandboxFiles: number;
}

export interface DeleteOutcome {
  documents: number;
  chunks: number;
  invertedRows: number;
  invertedDirective: string;
}

export interface ProbeStep {
  name: string;
  ok: boolean;
  detail: string;
}

export interface CapabilityReport {
  steps: ProbeStep[];
  searchPath: string;
  vectorStoreSupported: boolean;
}

export interface ChannelRank {
  chunkId: string;
  documentId: string;
  title: string;
  text: string;
  channel: RecallChannel;
  rank: number;
  distance: number;
}
