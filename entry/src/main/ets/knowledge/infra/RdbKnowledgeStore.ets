import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  ChunkSlice, ChannelRank, DeleteOutcome, IndexOutcome, KnowledgeCounts,
  KnowledgeDocStatus, KnowledgeDocumentRef, KnowledgeHit, RecallChannel
} from '../domain/KnowledgeTypes';
import { chunkText } from '../pipeline/Chunker';
import { PSEUDO_EMBED_DIM, PSEUDO_EMBED_SPACE, pseudoEmbedding } from './PseudoEmbedding';

export const KB_STORE_NAME: string = 'shuvi_kb_probe.db';
export const KB_STORE_NAME_KEYWORD: string = 'shuvi_kb_probe_kw.db';
export const KB_CHUNK_SIZE: number = 512;
export const KB_OVERLAP_RATIO: number = 0.1;
export const KB_SCHEMA_VERSION: number = 1;
const RRF_K: number = 60;
const SANDBOX_DIR_NAME: string = 'kb';

export interface DdlStep {
  name: string;
  ok: boolean;
  detail: string;
}

export class RdbKnowledgeStore {
  private context: common.Context;
  private store: relationalStore.RdbStore | undefined = undefined;
  private vectorEnabled: boolean = false;
  private steps: DdlStep[] = [];
  private sequence: number = 0;
  private degradedReason: string = '';
  private openedWithName: string = KB_STORE_NAME;
  private ftsMode: string = 'none';
  private ftsDdl: string = '';

  constructor(context: common.Context) {
    this.context = context;
  }

  isVectorEnabled(): boolean {
    return this.vectorEnabled;
  }

  ddlSteps(): DdlStep[] {
    return this.steps;
  }

  embedSpace(): string {
    return PSEUDO_EMBED_SPACE;
  }

  embedDim(): number {
    return PSEUDO_EMBED_DIM;
  }

  degraded(): string {
    return this.degradedReason;
  }

  openedName(): string {
    return this.openedWithName;
  }

  invertedMode(): string {
    return this.ftsMode;
  }

  async open(): Promise<void> {
    const vectorSupported: boolean = relationalStore.isVectorSupported();
    this.vectorEnabled = vectorSupported;
    const vectorConfig: relationalStore.StoreConfig = {
      name: KB_STORE_NAME,
      securityLevel: relationalStore.SecurityLevel.S3,
      vector: vectorSupported
    };
    this.store = await relationalStore.getRdbStore(this.context, vectorConfig);
    this.openedWithName = KB_STORE_NAME;
    await this.createSchema();
    if (this.schemaFailed() && vectorSupported) {
      this.degradedReason = 'vector store DDL failed, retry with keyword-only store';
      this.store = undefined;
      this.vectorEnabled = false;
      const keywordConfig: relationalStore.StoreConfig = {
        name: KB_STORE_NAME_KEYWORD,
        securityLevel: relationalStore.SecurityLevel.S3,
        vector: false
      };
      this.store = await relationalStore.getRdbStore(this.context, keywordConfig);
      this.openedWithName = KB_STORE_NAME_KEYWORD;
      await this.createSchema();
    }
  }

  private schemaFailed(): boolean {
    for (let i = 0; i < this.steps.length; i++) {
      if (!this.steps[i].ok) {
        return true;
      }
    }
    return false;
  }

