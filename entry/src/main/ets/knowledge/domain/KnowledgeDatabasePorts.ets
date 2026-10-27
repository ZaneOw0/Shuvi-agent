export class KnowledgeDatabaseWriteRequest {
  sourceId: string = '';
  sourceVersion: number = 1;
  title: string = '';
  markdown: string = '';
}

export class KnowledgeDatabaseReadRequest {
  documentId: string = '';
  includeArchived: boolean = false;
}

export class KnowledgeDatabaseListRequest {
  offset: number = 0;
  limit: number = 50;
  includeArchived: boolean = false;
}

export class KnowledgeDatabaseChunk {
  id: string = '';
  ordinal: number = 0;
  text: string = '';
  inputHash: string = '';
  blockId: string = '';
  occurrenceId: string = '';
  evidence: string = '';
  start: number = 0;
  end: number = 0;
}

export class KnowledgeDatabaseSummary {
  documentId: string = '';
  namespace: string = '';
  sourceId: string = '';
  title: string = '';
  sourceHash: string = '';
  generation: string = '';
  archived: boolean = false;
}

export class KnowledgeDatabaseDocument {
  summary: KnowledgeDatabaseSummary = new KnowledgeDatabaseSummary();
  sourceVersion: number = 1;
  markdown: string = '';
  chunks: KnowledgeDatabaseChunk[] = [];
}

export interface KnowledgeDatabasePort {
  write(request: KnowledgeDatabaseWriteRequest): Promise<KnowledgeDatabaseDocument>;
  read(request: KnowledgeDatabaseReadRequest): Promise<KnowledgeDatabaseDocument | undefined>;
  list(request: KnowledgeDatabaseListRequest): Promise<KnowledgeDatabaseSummary[]>;
}
