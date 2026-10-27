import {
  ParsedCancellation, ParsedDocument, ParsedDocumentRecord, ParsedFailure, ParsedFormat, ParsedLimits, ParsedTextChunk, parsedId
} from '../domain/ParsedDocumentModels';
import { ParsedAssetPort, ParsedIdentityPort, ParsedImportRequest, ParsedRepositoryPort } from '../domain/ParsedDocumentPorts';
import {
  KnowledgeDatabaseChunk, KnowledgeDatabaseDocument, KnowledgeDatabaseListRequest, KnowledgeDatabasePort,
  KnowledgeDatabaseReadRequest, KnowledgeDatabaseSummary, KnowledgeDatabaseWriteRequest
} from '../domain/KnowledgeDatabasePorts';
import { parsedUtf8 } from '../pipeline/ParsedDocumentCodec';
import { ParsedDocumentAdapters } from '../infra/ParsedDocumentAdapters';
import { ParsedDocumentIngestionService } from './ParsedDocumentIngestionService';

export const BACKEND_KNOWLEDGE_NAMESPACE: string = 'Backend';
const BACKEND_PARSER_SIGNATURE: string = 'SHUVI-BACKEND-MARKDOWN-1';
const BACKEND_ENGINE: string = 'ShuviBackend';
const BACKEND_SOURCE_ID_BYTES: number = 4096;
const BACKEND_LIST_LIMIT: number = 100;

function databaseChunk(source: ParsedTextChunk): KnowledgeDatabaseChunk {
  const chunk: KnowledgeDatabaseChunk = new KnowledgeDatabaseChunk();
  chunk.id = source.id; chunk.ordinal = source.ordinal; chunk.text = source.text; chunk.inputHash = source.inputHash;
  chunk.blockId = source.blockId; chunk.occurrenceId = source.occurrenceId; chunk.evidence = source.evidence;
  chunk.start = source.start; chunk.end = source.end; return chunk;
}

function databaseSummary(record: ParsedDocumentRecord): KnowledgeDatabaseSummary {
  const summary: KnowledgeDatabaseSummary = new KnowledgeDatabaseSummary();
  summary.documentId = record.id; summary.namespace = record.namespace; summary.sourceId = record.legacyId;
  summary.title = record.title; summary.sourceHash = record.sourceHash; summary.generation = record.activeGeneration;
  summary.archived = record.archived; return summary;
}

export class KnowledgeDatabaseAdapter implements KnowledgeDatabasePort {
  private repository: ParsedRepositoryPort;
  private assets: ParsedAssetPort;
  private ingestion: ParsedDocumentIngestionService;
  private identity: ParsedIdentityPort;

  constructor(repository: ParsedRepositoryPort, assets: ParsedAssetPort, ingestion: ParsedDocumentIngestionService, identity: ParsedIdentityPort) {
    this.repository = repository; this.assets = assets; this.ingestion = ingestion; this.identity = identity;
  }

  private validateWrite(request: KnowledgeDatabaseWriteRequest): Uint8Array {
    const sourceBytes: Uint8Array = parsedUtf8(request.sourceId);
    const markdownBytes: Uint8Array = parsedUtf8(request.markdown);
    if (request.sourceId.trim() !== request.sourceId || sourceBytes.length < 1 || sourceBytes.length > BACKEND_SOURCE_ID_BYTES) {
      throw new ParsedFailure('BackendSourceIdentity','database-write');
    }
    if (request.title.trim().length < 1 || request.title.length > 256) { throw new ParsedFailure('BackendTitle','database-write'); }
    if (!Number.isSafeInteger(request.sourceVersion) || request.sourceVersion < 1) { throw new ParsedFailure('BackendSourceVersion','database-write'); }
    if (request.markdown.trim().length < 1 || markdownBytes.length > ParsedLimits.payloadBytes) { throw new ParsedFailure('BackendMarkdownBudget','database-write'); }
    return markdownBytes;
  }

  private async documentId(sourceId: string): Promise<string> {
    return 'upd-'+(await this.identity.hash(parsedUtf8(`${BACKEND_KNOWLEDGE_NAMESPACE}\n${sourceId}`))).slice(0,32);
  }