  async ingest(ref: KnowledgeDocumentRef): Promise<IndexOutcome> {
    const store = this.requireStore();
    const documentId: string = this.nextId('doc');
    const contentHash: string = hashText(ref.text);
    const sandboxPath: string = `${this.sandboxDir()}/${documentId}.md`;
    ensureDirectory(this.sandboxDir());
    writeTextFile(sandboxPath, ref.text);
    const loaded: string = fileIo.readTextSync(sandboxPath);
    const slices: ChunkSlice[] = chunkText(loaded, KB_CHUNK_SIZE, KB_OVERLAP_RATIO);
    const now: number = Date.now();
    store.beginTransaction();
    try {
      const docBucket: relationalStore.ValuesBucket = {
        'id': documentId,
        'title': ref.title,
        'source_type': 'TEXT_FILE',
        'content_hash': contentHash,
        'content': loaded,
        'schema_version': KB_SCHEMA_VERSION,
        'created_at': now,
        'updated_at': now
      };
      await store.insert('kb_document', docBucket);
      const stateBucket: relationalStore.ValuesBucket = {
        'document_id': documentId,
        'status': KnowledgeDocStatus.Indexing,
        'chunk_count': 0,
        'fail_reason': '',
        'index_version': this.vectorEnabled ? `${PSEUDO_EMBED_SPACE}` : 'keyword-only',
        'updated_at': now
      };
      await store.insert('kb_doc_state', stateBucket);
      let vectorCount: number = 0;
      for (let i = 0; i < slices.length; i++) {
        const slice: ChunkSlice = slices[i];
        const chunkId: string = `${documentId}-c${i}`;
        let chunkBucket: relationalStore.ValuesBucket;
        if (this.vectorEnabled) {
          const vector: Float32Array = pseudoEmbedding(slice.text);
          vectorCount++;
          chunkBucket = {
            'chunk_id': chunkId,
            'document_id': documentId,
            'ordinal': i,
            'text': slice.text,
            'char_offset': slice.charOffset,
            'embed_space': PSEUDO_EMBED_SPACE,
            'embedding': vector
          };
        } else {
          chunkBucket = {
            'chunk_id': chunkId,
            'document_id': documentId,
            'ordinal': i,
            'text': slice.text,
            'char_offset': slice.charOffset,
            'embed_space': null
          };
        }
        await store.insert('kb_chunk', chunkBucket);
      }
      await store.executeSql(
        'UPDATE kb_doc_state SET status = ?, chunk_count = ?, updated_at = ? WHERE document_id = ?',
        [KnowledgeDocStatus.Indexing, slices.length, Date.now(), documentId]);
      store.commit();
      await this.writeInvertedIndex(documentId);
      const outcome: IndexOutcome = {
        documentId: documentId,
        title: ref.title,
        chunkCount: slices.length,
        vectorCount: vectorCount
      };
      return outcome;
    } catch (error) {
      await this.safeRollback(store);
      const businessError: BusinessError = error as BusinessError;
      throw new Error(`ingest failed: ${describeError(businessError)}`);
    }
  }

  async search(query: string, topK: number): Promise<KnowledgeHit[]> {
    const inverted: ChannelRank[] = await this.searchInverted(query, topK * 2);
    const vector: ChannelRank[] = this.vectorEnabled ? await this.searchVector(query, topK * 2) : [];
    if (inverted.length === 0 && vector.length === 0) {
      const fallback: ChannelRank[] = await this.searchLike(query, topK * 2);
      return await this.fuse(fallback, [], topK);
    }
    return await this.fuse(inverted, vector, topK);
  }

