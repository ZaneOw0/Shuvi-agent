import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { TextCandidatePort, TextDirectCandidatePort } from '../domain/TextKnowledgePorts';
import { knowledgeLiteralScore } from '../pipeline/KnowledgeMatchPolicy';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { KnowledgeLegacyHistoryPort } from '../application/KnowledgeSearchService';
import {
  TextBudget, TextFailure, TextDocument, TextFormat, TextStage, TextJob, TextChunk, TextUsage,
  TextCleanup, TextCancellation, TextQueryInput, TextSearchResult, TextHistory, TextHit, TextChannel, TextReferenceState
} from '../domain/TextKnowledgeModels';
import { encodeRanges, decodeRanges, packTextFields, textNodeKind } from '../pipeline/StructuredChunker';
import { textLikePattern, textFtsInput, textKeywordScore, compareTextHits } from '../pipeline/QueryPreparation';
import { safeTextBoundary } from '../pipeline/Chunker';

export const TEXT_USER_STORE: string = 'shuvi_kb_user_v1.db';
const TEXT_LAYOUT: string = 'text-user-relations-v1';
const TEXT_FTS_DDL: string = 'CREATE VIRTUAL TABLE IF NOT EXISTS text_fts USING fts5(chunk_id UNINDEXED, text, tokenize=customtokenizer)';