  private async readRecord(record: ParsedDocumentRecord, includeArchived: boolean): Promise<KnowledgeDatabaseDocument | undefined> {
    if (record.tombstone || record.activeGeneration.length === 0 || record.archived && !includeArchived) { return undefined; }
    const generation: string = record.activeGeneration;
    const sourceHash: string = record.sourceHash;
    const cancel: ParsedCancellation = new ParsedCancellation();
    const document: ParsedDocument = await this.assets.readSnapshot(`${generation}-manifest`,cancel);
    const chunks: ParsedTextChunk[] = await this.repository.chunks(record.id); cancel.check();
    const current: ParsedDocumentRecord | undefined = await this.repository.get(record.id); cancel.check();
    if (current === undefined || current.tombstone || current.activeGeneration.length === 0 || current.archived && !includeArchived) { return undefined; }
    if (current.activeGeneration !== generation || current.sourceHash !== sourceHash || current.namespace !== record.namespace ||
      current.legacyId !== record.legacyId || document.documentKey !== record.id || document.generation !== generation ||
      document.source_hash !== sourceHash || chunks.some((chunk: ParsedTextChunk): boolean =>
        chunk.documentKey !== record.id || chunk.generation !== generation)) {
      throw new ParsedFailure('BackendReadbackMismatch','database-read');
    }
    const result: KnowledgeDatabaseDocument = new KnowledgeDatabaseDocument(); result.summary = databaseSummary(current);
    result.sourceVersion = document.sourceVersion; result.markdown = document.markdown;
    result.chunks = chunks.map((chunk: ParsedTextChunk): KnowledgeDatabaseChunk => databaseChunk(chunk)); return result;
  }

  async write(request: KnowledgeDatabaseWriteRequest): Promise<KnowledgeDatabaseDocument> {
    const markdownBytes: Uint8Array = this.validateWrite(request); await this.repository.open();
    const sourceHash: string = await this.identity.hash(markdownBytes); const documentId: string = await this.documentId(request.sourceId);
    const existing: ParsedDocumentRecord | undefined = await this.repository.get(documentId);
    if (existing !== undefined && existing.archived) { throw new ParsedFailure('BackendDocumentArchived','database-write'); }
    if (existing !== undefined && existing.namespace !== BACKEND_KNOWLEDGE_NAMESPACE) { throw new ParsedFailure('BackendDocumentNamespace','database-write'); }
    if (existing !== undefined && existing.title !== request.title) { throw new ParsedFailure('BackendSourceMetadataChanged','database-write'); }
    const parsed: ParsedImportRequest = new ParsedImportRequest(); parsed.namespace = BACKEND_KNOWLEDGE_NAMESPACE;
    parsed.sourceId = request.sourceId; parsed.sourceHash = sourceHash; parsed.sourceVersion = request.sourceVersion;
    parsed.title = request.title; parsed.format = ParsedFormat.Text; parsed.parserSignature = BACKEND_PARSER_SIGNATURE;
    parsed.engine = BACKEND_ENGINE; parsed.outputIdentity = sourceHash;
    const producer: ParsedDocumentAdapters = new ParsedDocumentAdapters(this.identity); producer.setOutput(request.markdown,undefined,sourceHash);
    await this.ingestion.ingest(parsed,producer);
    const record: ParsedDocumentRecord | undefined = await this.repository.get(documentId);
    if (record === undefined) { throw new ParsedFailure('BackendPublicationMissing','database-write'); }
    if (record.archived || record.tombstone) { throw new ParsedFailure('BackendDocumentArchived','database-write'); }
    // Re-read with archived excluded: a concurrent archive must not become a successful write result.
    const result: KnowledgeDatabaseDocument | undefined = await this.readRecord(record,false);
    if (result === undefined) { throw new ParsedFailure('BackendPublicationUnavailable','database-write'); } return result;
  }

  async read(request: KnowledgeDatabaseReadRequest): Promise<KnowledgeDatabaseDocument | undefined> {
    if (!parsedId(request.documentId)) { throw new ParsedFailure('BackendDocumentIdentity','database-read'); }
    await this.repository.open(); const record: ParsedDocumentRecord | undefined = await this.repository.get(request.documentId);
    return record === undefined ? undefined : this.readRecord(record,request.includeArchived);
  }

  async list(request: KnowledgeDatabaseListRequest): Promise<KnowledgeDatabaseSummary[]> {
    if (!Number.isSafeInteger(request.offset) || request.offset < 0 || !Number.isSafeInteger(request.limit) || request.limit < 1 || request.limit > BACKEND_LIST_LIMIT) {
      throw new ParsedFailure('BackendListRange','database-list');
    }
    await this.repository.open(); const records: ParsedDocumentRecord[] = await this.repository.list();
    return records.filter((record: ParsedDocumentRecord): boolean => !record.tombstone && record.activeGeneration.length > 0 && (request.includeArchived || !record.archived))
      .slice(request.offset,request.offset+request.limit).map((record: ParsedDocumentRecord): KnowledgeDatabaseSummary => databaseSummary(record));
  }
}