  async searchLike(query: string, limit: number): Promise<ChannelRank[]> {
    const store = this.requireStore();
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT chunk_id, document_id, text FROM kb_chunk WHERE text LIKE ? LIMIT ?',
      [`%${query}%`, limit]);
    const chunkIdIndex: number = resultSet.getColumnIndex('chunk_id');
    const documentIdIndex: number = resultSet.getColumnIndex('document_id');
    const textIndex: number = resultSet.getColumnIndex('text');
    const ranks: ChannelRank[] = [];
    let rank: number = 0;
    while (resultSet.goToNextRow()) {
      rank++;
      const hit: ChannelRank = {
        chunkId: resultSet.getString(chunkIdIndex),
        documentId: resultSet.getString(documentIdIndex),
        title: '',
        text: resultSet.getString(textIndex),
        channel: RecallChannel.SqlLike,
        rank: rank,
        distance: -1
      };
      ranks.push(hit);
    }
    resultSet.close();
    return ranks;
  }

  async invertedDiagnostics(): Promise<string> {
    const store = this.requireStore();
    if (this.ftsMode === 'none') {
      return 'inverted table not available';
    }
    let writeProbe: string = 'not-attempted';
    try {
      await store.executeSql(
        'INSERT INTO kb_chunk_fts(chunk_id, document_id, text) VALUES(?, ?, ?)',
        ['probe-1', 'probe-doc', '分块重叠 探针']);
      const afterInsert: number = await this.count('SELECT count(*) FROM kb_chunk_fts');
      await store.executeSql('DELETE FROM kb_chunk_fts WHERE chunk_id = ?', ['probe-1']);
      writeProbe = `direct-insert-count=${afterInsert}`;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      writeProbe = `direct-insert-error=${describeError(businessError)}`;
    }
    const total: number = await this.count('SELECT count(*) FROM kb_chunk_fts');
    let sampleRows: number = 0;
    const sampleSet: relationalStore.ResultSet = await store.querySql('SELECT chunk_id FROM kb_chunk_fts LIMIT 5');
    const chunkIdIndex: number = sampleSet.getColumnIndex('chunk_id');
    while (sampleSet.goToNextRow()) {
      sampleRows++;
    }
    sampleSet.close();
    let matchRows: number = 0;
    try {
      const matchSet: relationalStore.ResultSet = await store.querySql(
        'SELECT chunk_id FROM kb_chunk_fts WHERE kb_chunk_fts MATCH ? LIMIT 5', ['分块']);
      while (matchSet.goToNextRow()) {
        matchRows++;
      }
      matchSet.close();
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      return `mode=${this.ftsMode} count=${total} sample=${sampleRows} match-error=${describeError(businessError)}`;
    }
    return `mode=${this.ftsMode} count=${total} sample=${sampleRows} match(分块)=${matchRows} ${writeProbe}`;
  }

  async counts(): Promise<KnowledgeCounts> {
    const result: KnowledgeCounts = {
      documents: await this.count('SELECT count(*) FROM kb_document'),
      chunks: await this.count('SELECT count(*) FROM kb_chunk'),
      invertedRows: await this.count('SELECT count(*) FROM kb_chunk_fts'),
      vectorRows: this.vectorEnabled
        ? await this.count('SELECT count(*) FROM kb_chunk WHERE embedding IS NOT NULL')
        : 0,
      orphans: await this.count('SELECT count(*) FROM kb_chunk WHERE document_id NOT IN (SELECT id FROM kb_document)'),
      sandboxFiles: listSandboxFiles(this.sandboxDir())
    };
    return result;
  }

  async deleteDocuments(documentIds: string[]): Promise<DeleteOutcome> {
    const store = this.requireStore();
    let documents: number = 0;
    let chunks: number = 0;
    let inverted: number = 0;
    let directive: string = 'not-attempted';
    const pendingRows: FtsRow[][] = [];
    for (let i = 0; i < documentIds.length; i++) {
      pendingRows.push(await this.loadFtsRows(documentIds[i]));
    }
    store.beginTransaction();
    try {
      for (let i = 0; i < documentIds.length; i++) {
        const documentId: string = documentIds[i];
        const rows: FtsRow[] = pendingRows[i];
        if (this.ftsMode.startsWith('external')) {
          for (let j = 0; j < rows.length; j++) {
            const row: FtsRow = rows[j];
            try {
              await store.executeSql(
                'INSERT INTO kb_chunk_fts(kb_chunk_fts, rowid, chunk_id, document_id, text) VALUES(?, ?, ?, ?, ?)',
                ['delete', row.rowId, row.chunkId, row.documentId, row.text]);
              inverted++;
              directive = 'external:fts5-delete-directive-ok';
            } catch (error) {
              const businessError: BusinessError = error as BusinessError;
              directive = `external:fts5-delete-directive-failed ${describeError(businessError)}`;
            }
          }
        } else if (this.ftsMode !== 'none') {
          try {
            await store.executeSql('DELETE FROM kb_chunk_fts WHERE document_id = ?', [documentId]);
            inverted += rows.length;
            directive = 'independent:delete-by-document-id-ok';
          } catch (error) {
            const businessError: BusinessError = error as BusinessError;
            directive = `independent:delete-failed ${describeError(businessError)}`;
          }
        }
        chunks += rows.length;
        await store.executeSql('DELETE FROM kb_chunk WHERE document_id = ?', [documentId]);
        await store.executeSql('DELETE FROM kb_doc_state WHERE document_id = ?', [documentId]);
        await store.executeSql('DELETE FROM kb_document WHERE id = ?', [documentId]);
        documents++;
        deleteSandboxFile(`${this.sandboxDir()}/${documentId}.md`);
      }
      store.commit();
    } catch (error) {
      await this.safeRollback(store);
      const businessError: BusinessError = error as BusinessError;
      throw new Error(`delete failed: ${describeError(businessError)}`);
    }
    const outcome: DeleteOutcome = {
      documents: documents,
      chunks: chunks,
      invertedRows: inverted,
      invertedDirective: directive
    };
    return outcome;
  }

  async clearAll(): Promise<void> {
    const store = this.requireStore();
    await store.executeSql('DELETE FROM kb_meta');
    await store.executeSql('DELETE FROM kb_chunk');
    await store.executeSql('DELETE FROM kb_doc_state');
    await store.executeSql('DELETE FROM kb_document');
    if (this.ftsDdl.length > 0) {
      await store.executeSql('DROP TABLE IF EXISTS kb_chunk_fts');
      await store.executeSql(this.ftsDdl);
    }
    clearSandboxFiles(this.sandboxDir());
  }

  async listDocumentIds(): Promise<string[]> {
    const store = this.requireStore();
    const args: Array<relationalStore.ValueType> = [];
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT id FROM kb_document ORDER BY created_at', args);
    const ids: string[] = [];
    const index: number = resultSet.getColumnIndex('id');
    while (resultSet.goToNextRow()) {
      ids.push(resultSet.getString(index));
    }
    resultSet.close();
    return ids;
  }

  async reconcile(): Promise<number> {
    const store = this.requireStore();
    const orphans: number = await this.count(
      'SELECT count(*) FROM kb_chunk WHERE document_id NOT IN (SELECT id FROM kb_document)');
    if (orphans > 0) {
      await store.executeSql(
        'DELETE FROM kb_chunk WHERE document_id NOT IN (SELECT id FROM kb_document)');
    }
    return orphans;
  }

  close(): void {
    this.store = undefined;
  }

  private async createSchema(): Promise<void> {
    this.steps = [];
    await this.exec('kb_document', 'CREATE TABLE IF NOT EXISTS kb_document (' +
      'id TEXT PRIMARY KEY, title TEXT, source_type TEXT, content_hash TEXT, content TEXT, ' +
      'schema_version INTEGER, created_at INTEGER, updated_at INTEGER)');
    await this.exec('kb_doc_state', 'CREATE TABLE IF NOT EXISTS kb_doc_state (' +
      'document_id TEXT PRIMARY KEY, status TEXT, chunk_count INTEGER, fail_reason TEXT, ' +
      'index_version TEXT, updated_at INTEGER)');
    const embeddingColumn: string = this.vectorEnabled ? `, embedding FLOATVECTOR(${PSEUDO_EMBED_DIM})` : '';
    this.steps.push({ name: 'mode', ok: true, detail: this.vectorEnabled ? 'vector-store' : 'keyword-only-store' });
    await this.exec('kb_chunk', 'CREATE TABLE IF NOT EXISTS kb_chunk (' +
      'chunk_id TEXT PRIMARY KEY, document_id TEXT NOT NULL, ordinal INTEGER NOT NULL, ' +
      `text TEXT NOT NULL, char_offset INTEGER NOT NULL, embed_space TEXT${embeddingColumn})`);
    await this.exec('kb_meta', 'CREATE TABLE IF NOT EXISTS kb_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    await this.createInvertedTable();
  }

  private async safeRollback(store: relationalStore.RdbStore): Promise<void> {
    try {
      await store.executeSql('ROLLBACK');
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.steps.push({ name: 'rollback', ok: false, detail: describeError(businessError) });
    }
  }

  private async createInvertedTable(): Promise<void> {
    const storedMode: string = await this.metaValue(FTS_MODE_KEY);
    if (await this.tableExists('kb_chunk_fts') && storedMode.length > 0) {
      this.ftsMode = storedMode;
      this.ftsDdl = invertedDdl(storedMode);
      this.steps.push({ name: `kb_chunk_fts[reused:${storedMode}]`, ok: true, detail: 'existing table' });
      return;
    }
    for (let i = 0; i < FTS_CANDIDATES.length; i++) {
      const candidate: FtsCandidate = FTS_CANDIDATES[i];
      await this.exec(`kb_chunk_fts[drop-before:${candidate.mode}]`, 'DROP TABLE IF EXISTS kb_chunk_fts');
      const ok: boolean = await this.exec(`kb_chunk_fts[${candidate.mode}]`, candidate.ddl);
      if (ok) {
        this.ftsMode = candidate.mode;
        this.ftsDdl = candidate.ddl;
        await this.saveMeta(FTS_MODE_KEY, candidate.mode);
        return;
      }
    }
    this.ftsMode = 'none';
  }

  private async tableExists(name: string): Promise<boolean> {
    const store = this.requireStore();
    const resultSet: relationalStore.ResultSet = await store.querySql(
      "SELECT name FROM sqlite_master WHERE name = ? AND type = 'table'", [name]);
    const exists: boolean = resultSet.goToNextRow();
    resultSet.close();
    return exists;
  }

  private async metaValue(key: string): Promise<string> {
    const store = this.requireStore();
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT value FROM kb_meta WHERE key = ?', [key]);
    let value: string = '';
    if (resultSet.goToNextRow()) {
      value = resultSet.getString(0);
    }
    resultSet.close();
    return value;
  }

  private async saveMeta(key: string, value: string): Promise<void> {
    const store = this.requireStore();
    await store.executeSql('INSERT OR REPLACE INTO kb_meta(key, value) VALUES(?, ?)', [key, value]);
  }

  private async exec(name: string, sql: string): Promise<boolean> {
    const store = this.requireStore();
    try {
      await store.executeSql(sql);
      const step: DdlStep = { name: name, ok: true, detail: 'ok' };
      this.steps.push(step);
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      const step: DdlStep = { name: name, ok: false, detail: describeError(businessError) };
      this.steps.push(step);
      return false;
    }
  }

  private async writeInvertedIndex(documentId: string): Promise<void> {
    if (this.ftsMode === 'none') {
      this.steps.push({ name: 'fts-write', ok: false, detail: 'inverted table unavailable' });
      return;
    }
    try {
      await this.syncInvertedIndex(documentId);
      const rows: number = await this.count('SELECT count(*) FROM kb_chunk_fts');
      this.steps.push({ name: 'fts-write', ok: rows > 0, detail: `rows=${rows}` });
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.steps.push({ name: 'fts-write', ok: false, detail: describeError(businessError) });
    }
  }

  private async syncInvertedIndex(documentId: string): Promise<void> {
    if (this.ftsMode === 'none') {
      return;
    }
    const store = this.requireStore();
    const rows: FtsRow[] = await this.loadFtsRows(documentId);
    for (let i = 0; i < rows.length; i++) {
      const row: FtsRow = rows[i];
      if (this.ftsMode.startsWith('external')) {
        await store.executeSql(
          'INSERT INTO kb_chunk_fts(rowid, chunk_id, document_id, text) VALUES(?, ?, ?, ?)',
          [row.rowId, row.chunkId, row.documentId, row.text]);
      } else {
        await store.executeSql(
          'INSERT INTO kb_chunk_fts(chunk_id, document_id, text) VALUES(?, ?, ?)',
          [row.chunkId, row.documentId, row.text]);
      }
    }
  }

  private async loadFtsRows(documentId: string): Promise<FtsRow[]> {
    const store = this.requireStore();
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT rowid, chunk_id, document_id, text FROM kb_chunk WHERE document_id = ?',
      [documentId]);
    const rows: FtsRow[] = [];
    const rowIdIndex: number = resultSet.getColumnIndex('rowid');
    const chunkIdIndex: number = resultSet.getColumnIndex('chunk_id');
    const documentIdIndex: number = resultSet.getColumnIndex('document_id');
    const textIndex: number = resultSet.getColumnIndex('text');
    while (resultSet.goToNextRow()) {
      const row: FtsRow = {
        rowId: resultSet.getLong(rowIdIndex),
        chunkId: resultSet.getString(chunkIdIndex),
        documentId: resultSet.getString(documentIdIndex),
        text: resultSet.getString(textIndex)
      };
      rows.push(row);
    }
    resultSet.close();
    return rows;
  }

  private async searchInverted(query: string, limit: number): Promise<ChannelRank[]> {
    const store = this.requireStore();
    const sanitized: string = sanitizeFtsQuery(query);
    if (sanitized.length === 0) {
      return [];
    }
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT chunk_id, document_id, text FROM kb_chunk_fts WHERE kb_chunk_fts MATCH ? LIMIT ?',
      [sanitized, limit]);
    const chunkIdIndex: number = resultSet.getColumnIndex('chunk_id');
    const documentIdIndex: number = resultSet.getColumnIndex('document_id');
    const textIndex: number = resultSet.getColumnIndex('text');
    const ranks: ChannelRank[] = [];
    let rank: number = 0;
    while (resultSet.goToNextRow()) {
      rank++;
      const hit: ChannelRank = {
        chunkId: resultSet.getString(chunkIdIndex),
        documentId: resultSet.getString(documentIdIndex),
        title: '',
        text: resultSet.getString(textIndex),
        channel: RecallChannel.Inverted,
        rank: rank,
        distance: -1
      };
      ranks.push(hit);
    }
    resultSet.close();
    return ranks;
  }

  private async searchVector(query: string, limit: number): Promise<ChannelRank[]> {
    const store = this.requireStore();
    const vector: Float32Array = pseudoEmbedding(query);
    const resultSet: relationalStore.ResultSet = await store.querySql(
      'SELECT chunk_id, document_id, text, embedding <=> ? AS distance FROM kb_chunk ' +
      'WHERE embed_space = ? AND embedding IS NOT NULL ORDER BY embedding <=> ? LIMIT ?',
      [vector, PSEUDO_EMBED_SPACE, vector, limit]);
    const chunkIdIndex: number = resultSet.getColumnIndex('chunk_id');
    const documentIdIndex: number = resultSet.getColumnIndex('document_id');
    const textIndex: number = resultSet.getColumnIndex('text');
    const distanceIndex: number = resultSet.getColumnIndex('distance');
    const ranks: ChannelRank[] = [];
    let rank: number = 0;
    while (resultSet.goToNextRow()) {
      rank++;
      const hit: ChannelRank = {
        chunkId: resultSet.getString(chunkIdIndex),
        documentId: resultSet.getString(documentIdIndex),
        title: '',
        text: resultSet.getString(textIndex),
        channel: RecallChannel.Vector,
        rank: rank,
        distance: resultSet.getDouble(distanceIndex)
      };
      ranks.push(hit);
    }
    resultSet.close();
    return ranks;
  }

  private async fuse(inverted: ChannelRank[], vector: ChannelRank[], topK: number): Promise<KnowledgeHit[]> {
    const titles: Map<string, string> = await this.loadTitles();
    const scores: Map<string, number> = new Map<string, number>();
    const merged: Map<string, ChannelRank> = new Map<string, ChannelRank>();
    accumulate(scores, merged, inverted);
    accumulate(scores, merged, vector);
    const combined: KnowledgeHit[] = [];
    scores.forEach((score: number, chunkId: string) => {
      const source: ChannelRank | undefined = merged.get(chunkId);
      if (source === undefined) {
        return;
      }
      const invertedRank: number = findRank(inverted, chunkId);
      const vectorRank: number = findRank(vector, chunkId);
      let channel: RecallChannel = source.channel;
      if (invertedRank > 0 && vectorRank > 0) {
        channel = RecallChannel.Fused;
      }
      const title: string | undefined = titles.get(source.documentId);
      const hit: KnowledgeHit = {
        chunkId: chunkId,
        documentId: source.documentId,
        documentTitle: title === undefined ? '' : title,
        text: source.text,
        channel: channel,
        rrfScore: score,
        distance: source.distance
      };
      combined.push(hit);
    });
    combined.sort((left: KnowledgeHit, right: KnowledgeHit) => right.rrfScore - left.rrfScore);
    return combined.slice(0, topK);
  }

  private async loadTitles(): Promise<Map<string, string>> {
    const store = this.requireStore();
    const resultSet: relationalStore.ResultSet = await store.querySql('SELECT id, title FROM kb_document');
    const titles: Map<string, string> = new Map<string, string>();
    const idIndex: number = resultSet.getColumnIndex('id');
    const titleIndex: number = resultSet.getColumnIndex('title');
    while (resultSet.goToNextRow()) {
      titles.set(resultSet.getString(idIndex), resultSet.getString(titleIndex));
    }
    resultSet.close();
    return titles;
  }

  private async count(sql: string): Promise<number> {
    const store = this.requireStore();
    const resultSet: relationalStore.ResultSet = await store.querySql(sql);
    let value: number = 0;
    if (resultSet.goToNextRow()) {
      value = resultSet.getLong(0);
    }
    resultSet.close();
    return value;
  }

  private requireStore(): relationalStore.RdbStore {
    const store: relationalStore.RdbStore | undefined = this.store;
    if (store === undefined) {
      throw new Error('knowledge store is not open');
    }
    return store;
  }

  private sandboxDir(): string {
    return `${this.context.filesDir}/${SANDBOX_DIR_NAME}`;
  }

  private nextId(prefix: string): string {
    this.sequence++;
    return `${prefix}-${this.sequence}-${Date.now()}`;
  }
}