function storedStage(raw: string): TextStage {
  const stages: TextStage[] = [TextStage.Saved, TextStage.Normalized, TextStage.Prepared, TextStage.Ready, TextStage.Paused, TextStage.Failed];
  for (const stage of stages) { if (stage === raw) { return stage; } }
  throw new TextFailure('SCHEMA', 'RDB', '未知处理阶段');
}
function storedFormat(raw: string): TextFormat {
  if (raw === TextFormat.Txt) { return TextFormat.Txt; }
  if (raw === TextFormat.Markdown) { return TextFormat.Markdown; }
  throw new TextFailure('SCHEMA', 'RDB', '未知原件格式');
}
function storedChannel(raw: string): TextChannel {
  if (raw === TextChannel.Fts) { return TextChannel.Fts; }
  if (raw === TextChannel.Like) { return TextChannel.Like; }
  throw new TextFailure('SCHEMA', 'history', '未知历史通道');
}
function rowDocument(rows: relationalStore.ResultSet): TextDocument {
  const doc: TextDocument = new TextDocument();
  doc.id = rows.getString(rows.getColumnIndex('id')); doc.title = rows.getString(rows.getColumnIndex('title'));
  doc.format = storedFormat(rows.getString(rows.getColumnIndex('format')));
  doc.original.assetId = rows.getString(rows.getColumnIndex('asset'));
  doc.original.hash = rows.getString(rows.getColumnIndex('hash')); doc.original.bytes = rows.getLong(rows.getColumnIndex('bytes'));
  doc.version = rows.getLong(rows.getColumnIndex('version')); doc.activeGeneration = rows.getString(rows.getColumnIndex('active'));
  doc.archived = rows.getLong(rows.getColumnIndex('archived')) === 1; doc.stage = storedStage(rows.getString(rows.getColumnIndex('stage')));
  doc.failure = rows.getString(rows.getColumnIndex('failure')); doc.chunkCount = rows.getLong(rows.getColumnIndex('chunks'));
  const warnings: string = rows.getString(rows.getColumnIndex('warnings'));
  doc.warnings = warnings.length > 0 ? warnings.split('\t').map((s: string): string => decodeURIComponent(s)) : [];
  doc.createdAt = rows.getLong(rows.getColumnIndex('created')); doc.updatedAt = rows.getLong(rows.getColumnIndex('updated'));
  if (doc.version < 1 || doc.original.bytes < 1 || doc.original.bytes > TextBudget.fileBytes || doc.chunkCount < 0 || doc.chunkCount > TextBudget.activeChunks) {
    throw new TextFailure('SCHEMA', 'RDB', '文档字段超限');
  }
  return doc;
}
export class TextRdbRepository implements TextDirectCandidatePort, KnowledgeLegacyHistoryPort {
  private host: KnowledgeStoreHost;
  private store: relationalStore.RdbStore | undefined = undefined;
  private tail: Promise<void> = Promise.resolve();
  private activeChannel: TextChannel = TextChannel.Unavailable;
  constructor(context: common.Context, host: KnowledgeStoreHost = KnowledgeStoreHost.forContext(context)) { this.host = host; }
  channel(): TextChannel { return this.activeChannel; }
  private requireStore(): relationalStore.RdbStore {
    if (this.store === undefined) { throw new TextFailure('RDB', 'open', '用户知识库尚未打开'); }
    return this.store;
  }
  private write<T>(operation: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.host.enqueue<T>(operation);
    this.tail = result.then((): void => {}, (_error: Error): void => {}); return result;
  }
  private async transaction(operation: (transaction: relationalStore.Transaction) => Promise<void>): Promise<void> {
    const transaction: relationalStore.Transaction = await this.requireStore().createTransaction();
    try { await operation(transaction); await transaction.commit(); }
    catch (error) {
      await transaction.rollback();
      if (error instanceof Error) { throw error; }
      throw new TextFailure('RDB', 'transaction', '数据库事务失败，未提交变更');
    }
  }
  private async scalar(sql: string, args: relationalStore.ValueType[] = []): Promise<number> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql(sql, args);
    try { return rows.goToNextRow() ? rows.getLong(0) : 0; } finally { rows.close(); }
  }
  private async meta(key: string): Promise<string> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT value FROM text_meta WHERE key=?', [key]);
    try { return rows.goToNextRow() ? rows.getString(0) : ''; } finally { rows.close(); }
  }
  async open(): Promise<void> {
    if (this.store !== undefined) { return; }
    try {
      this.store = await this.host.acquireM1(async (store: relationalStore.RdbStore, supported: boolean): Promise<TextChannel> => {
        this.store = store; await this.bootstrap(supported); return this.activeChannel;
      });
      this.activeChannel = this.host.textChannel;
    } catch (error) { this.store = undefined; if (error instanceof Error) { throw error; } throw new TextFailure('RDB', 'open', '用户库打开失败'); }
  }
  private async bootstrap(supported: boolean): Promise<void> {
    const store: relationalStore.RdbStore = this.requireStore();
    const tables: number = await this.scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
    if (tables === 0) {
      await this.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        await transaction.execute('CREATE TABLE text_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        await transaction.execute('CREATE TABLE text_doc (id TEXT PRIMARY KEY,title TEXT,format TEXT,asset TEXT,hash TEXT UNIQUE,bytes INTEGER,version INTEGER,active TEXT,archived INTEGER,stage TEXT,failure TEXT,chunks INTEGER,created INTEGER,updated INTEGER,warnings TEXT)');
        await transaction.execute('CREATE TABLE text_job (id TEXT PRIMARY KEY,doc TEXT,generation TEXT,stage TEXT,checkpoint TEXT,cancel INTEGER,started INTEGER,failure TEXT)');
        await transaction.execute('CREATE TABLE text_generation (id TEXT PRIMARY KEY,doc TEXT,snapshot TEXT,version INTEGER,hash TEXT,complete INTEGER)');
        await transaction.execute('CREATE TABLE text_chunk (id TEXT PRIMARY KEY,doc TEXT,generation TEXT,snapshot TEXT,ordinal INTEGER,kind TEXT,text TEXT,evidence TEXT,prefix TEXT,ranges TEXT,blocks TEXT)');
        await transaction.execute('CREATE INDEX text_chunk_generation ON text_chunk(doc,generation)');
        await transaction.execute('CREATE TABLE text_cleanup (id TEXT PRIMARY KEY,doc TEXT,generation TEXT,assets TEXT,failure TEXT)');
        await transaction.execute('CREATE TABLE text_query (id TEXT PRIMARY KEY,created INTEGER,question TEXT,input TEXT,notice TEXT,channel TEXT)');
        await transaction.execute('CREATE TABLE text_question_part (query_id TEXT,ordinal INTEGER,text TEXT,PRIMARY KEY(query_id,ordinal))');
        await transaction.execute('CREATE TABLE text_citation (query_id TEXT,ordinal INTEGER,doc TEXT,title TEXT,version INTEGER,hash TEXT,generation TEXT,snapshot TEXT,chunk TEXT,text TEXT,retrieval TEXT,kind TEXT,ranges TEXT,channel TEXT,score INTEGER,PRIMARY KEY(query_id,ordinal))');
        await transaction.execute('INSERT INTO text_meta(key,value) VALUES(?,?)', ['layout', TEXT_LAYOUT]);
      });
    } else if (await this.meta('layout') !== TEXT_LAYOUT) {
      throw new TextFailure('SCHEMA', 'open', '用户库版本未知，拒绝清库或覆盖修复');
    }
    const required: string[] = ['text_meta','text_doc','text_job','text_generation','text_chunk','text_cleanup','text_query','text_question_part','text_citation'];
    for (const name of required) {
      if (await this.scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?",[name]) !== 1) { throw new TextFailure('SCHEMA','open','M1 原表缺失，拒绝扩展或清库修复'); }
    }
    const identity: relationalStore.ResultSet = await store.querySql('SELECT d.id,d.hash,d.version,d.active,c.ranges,g.snapshot FROM text_doc d LEFT JOIN text_chunk c ON c.doc=d.id LEFT JOIN text_generation g ON g.id=c.generation LIMIT 0'); identity.close();
    // Verify LIKE independently; an exception is unavailable, not an empty success.
    const like: relationalStore.ResultSet = await store.querySql("SELECT '中文 keyword %_' LIKE ? ESCAPE '\\'", [textLikePattern('%_')]);
    try {
      if (!like.goToNextRow() || like.getLong(0) !== 1) { throw new TextFailure('QUERY', 'LIKE', '字面关键词能力校验失败'); }
    } finally { like.close(); }
    this.activeChannel = TextChannel.Like;
    if (supported) {
      try {
        const existingDdl: relationalStore.ResultSet = await store.querySql("SELECT sql FROM sqlite_master WHERE name='text_fts'");
        try {
          if (existingDdl.goToNextRow() && !(existingDdl.getString(0).includes('chunk_id UNINDEXED, text, tokenize=customtokenizer'))) {
            throw new TextFailure('SCHEMA', 'FTS', '既有 FTS 定义不一致，仅使用普通关系数据');
          }
        } finally { existingDdl.close(); }
        await store.executeSql(TEXT_FTS_DDL);
        await store.executeSql('DELETE FROM text_fts WHERE chunk_id=?', ['capability-sentinel']);
        await this.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
          await transaction.execute('INSERT INTO text_fts(chunk_id,text) VALUES(?,?)', ['capability-sentinel', '知识检索 keyword']);
        });
        const chinese: number = await this.scalar('SELECT count(*) FROM text_fts WHERE text_fts MATCH ? AND chunk_id=?', ['"知识"', 'capability-sentinel']);
        const english: number = await this.scalar('SELECT count(*) FROM text_fts WHERE text_fts MATCH ? AND chunk_id=?', ['"keyword"', 'capability-sentinel']);
        const rollback: relationalStore.Transaction = await store.createTransaction();
        try { await rollback.execute('DELETE FROM text_fts WHERE chunk_id=?', ['capability-sentinel']); }
        finally { await rollback.rollback(); }
        const retained: number = await this.scalar('SELECT count(*) FROM text_fts WHERE chunk_id=?', ['capability-sentinel']);
        await this.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
          await transaction.execute('DELETE FROM text_fts WHERE chunk_id=?', ['capability-sentinel']);
        });
        const deleted: number = await this.scalar('SELECT count(*) FROM text_fts WHERE chunk_id=?', ['capability-sentinel']);
        if (chinese !== 1 || english !== 1 || retained !== 1 || deleted !== 0) { throw new TextFailure('FTS', 'verify', 'FTS 实际事务/中英查询未通过'); }
        const missing: number = await this.scalar('SELECT count(*) FROM text_chunk c JOIN text_doc d ON d.id=c.doc AND d.active=c.generation LEFT JOIN text_fts f ON f.chunk_id=c.id WHERE f.chunk_id IS NULL');
        if (missing !== 0) { throw new TextFailure('FTS', 'coverage', '既有活动块未完整倒排，保持 LIKE 通道'); }
        this.activeChannel = TextChannel.Fts;
        await store.executeSql('INSERT OR REPLACE INTO text_meta(key,value) VALUES(?,?)', ['fts_layout', TEXT_FTS_DDL]);
      } catch { this.activeChannel = TextChannel.Like; }
    }
    await store.executeSql('INSERT OR REPLACE INTO text_meta(key,value) VALUES(?,?)', ['channel', this.activeChannel]);
  }
  async close(): Promise<void> { await this.tail; if (this.store !== undefined) { await this.host.release(); this.store = undefined; } }
  async list(): Promise<TextDocument[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM text_doc ORDER BY created DESC,id');
    const docs: TextDocument[] = [];
    try { while (rows.goToNextRow()) { docs.push(rowDocument(rows)); } } finally { rows.close(); } return docs;
  }
  async usage(): Promise<TextUsage> {
    const result: TextUsage = new TextUsage();
    result.documents = await this.scalar('SELECT count(*) FROM text_doc');
    result.originalBytes = await this.scalar('SELECT coalesce(sum(bytes),0) FROM text_doc');
    result.activeChunks = await this.scalar('SELECT coalesce(sum(chunks),0) FROM text_doc'); return result;
  }
  private async lookup(column: string, argument: string): Promise<TextDocument | undefined> {
    if (column !== 'id' && column !== 'hash') { throw new TextFailure('SQL', 'lookup', '非法内部查询列'); }
    const rows: relationalStore.ResultSet = await this.requireStore().querySql(`SELECT * FROM text_doc WHERE ${column}=?`, [argument]);
    try { return rows.goToNextRow() ? rowDocument(rows) : undefined; } finally { rows.close(); }
  }
  async get(id: string): Promise<TextDocument | undefined> { return this.lookup('id', id); }
  async findHash(hash: string): Promise<TextDocument | undefined> { return this.lookup('hash', hash); }
  private async insertJob(transaction: relationalStore.Transaction, job: TextJob): Promise<void> {
    await transaction.execute('INSERT INTO text_job(id,doc,generation,stage,checkpoint,cancel,started,failure) VALUES(?,?,?,?,?,?,?,?)',
      [job.id, job.documentId, job.generation, job.stage, job.checkpoint, job.cancelGeneration, job.startedAt, job.failure]);
  }
  async add(doc: TextDocument, job: TextJob): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      await this.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        await transaction.execute('INSERT INTO text_doc VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
          [doc.id,doc.title,doc.format,doc.original.assetId,doc.original.hash,doc.original.bytes,doc.version,doc.activeGeneration,
            doc.archived ? 1 : 0,doc.stage,doc.failure,doc.chunkCount,doc.createdAt,doc.updatedAt,packTextFields(doc.warnings)]);
        await this.insertJob(transaction, job);
      });
    });
  }
  async start(job: TextJob): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      await this.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        if (await this.get(job.documentId) === undefined) { throw new TextFailure('DELETED', 'start', '文档已删除'); }
        await transaction.execute('DELETE FROM text_job WHERE doc=?', [job.documentId]); await this.insertJob(transaction, job);
      });
    });
  }
  async checkpoint(job: TextJob): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      await this.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        await transaction.execute('UPDATE text_job SET stage=?,checkpoint=?,cancel=?,failure=? WHERE id=? AND doc IN (SELECT id FROM text_doc)',
          [job.stage,job.checkpoint,job.cancelGeneration,job.failure,job.id]);
        await transaction.execute('UPDATE text_doc SET stage=?,failure=?,updated=? WHERE id=?', [job.stage,job.failure,Date.now(),job.documentId]);
      });
    });
  }
  async jobs(): Promise<TextJob[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM text_job WHERE stage<>? ORDER BY started', [TextStage.Ready]);
    const jobs: TextJob[] = [];
    try {
      while (rows.goToNextRow()) {
        const job: TextJob = new TextJob(); job.id = rows.getString(0); job.documentId = rows.getString(1);
        job.generation = rows.getString(2); job.stage = storedStage(rows.getString(3)); job.checkpoint = storedStage(rows.getString(4));
        job.cancelGeneration = rows.getLong(5); job.startedAt = rows.getLong(6); job.failure = rows.getString(7); jobs.push(job);
      }
    } finally { rows.close(); } return jobs;
  }
  async prepare(doc: TextDocument, job: TextJob, chunks: TextChunk[]): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      const store: relationalStore.RdbStore = this.requireStore();
      const remaining: number = await this.scalar('SELECT count(*) FROM text_chunk WHERE generation NOT IN (SELECT active FROM text_doc)');
      if (remaining > 0) { throw new TextFailure('CLEANUP', 'prepare', '有失活索引待清理，请先完成清理再重建'); }
      await store.executeSql('INSERT INTO text_generation VALUES(?,?,?,?,?,0)', [job.generation,doc.id,`${job.generation}-snapshot`,doc.version,doc.original.hash]);
      for (let start: number = 0; start < chunks.length; start += 100) {
        if (job.stage === TextStage.Paused || job.stage === TextStage.Failed || Date.now() - job.startedAt >= TextBudget.indexMs || await this.get(doc.id) === undefined) {
          throw new TextFailure('STALE', 'prepare', '任务取消、超时或文档已删，停止后续批次');
        }
        try { await this.writeChunkBatch(chunks.slice(start, start + 100)); }
        catch {
          if (this.activeChannel !== TextChannel.Fts) { throw new TextFailure('INDEX', 'prepare', '普通索引写入失败'); }
          this.activeChannel = TextChannel.Like;
          await this.writeChunkBatch(chunks.slice(start, start + 100));
        }
      }
      if (await this.scalar('SELECT count(*) FROM text_chunk WHERE generation=?', [job.generation]) !== chunks.length) {
        throw new TextFailure('INDEX', 'prepare', '块数校验失败，未发布');
      }
      if (this.activeChannel === TextChannel.Fts && await this.scalar('SELECT count(*) FROM text_fts JOIN text_chunk c ON text_fts.chunk_id=c.id WHERE c.generation=?', [job.generation]) !== chunks.length) {
        // Keep same ordinary data. FTS failure does not erase or switch stores.
        this.activeChannel = TextChannel.Like;
      }
      await store.executeSql('UPDATE text_generation SET complete=1 WHERE id=?', [job.generation]);
    });
  }
  private async writeChunkBatch(chunks: TextChunk[]): Promise<void> {
    await this.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
      for (const chunk of chunks) {
        await transaction.execute('INSERT INTO text_chunk VALUES(?,?,?,?,?,?,?,?,?,?,?)',
          [chunk.id,chunk.documentId,chunk.generation,chunk.snapshotId,chunk.ordinal,chunk.kind,chunk.retrievalText,
            chunk.evidenceText,chunk.prefix,encodeRanges(chunk.ranges),packTextFields(chunk.blockIds)]);
        if (this.activeChannel === TextChannel.Fts) {
          await transaction.execute('INSERT INTO text_fts(chunk_id,text) VALUES(?,?)', [chunk.id,chunk.retrievalText]);
        }
      }
    });
  }
  async publish(doc: TextDocument, job: TextJob, chunks: number): Promise<boolean> {
    return this.write<boolean>(async (): Promise<boolean> => {
      let published: boolean = false;
      await this.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        const rows: relationalStore.ResultSet = await transaction.querySql(
          'SELECT d.id FROM text_doc d JOIN text_job j ON j.doc=d.id JOIN text_generation g ON g.id=j.generation WHERE d.id=? AND d.hash=? AND d.version=? AND j.id=? AND j.cancel=? AND j.stage=? AND g.complete=1',
          [doc.id,doc.original.hash,doc.version,job.id,job.cancelGeneration,TextStage.Prepared]);
        try { published = rows.goToNextRow(); } finally { rows.close(); }
        if (!published) { return; }
        if (Date.now() - job.startedAt >= TextBudget.indexMs || job.stage !== TextStage.Prepared) { published = false; return; }
        const old: relationalStore.ResultSet = await transaction.querySql('SELECT active FROM text_doc WHERE id=?', [doc.id]);
        let oldGeneration: string = '';
        try { if (old.goToNextRow()) { oldGeneration = old.getString(0); } } finally { old.close(); }
        if (oldGeneration.length > 0 && oldGeneration !== job.generation) {
          await transaction.execute('INSERT OR IGNORE INTO text_cleanup VALUES(?,?,?,?,?)',
            [`obsolete-${oldGeneration}`,doc.id,oldGeneration,packTextFields([`${oldGeneration}-snapshot`]),'']);
        }
        await transaction.execute('UPDATE text_doc SET active=?,chunks=?,stage=?,failure=?,updated=?,warnings=? WHERE id=?',
          [job.generation,chunks,TextStage.Ready,'',Date.now(),packTextFields(doc.warnings),doc.id]);
        await transaction.execute('UPDATE text_job SET stage=?,checkpoint=? WHERE id=?', [TextStage.Ready,TextStage.Ready,job.id]);
        if (job.stage !== TextStage.Prepared || Date.now() - job.startedAt >= TextBudget.indexMs) {
          throw new TextFailure('STALE', 'publish', '提交前任务失效，事务回滚');
        }
      }); return published;
    });
  }
  async search(input: TextQueryInput, archived: boolean, cancel: TextCancellation): Promise<TextSearchResult> {
    return this.recall(input, archived, cancel, 5);
  }
  async candidates(input: TextQueryInput, archived: boolean, cancel: TextCancellation): Promise<TextSearchResult> {
    return this.recall(input, archived, cancel, 20);
  }
  async directCandidates(input: TextQueryInput, archived: boolean, cancel: TextCancellation): Promise<TextSearchResult> {
    cancel.check(); const result = new TextSearchResult(); result.input = input; result.channel = TextChannel.Like;
    const rows = await this.requireStore().querySql('SELECT c.id,c.doc,c.generation,c.snapshot,c.kind,c.text,c.evidence,c.ranges,d.title,d.version,d.hash FROM text_chunk c JOIN text_doc d ON d.id=c.doc AND d.active=c.generation JOIN text_generation g ON g.id=c.generation AND g.complete=1 WHERE (?=1 OR d.archived=0) ORDER BY c.doc,c.ordinal',[archived ? 1 : 0]); let scanned: number = 0;
    try { while (rows.goToNextRow()) {
      cancel.check(); if (++scanned > TextBudget.activeChunks) { throw new TextFailure('BUDGET','direct','活动正文超限'); }
      const score = knowledgeLiteralScore(rows.getString(6),input); if (score > 0) {
        const hit = new TextHit(); hit.chunkId = rows.getString(0); hit.documentId = rows.getString(1); hit.generation = rows.getString(2); hit.snapshotId = rows.getString(3); hit.kind = textNodeKind(rows.getString(4)); hit.retrievalText = rows.getString(5); hit.text = rows.getString(6); hit.ranges = decodeRanges(rows.getString(7)); hit.title = rows.getString(8); hit.documentVersion = rows.getLong(9); hit.originalHash = rows.getString(10); hit.channel = TextChannel.Like; hit.score = score; result.hits.push(hit); result.hits.sort(compareTextHits); if (result.hits.length > 20) { result.hits.pop(); }
      }
      if (scanned%100 === 0) { await new Promise<void>((resolve: () => void): void => { setTimeout(resolve,0); }); }
    } } finally { rows.close(); } cancel.check(); return result;
  }
  private async recall(input: TextQueryInput, archived: boolean, cancel: TextCancellation, limit: number): Promise<TextSearchResult> {
    cancel.check();
    const result: TextSearchResult = new TextSearchResult(); result.input = input;
    let fts: boolean = this.activeChannel === TextChannel.Fts;
    try { result.hits = await this.searchRows(input, archived, fts, cancel, limit); }
    catch {
      if (!fts) { throw new TextFailure('QUERY', 'LIKE', '字面关键词检索失败，不是无召回'); }
      fts = false; this.activeChannel = TextChannel.Like;
      result.notice = 'FTS 查询失败，实际使用 LIKE 字面关键词降级';
      result.hits = await this.searchRows(input, archived, false, cancel, limit);
    }
    result.channel = fts ? TextChannel.Fts : TextChannel.Like;
    result.hits.sort(compareTextHits); result.hits = result.hits.slice(0, limit); cancel.check(); return result;
  }
  private async searchRows(input: TextQueryInput, archived: boolean, fts: boolean, cancel: TextCancellation, limit: number): Promise<TextHit[]> {
    const clauses: string[] = []; const args: relationalStore.ValueType[] = [archived ? 1 : 0];
    let join: string = '';
    if (fts) { join = ' JOIN text_fts ON text_fts.chunk_id=c.id'; clauses.push('text_fts MATCH ?'); args.push(textFtsInput(input.terms)); }
    else { for (const term of input.terms) { clauses.push("c.text LIKE ? ESCAPE '\\'"); args.push(textLikePattern(term)); } }
    const sql: string = 'SELECT c.id,c.doc,c.generation,c.snapshot,c.kind,c.text,c.evidence,c.ranges,d.title,d.version,d.hash FROM text_chunk c JOIN text_doc d ON d.id=c.doc AND d.active=c.generation JOIN text_generation g ON g.id=c.generation AND g.complete=1' + join +
      ' WHERE (?=1 OR d.archived=0) AND (' + clauses.join(' OR ') + ') ORDER BY c.doc,c.ordinal';
    const rows: relationalStore.ResultSet = await this.requireStore().querySql(sql, args);
    const hits: TextHit[] = [];
    try {
      let count: number = 0;
      while (rows.goToNextRow()) {
        cancel.check(); const hit: TextHit = new TextHit();
        hit.chunkId = rows.getString(0); hit.documentId = rows.getString(1); hit.generation = rows.getString(2);
        hit.snapshotId = rows.getString(3); hit.kind = textNodeKind(rows.getString(4)); hit.retrievalText = rows.getString(5);
        hit.text = rows.getString(6); hit.ranges = decodeRanges(rows.getString(7)); hit.title = rows.getString(8);
        hit.documentVersion = rows.getLong(9); hit.originalHash = rows.getString(10);
        hit.channel = fts ? TextChannel.Fts : TextChannel.Like; hit.score = textKeywordScore(hit.retrievalText, input.terms);
        // Score is literal occurrence count, not a fabricated semantic confidence.
        hits.push(hit); hits.sort(compareTextHits); if (hits.length > limit) { hits.pop(); }
        count++; if (count % 100 === 0) { await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); }); }
        if (count > TextBudget.activeChunks) { throw new TextFailure('BUDGET', 'query', '活动索引行数异常'); }
      }
    } finally { rows.close(); } return hits;
  }
  async rename(id: string, title: string): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      await this.requireStore().executeSql('UPDATE text_doc SET title=?,updated=? WHERE id=?', [title,Date.now(),id]);
    });
  }
  async archive(id: string, archived: boolean): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      await this.requireStore().executeSql('UPDATE text_doc SET archived=?,updated=? WHERE id=?', [archived ? 1 : 0,Date.now(),id]);
    });
  }
  private async generationAssets(documentId: string): Promise<string[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT snapshot FROM text_generation WHERE doc=?', [documentId]);
    const assets: string[] = [];
    try { while (rows.goToNextRow()) { assets.push(rows.getString(0)); } } finally { rows.close(); } return assets;
  }
  async deleteDocuments(ids: string[]): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      await this.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        for (const id of ids) {
          const doc: TextDocument | undefined = await this.get(id); if (doc === undefined) { continue; }
          const assets: string[] = [doc.original.assetId].concat(await this.generationAssets(id));
          for (const job of await this.jobs()) {
            if (job.documentId === id && assets.indexOf(`${job.generation}-snapshot`) < 0) { assets.push(`${job.generation}-snapshot`); }
          }
          await transaction.execute('INSERT OR IGNORE INTO text_cleanup VALUES(?,?,?,?,?)', [`delete-${id}`,id,'',packTextFields(assets),'']);
          // Ordinary identities disappear atomically. FTS residuals are hidden by JOIN,
          // and removed by the durable cleanup below even if virtual-table deletion fails.
          await transaction.execute('DELETE FROM text_doc WHERE id=?', [id]);
          await transaction.execute('DELETE FROM text_job WHERE doc=?', [id]);
          if (this.activeChannel === TextChannel.Fts) {
            await transaction.execute('DELETE FROM text_fts WHERE chunk_id IN (SELECT id FROM text_chunk WHERE doc=?)', [id]);
          }
          await transaction.execute('DELETE FROM text_chunk WHERE doc=?', [id]);
          await transaction.execute('DELETE FROM text_generation WHERE doc=?', [id]);
        }
      });
    });
  }
  async cleanups(): Promise<TextCleanup[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM text_cleanup ORDER BY id');
    const cleanups: TextCleanup[] = [];
    try {
      while (rows.goToNextRow()) {
        const item: TextCleanup = new TextCleanup(); item.id = rows.getString(0); item.documentId = rows.getString(1);
        item.generation = rows.getString(2); const assets: string = rows.getString(3);
        item.assetIds = assets.length > 0 ? assets.split('\t').map((s: string): string => decodeURIComponent(s)) : [];
        item.failure = rows.getString(4); cleanups.push(item);
      }
    } finally { rows.close(); } return cleanups;
  }
  async finishCleanup(id: string, failure: string): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      if (failure.length > 0) { await this.requireStore().executeSql('UPDATE text_cleanup SET failure=? WHERE id=?', [failure,id]); return; }
      const items: TextCleanup[] = await this.cleanups(); const item: TextCleanup | undefined = items.find((c: TextCleanup): boolean => c.id === id);
      if (item === undefined) { return; }
      if (item.generation.length > 0 && await this.scalar('SELECT count(*) FROM text_doc WHERE active=?', [item.generation]) > 0) {
        throw new TextFailure('ACTIVE', 'cleanup', '拒绝清理活动世代');
      }
      const filter: string = item.generation.length > 0 ? 'generation=?' : 'doc=?';
      const parameter: string = item.generation.length > 0 ? item.generation : item.documentId;
      // FTS cleanup remains durable until successful; absence is permitted only
      // when the virtual table was never created.
      if (await this.scalar("SELECT count(*) FROM sqlite_master WHERE name='text_fts'") > 0) {
        if (item.generation.length > 0) {
          await this.requireStore().executeSql("DELETE FROM text_fts WHERE chunk_id LIKE ? ESCAPE '\\'", [textLikePattern(item.generation + '-c').slice(1)]);
        } else {
          // Deleted document identities are absent; recovery sweeps only orphans.
          await this.requireStore().executeSql('DELETE FROM text_fts WHERE chunk_id NOT IN (SELECT id FROM text_chunk)');
        }
      }
      await this.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        await transaction.execute(`DELETE FROM text_chunk WHERE ${filter}`, [parameter]);
        if (item.generation.length > 0) { await transaction.execute('DELETE FROM text_generation WHERE id=?', [item.generation]); }
        else { await transaction.execute('DELETE FROM text_generation WHERE doc=?', [item.documentId]); }
        await transaction.execute('DELETE FROM text_cleanup WHERE id=?', [id]);
      });
    });
  }
  async reconcile(pauseJobs: boolean = true): Promise<void> {
    await this.write<void>(async (): Promise<void> => {
      await this.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        if (pauseJobs) {
          await transaction.execute('UPDATE text_job SET stage=?,cancel=cancel+1,failure=? WHERE stage NOT IN (?,?,?)',
          [TextStage.Paused,'上次处理已中断，请手动继续',TextStage.Ready,TextStage.Paused,TextStage.Failed]);
        await transaction.execute('UPDATE text_doc SET stage=?,failure=? WHERE id IN (SELECT doc FROM text_job WHERE stage=?)',
          [TextStage.Paused,'上次处理已中断，原件及旧活动索引保留',TextStage.Paused]);
        }
        await transaction.execute('DELETE FROM text_job WHERE doc NOT IN (SELECT id FROM text_doc)');
        const rows: relationalStore.ResultSet = await transaction.querySql(
          'SELECT g.id,g.doc,g.snapshot FROM text_generation g LEFT JOIN text_doc d ON d.id=g.doc LEFT JOIN text_job j ON j.generation=g.id WHERE d.id IS NULL OR (g.id<>d.active AND j.id IS NULL)');
        const cleanups: TextCleanup[] = [];
        try {
          while (rows.goToNextRow()) {
            const cleanup: TextCleanup = new TextCleanup(); cleanup.id = `obsolete-${rows.getString(0)}`;
            cleanup.generation = rows.getString(0); cleanup.documentId = rows.getString(1); cleanup.assetIds = [rows.getString(2)]; cleanups.push(cleanup);
          }
        } finally { rows.close(); }
        for (const cleanup of cleanups) {
          await transaction.execute('INSERT OR IGNORE INTO text_cleanup VALUES(?,?,?,?,?)',
            [cleanup.id,cleanup.documentId,cleanup.generation,packTextFields(cleanup.assetIds),'']);
        }
      });
    });
  }
  async assetIds(): Promise<string[]> {
    const ids: string[] = (await this.list()).map((doc: TextDocument): string => doc.original.assetId);
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT snapshot FROM text_generation');
    try { while (rows.goToNextRow()) { ids.push(rows.getString(0)); } } finally { rows.close(); }
    for (const job of await this.jobs()) {
      if (job.checkpoint === TextStage.Normalized || job.checkpoint === TextStage.Prepared) { ids.push(`${job.generation}-snapshot`); }
    }
    for (const cleanup of await this.cleanups()) { for (const id of cleanup.assetIds) { ids.push(id); } }
    return ids;
  }
  async historyBefore(created: number, id: string, limit: number): Promise<TextHistory[]> {
    if (!Number.isSafeInteger(created) || created < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > 20) { throw new TextFailure('BUDGET','history','旧历史游标非法'); }
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM text_query WHERE created<? OR (created=? AND id<?) ORDER BY created DESC,id DESC LIMIT ?',[created,created,id,limit]);
    const records: TextHistory[] = [];
    try { while (rows.goToNextRow()) {
      const record: TextHistory = new TextHistory(); record.id = rows.getString(0); record.createdAt = rows.getLong(1);
      if (rows.getString(2) !== 'question-parts-v1') { throw new TextFailure('SCHEMA','history','未知旧历史布局'); }
      record.result.input.actualInput = rows.getString(3); record.result.input.notice = rows.getString(4); record.result.channel = storedChannel(rows.getString(5)); records.push(record);
    } } finally { rows.close(); }
    for (const record of records) { record.result.input.fullQuestion = await this.questionParts(record.id); record.result.hits = await this.citations(record.id); } return records;
  }
  async saveHistory(history: TextHistory): Promise<void> {
    const result: TextSearchResult = history.result;
    if (result.hits.length > 5 || result.input.actualInput.length > 1024) { throw new TextFailure('BUDGET', 'history', '查询快照超限'); }
    await this.write<void>(async (): Promise<void> => {
      await this.transaction(async (transaction: relationalStore.Transaction): Promise<void> => {
        await transaction.execute('INSERT INTO text_query VALUES(?,?,?,?,?,?)',
          [history.id,history.createdAt,'question-parts-v1',result.input.actualInput,result.input.notice,result.channel]);
        const question: string = result.input.fullQuestion;
        let ordinal: number = 0;
        for (let cursor: number = 0; cursor < question.length;) {
          const end: number = safeTextBoundary(question, Math.min(question.length, cursor + 16384));
          await transaction.execute('INSERT INTO text_question_part VALUES(?,?,?)', [history.id,ordinal++,question.slice(cursor,end)]); cursor = end;
        }
        for (let i: number = 0; i < result.hits.length; i++) {
          const hit: TextHit = result.hits[i];
          if (hit.text.length > 512 || hit.retrievalText.length > 512 || hit.title.length > 256 || encodeRanges(hit.ranges).length > 65536) {
            throw new TextFailure('BUDGET', 'history', '引用快照行超过保护预算');
          }
          await transaction.execute('INSERT INTO text_citation VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            [history.id,i,hit.documentId,hit.title,hit.documentVersion,hit.originalHash,hit.generation,hit.snapshotId,hit.chunkId,
              hit.text,hit.retrievalText,hit.kind,encodeRanges(hit.ranges),hit.channel,hit.score]);
        }
      });
    });
  }
  private async questionParts(queryId: string): Promise<string> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT ordinal,text FROM text_question_part WHERE query_id=? ORDER BY ordinal', [queryId]);
    const parts: string[] = [];
    try {
      while (rows.goToNextRow()) {
        if (rows.getLong(0) !== parts.length || rows.getString(1).length > 16384) { throw new TextFailure('SCHEMA', 'history', '问题分页记录不完整'); }
        parts.push(rows.getString(1));
      }
    } finally { rows.close(); }
    if (parts.length === 0) { throw new TextFailure('SCHEMA', 'history', '完整问题记录缺失'); } return parts.join('');
  }
  private async citations(queryId: string): Promise<TextHit[]> {
    const rows: relationalStore.ResultSet = await this.requireStore().querySql(
      'SELECT c.*,d.id AS current_id,d.version AS current_version,d.hash AS current_hash,d.active AS current_generation FROM text_citation c LEFT JOIN text_doc d ON d.id=c.doc WHERE c.query_id=? ORDER BY c.ordinal', [queryId]);
    const hits: TextHit[] = [];
    try {
      while (rows.goToNextRow()) {
        const hit: TextHit = new TextHit(); hit.documentId = rows.getString(2); hit.title = rows.getString(3);
        hit.documentVersion = rows.getLong(4); hit.originalHash = rows.getString(5); hit.generation = rows.getString(6);
        hit.snapshotId = rows.getString(7); hit.chunkId = rows.getString(8); hit.text = rows.getString(9);
        hit.retrievalText = rows.getString(10); hit.kind = textNodeKind(rows.getString(11)); hit.ranges = decodeRanges(rows.getString(12));
        hit.channel = storedChannel(rows.getString(13)); hit.score = rows.getLong(14);
        if (rows.isColumnNull(rows.getColumnIndex('current_id'))) { hit.referenceState = TextReferenceState.Deleted; }
        else if (rows.getLong(rows.getColumnIndex('current_version')) !== hit.documentVersion ||
          rows.getString(rows.getColumnIndex('current_hash')) !== hit.originalHash || rows.getString(rows.getColumnIndex('current_generation')) !== hit.generation) {
          hit.referenceState = TextReferenceState.Old;
        }
        hits.push(hit);
        if (hits.length > 5) { throw new TextFailure('SCHEMA', 'history', '引用数量异常'); }
      }
    } finally { rows.close(); } return hits;
  }
  async history(offset: number, limit: number): Promise<TextHistory[]> {
    if (!Number.isSafeInteger(offset) || offset < 0 || limit < 1 || limit > TextBudget.historyPage) { throw new TextFailure('BUDGET', 'history', '历史分页参数非法'); }
    const rows: relationalStore.ResultSet = await this.requireStore().querySql('SELECT * FROM text_query ORDER BY created DESC,id DESC LIMIT ? OFFSET ?', [limit,offset]);
    const records: TextHistory[] = [];
    try {
      while (rows.goToNextRow()) {
        const record: TextHistory = new TextHistory(); record.id = rows.getString(0); record.createdAt = rows.getLong(1);
        if (rows.getString(2) !== 'question-parts-v1') { throw new TextFailure('SCHEMA', 'history', '未知历史问题布局'); }
        record.result.input.actualInput = rows.getString(3); record.result.input.notice = rows.getString(4);
        record.result.channel = storedChannel(rows.getString(5)); records.push(record);
      }
    } finally { rows.close(); }
    for (const record of records) {
      record.result.input.fullQuestion = await this.questionParts(record.id); record.result.hits = await this.citations(record.id);
    }
    return records;
  }
}