interface FtsCandidate {
  mode: string;
  ddl: string;
}

const FTS_MODE_KEY: string = 'fts_mode';

const FTS_CANDIDATES: FtsCandidate[] = [
  { mode: 'external+custom', ddl: 'CREATE VIRTUAL TABLE IF NOT EXISTS kb_chunk_fts USING fts5(' +
    "chunk_id, document_id UNINDEXED, text, tokenize = 'customtokenizer', " +
    "content = 'kb_chunk', content_rowid = 'rowid')" },
  { mode: 'external+custom-no-unindexed', ddl: 'CREATE VIRTUAL TABLE IF NOT EXISTS kb_chunk_fts USING fts5(' +
    "chunk_id, document_id, text, tokenize = 'customtokenizer', " +
    "content = 'kb_chunk', content_rowid = 'rowid')" },
  { mode: 'independent+custom', ddl: 'CREATE VIRTUAL TABLE IF NOT EXISTS kb_chunk_fts USING fts5(' +
    "chunk_id, document_id UNINDEXED, text, tokenize = 'customtokenizer')" },
  { mode: 'independent+default', ddl: 'CREATE VIRTUAL TABLE IF NOT EXISTS kb_chunk_fts USING fts5(' +
    'chunk_id, document_id UNINDEXED, text)' }
];

function invertedDdl(mode: string): string {
  for (let i = 0; i < FTS_CANDIDATES.length; i++) {
    if (FTS_CANDIDATES[i].mode === mode) {
      return FTS_CANDIDATES[i].ddl;
    }
  }
  return '';
}

interface FtsRow {
  rowId: number;
  chunkId: string;
  documentId: string;
  text: string;
}

function accumulate(scores: Map<string, number>, merged: Map<string, ChannelRank>, ranks: ChannelRank[]): void {
  for (let i = 0; i < ranks.length; i++) {
    const rank: ChannelRank = ranks[i];
    const current: number | undefined = scores.get(rank.chunkId);
    const add: number = 1 / (RRF_K + rank.rank);
    scores.set(rank.chunkId, current === undefined ? add : current + add);
    if (!merged.has(rank.chunkId)) {
      merged.set(rank.chunkId, rank);
    }
  }
}

function findRank(ranks: ChannelRank[], chunkId: string): number {
  for (let i = 0; i < ranks.length; i++) {
    if (ranks[i].chunkId === chunkId) {
      return ranks[i].rank;
    }
  }
  return -1;
}

function sanitizeFtsQuery(query: string): string {
  let sanitized: string = '';
  for (let i = 0; i < query.length; i++) {
    const code: number = query.charCodeAt(i);
    const isDigit: boolean = code >= 48 && code <= 57;
    const isUpper: boolean = code >= 65 && code <= 90;
    const isLower: boolean = code >= 97 && code <= 122;
    const isCjk: boolean = code >= 0x4E00 && code <= 0x9FFF;
    const isSpace: boolean = code === 32;
    sanitized = sanitized + (isDigit || isUpper || isLower || isCjk || isSpace ? query.charAt(i) : ' ');
  }
  return sanitized.trim();
}

function hashText(value: string): string {
  let hash: number = 2166136261;
  for (let i = 0; i < value.length; i++) {
    hash = hash ^ value.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  const unsigned: number = hash >>> 0;
  return `${unsigned.toString(16)}-${value.length}`;
}

function ensureDirectory(dir: string): void {
  if (!fileIo.accessSync(dir)) {
    fileIo.mkdirSync(dir, true);
  }
}

function writeTextFile(path: string, content: string): void {
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, content);
  } finally {
    fileIo.closeSync(file);
  }
}

function deleteSandboxFile(path: string): void {
  if (fileIo.accessSync(path)) {
    fileIo.unlinkSync(path);
  }
}

function clearSandboxFiles(dir: string): void {
  if (!fileIo.accessSync(dir)) {
    return;
  }
  const names: string[] = fileIo.listFileSync(dir);
  for (let i = 0; i < names.length; i++) {
    fileIo.unlinkSync(`${dir}/${names[i]}`);
  }
}

function listSandboxFiles(dir: string): number {
  if (!fileIo.accessSync(dir)) {
    return 0;
  }
  return fileIo.listFileSync(dir).length;
}

function describeError(error: BusinessError): string {
  return `${error.code}: ${error.message}`;
}
