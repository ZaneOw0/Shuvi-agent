import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { DocumentParseRepositoryPort } from '../domain/DocumentParsePorts';
import {
  DocumentParseSnapshot, DocumentOriginal, DocumentParseGrant, DocumentParseTask, DocumentParseResultEnvelope,
  DocumentParseCleanup, DocumentParseFailure, DocumentParseFormat, DocumentPreflightStatus, DocumentParseStage,
  DocumentRemoteState, DocumentParseBudget, documentCopySnapshot, DocumentRemoteOccupancy
} from '../domain/DocumentParseModels';
import { documentSafeId, documentHashValid } from '../pipeline/DocumentParsePolicy';

export const DOCUMENT_PARSE_STORE: string = 'shuvi_parse_stage_v1.db';
const DOCUMENT_PARSE_LAYOUT: string = 'parse-stage-explicit-columns-v1';
const DOCUMENT_PARSE_DDL: string[] = [
  'CREATE TABLE parse_meta (id INTEGER PRIMARY KEY,layout TEXT,enabled INTEGER,revision INTEGER)',
  'CREATE TABLE original (id TEXT PRIMARY KEY,asset TEXT,title TEXT,hash TEXT,bytes INTEGER,format TEXT,version INTEGER,preflight TEXT,pages INTEGER,reason TEXT,saved INTEGER)',
  'CREATE TABLE grant (id TEXT PRIMARY KEY,original TEXT,hash TEXT,version INTEGER,format TEXT,revision INTEGER,policy TEXT,parameters TEXT,full_file INTEGER,images INTEGER,nonsensitive INTEGER,privacy_unknown INTEGER,free INTEGER,issued INTEGER,revoked INTEGER)',
  'CREATE TABLE task (id TEXT PRIMARY KEY,original TEXT,data_id TEXT,batch_id TEXT,grant_id TEXT,hash TEXT,version INTEGER,revision INTEGER,stage TEXT,checkpoint TEXT,remote TEXT,epoch INTEGER,queries INTEGER,window_start INTEGER,uploaded INTEGER,upload_attempted INTEGER,upload_lease TEXT,result_lease TEXT,failure TEXT,extracted INTEGER,total INTEGER)',
  'CREATE TABLE remote_slot (id INTEGER PRIMARY KEY,task_id TEXT,data_id TEXT,batch_id TEXT,revision INTEGER,state TEXT,terminal INTEGER)',
  'CREATE TABLE result (asset TEXT PRIMARY KEY,task_id TEXT,data_id TEXT,original_hash TEXT,version INTEGER,bytes INTEGER,hash TEXT,received INTEGER,status TEXT,complete INTEGER,signature INTEGER)',
  'CREATE TABLE cleanup (id TEXT PRIMARY KEY,assets TEXT,leases TEXT,original_bytes INTEGER,result_bytes INTEGER,failure TEXT)'
];
function parseRowString(rows: relationalStore.ResultSet, name: string): string { return rows.getString(rows.getColumnIndex(name)); }
function parseRowNumber(rows: relationalStore.ResultSet, name: string): number {
  const n: number = rows.getLong(rows.getColumnIndex(name));
  if (!Number.isSafeInteger(n) || n < 0) { throw new DocumentParseFailure('数字列非法', '任务库'); } return n;
}
function parseRowBool(rows: relationalStore.ResultSet, name: string): boolean {
  const n: number = parseRowNumber(rows, name); if (n !== 0 && n !== 1) { throw new DocumentParseFailure('布尔列非法', '任务库'); } return n === 1;
}
function parseStoredFormat(raw: string): DocumentParseFormat {
  for (const f of [DocumentParseFormat.Pdf, DocumentParseFormat.Docx, DocumentParseFormat.Pptx, DocumentParseFormat.Xlsx]) { if (raw === f) { return f; } }
  throw new DocumentParseFailure('格式列未知', '任务库');
}
function parseStoredStage(raw: string): DocumentParseStage {
  const stages: DocumentParseStage[] = [DocumentParseStage.Saved, DocumentParseStage.Allocation, DocumentParseStage.Uncertain,
    DocumentParseStage.LeaseReady, DocumentParseStage.Uploading, DocumentParseStage.UploadUnknown, DocumentParseStage.Waiting,
    DocumentParseStage.Pending, DocumentParseStage.Converting, DocumentParseStage.Running, DocumentParseStage.Done,
    DocumentParseStage.RemoteFailed, DocumentParseStage.Downloading, DocumentParseStage.Received, DocumentParseStage.Paused, DocumentParseStage.Failed];
  for (const stage of stages) { if (stage === raw) { return stage; } } throw new DocumentParseFailure('阶段列未知', '任务库');
}
function parseStoredRemote(raw: string): DocumentRemoteState {
  for (const state of [DocumentRemoteState.Unobserved, DocumentRemoteState.Waiting, DocumentRemoteState.Pending, DocumentRemoteState.Converting, DocumentRemoteState.Running, DocumentRemoteState.Done, DocumentRemoteState.Failed]) {
    if (state === raw) { return state; }
  } throw new DocumentParseFailure('远端阶段未知', '任务库');
}
function parseStoredIds(raw: string): string[] {
  if (raw.length === 0) { return []; }
  const ids: string[] = raw.split('\n');
  if (ids.length > 32 || ids.some((id: string): boolean => !documentSafeId(id))) { throw new DocumentParseFailure('清理身份列非法', '任务库'); } return ids;
}
function parseReadOriginal(rows: relationalStore.ResultSet): DocumentOriginal {
  const o: DocumentOriginal = new DocumentOriginal(); o.id = parseRowString(rows, 'id'); o.assetId = parseRowString(rows, 'asset');
  o.title = parseRowString(rows, 'title'); o.hash = parseRowString(rows, 'hash'); o.bytes = parseRowNumber(rows, 'bytes');
  o.format = parseStoredFormat(parseRowString(rows, 'format')); o.version = parseRowNumber(rows, 'version');
  const preflight: string = parseRowString(rows, 'preflight');
  if (preflight !== DocumentPreflightStatus.Passed && preflight !== DocumentPreflightStatus.Blocked) { throw new DocumentParseFailure('预检列未知', '任务库'); }
  o.preflight = preflight === DocumentPreflightStatus.Passed ? DocumentPreflightStatus.Passed : DocumentPreflightStatus.Blocked;
  o.pages = parseRowNumber(rows, 'pages'); o.preflightReason = parseRowString(rows, 'reason'); o.savedAt = parseRowNumber(rows, 'saved');
  if (!documentSafeId(o.id) || !documentSafeId(o.assetId) || !documentHashValid(o.hash) || o.bytes < 1 || o.bytes > DocumentParseBudget.originalBytes || o.version < 1 || o.title.length > 1024) { throw new DocumentParseFailure('原件行非法', '任务库'); }
  return o;
}
function parseReadGrant(rows: relationalStore.ResultSet): DocumentParseGrant {
  const g: DocumentParseGrant = new DocumentParseGrant(); g.id = parseRowString(rows, 'id'); g.originalId = parseRowString(rows, 'original');
  g.hash = parseRowString(rows, 'hash'); g.version = parseRowNumber(rows, 'version'); g.format = parseStoredFormat(parseRowString(rows, 'format'));
  g.credentialRevision = parseRowNumber(rows, 'revision'); g.policy = parseRowString(rows, 'policy'); g.parameters = parseRowString(rows, 'parameters');
  g.acknowledgement.fullFile = parseRowBool(rows, 'full_file'); g.acknowledgement.embeddedImages = parseRowBool(rows, 'images');
  g.acknowledgement.nonSensitive = parseRowBool(rows, 'nonsensitive'); g.acknowledgement.privacyUnknown = parseRowBool(rows, 'privacy_unknown');
  g.acknowledgement.freeEligible = parseRowBool(rows, 'free'); g.issuedAt = parseRowNumber(rows, 'issued'); g.revoked = parseRowBool(rows, 'revoked');
  if (!documentSafeId(g.id) || !documentSafeId(g.originalId) || !documentHashValid(g.hash) || g.version < 1) { throw new DocumentParseFailure('授权行非法', '任务库'); } return g;
}
function parseReadTask(rows: relationalStore.ResultSet): DocumentParseTask {
  const t: DocumentParseTask = new DocumentParseTask(); t.id = parseRowString(rows, 'id'); t.originalId = parseRowString(rows, 'original');
  t.dataId = parseRowString(rows, 'data_id'); t.batchId = parseRowString(rows, 'batch_id'); t.grantId = parseRowString(rows, 'grant_id');
  t.hash = parseRowString(rows, 'hash'); t.version = parseRowNumber(rows, 'version'); t.credentialRevision = parseRowNumber(rows, 'revision');
  t.stage = parseStoredStage(parseRowString(rows, 'stage')); t.checkpoint = parseStoredStage(parseRowString(rows, 'checkpoint'));
  t.remote = parseStoredRemote(parseRowString(rows, 'remote')); t.epoch = parseRowNumber(rows, 'epoch'); t.queries = parseRowNumber(rows, 'queries');
  t.windowStart = parseRowNumber(rows, 'window_start'); t.uploaded = parseRowBool(rows, 'uploaded'); t.uploadAttempted = parseRowBool(rows, 'upload_attempted');
  t.uploadLease = parseRowString(rows, 'upload_lease'); t.resultLease = parseRowString(rows, 'result_lease'); t.failure = parseRowString(rows, 'failure');
  t.extractedPages = parseRowNumber(rows, 'extracted'); t.totalPages = parseRowNumber(rows, 'total');
  if (!documentSafeId(t.id) || !documentSafeId(t.dataId) || !documentSafeId(t.originalId) || !documentSafeId(t.grantId) || t.batchId.length > 0 && !documentSafeId(t.batchId) ||
    t.uploadLease.length > 0 && !new RegExp('^lease-[a-zA-Z0-9_-]+$').test(t.uploadLease) || t.resultLease.length > 0 && !new RegExp('^lease-[a-zA-Z0-9_-]+$').test(t.resultLease) ||
    !documentHashValid(t.hash) || t.version < 1 || t.queries > 90 || t.totalPages > 200 || t.extractedPages > t.totalPages) { throw new DocumentParseFailure('任务行非法', '任务库'); }
  return t;
}
export class DocumentParseRepository implements DocumentParseRepositoryPort {
  private context: common.Context; private store: relationalStore.RdbStore | undefined = undefined;
  private tail: Promise<void> = Promise.resolve();
  constructor(context: common.Context) { this.context = context; }
  private requireStore(): relationalStore.RdbStore { if (this.store === undefined) { throw new DocumentParseFailure('任务库未打开', '持久化'); } return this.store; }
  async open(): Promise<void> {
    if (this.store !== undefined) { return; }
    const existed: boolean = await fileIo.access(`${this.context.databaseDir}/rdb/${DOCUMENT_PARSE_STORE}`) || await fileIo.access(`${this.context.databaseDir}/${DOCUMENT_PARSE_STORE}`);
    for (const path of [`${this.context.databaseDir}/rdb/${DOCUMENT_PARSE_STORE}`, `${this.context.databaseDir}/${DOCUMENT_PARSE_STORE}`]) {
      if (await fileIo.access(path)) { const stat: fileIo.Stat = await fileIo.lstat(path); if (!stat.isFile() || stat.isSymbolicLink()) { throw new DocumentParseFailure('解析库路径非法，未打开或覆盖', '持久化'); } }
    }
    const config: relationalStore.StoreConfig = { name: DOCUMENT_PARSE_STORE, securityLevel: relationalStore.SecurityLevel.S3, vector: false };
    this.store = await relationalStore.getRdbStore(this.context, config); const store: relationalStore.RdbStore = this.requireStore();
    try {
      const rows: relationalStore.ResultSet = await store.querySql("SELECT sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name");
      const ddl: string[] = []; try { while (rows.goToNextRow()) { ddl.push(rows.getString(0)); } } finally { rows.close(); }
      if (ddl.length === 0 && !existed && store.version === 0) {
        const tx: relationalStore.Transaction = await store.createTransaction();
        try {
          for (const statement of DOCUMENT_PARSE_DDL) { await tx.execute(statement); }
          await tx.execute('INSERT INTO parse_meta(id,layout,enabled,revision) VALUES(1,?,0,0)', [DOCUMENT_PARSE_LAYOUT]);
          await tx.execute('INSERT INTO remote_slot(id,task_id,data_id,batch_id,revision,state,terminal) VALUES(1,?,?,?,0,?,0)', ['', '', '', '']);
          await tx.commit(); store.version = 1;
        } catch { await tx.rollback(); throw new DocumentParseFailure('建库未完成', '持久化'); }
      } else if (store.version !== 1 || ddl.length !== 7 || ddl.some((statement: string): boolean => DOCUMENT_PARSE_DDL.indexOf(statement) < 0)) {
        throw new DocumentParseFailure('既有解析库版本或布局未知，拒绝覆盖/清库', '持久化');
      }
      const meta: relationalStore.ResultSet = await store.querySql('SELECT layout FROM parse_meta WHERE id=1');
      try { if (!meta.goToNextRow() || meta.getString(0) !== DOCUMENT_PARSE_LAYOUT || meta.goToNextRow()) { throw new DocumentParseFailure('布局标识未知', '持久化'); } }
      finally { meta.close(); }
    } catch (error) { await store.close(); this.store = undefined; if (error instanceof DocumentParseFailure) { throw error; } throw new DocumentParseFailure('解析库打开失败，资料未清理', '持久化'); }
  }
  async load(): Promise<DocumentParseSnapshot> {
    const s: DocumentParseSnapshot = new DocumentParseSnapshot(); const store: relationalStore.RdbStore = this.requireStore();
    const meta: relationalStore.ResultSet = await store.querySql('SELECT id,enabled,revision FROM parse_meta');
    try { if (!meta.goToNextRow() || parseRowNumber(meta, 'id') !== 1) { throw new DocumentParseFailure('配置行缺失', '任务库'); }
      s.config.enabled = parseRowBool(meta, 'enabled'); s.config.credentialRevision = parseRowNumber(meta, 'revision'); if (meta.goToNextRow()) { throw new DocumentParseFailure('配置行重复', '任务库'); }
    } finally { meta.close(); }
    const originals: relationalStore.ResultSet = await store.querySql('SELECT id,asset,title,hash,bytes,format,version,preflight,pages,reason,saved FROM original ORDER BY saved DESC');
    try { while (originals.goToNextRow()) { s.originals.push(parseReadOriginal(originals)); } } finally { originals.close(); }
    const grants: relationalStore.ResultSet = await store.querySql('SELECT id,original,hash,version,format,revision,policy,parameters,full_file,images,nonsensitive,privacy_unknown,free,issued,revoked FROM grant');
    try { while (grants.goToNextRow()) { s.grants.push(parseReadGrant(grants)); } } finally { grants.close(); }
    const tasks: relationalStore.ResultSet = await store.querySql('SELECT id,original,data_id,batch_id,grant_id,hash,version,revision,stage,checkpoint,remote,epoch,queries,window_start,uploaded,upload_attempted,upload_lease,result_lease,failure,extracted,total FROM task');
    try { while (tasks.goToNextRow()) { s.tasks.push(parseReadTask(tasks)); } } finally { tasks.close(); }
    const slot: relationalStore.ResultSet = await store.querySql('SELECT id,task_id,data_id,batch_id,revision,state,terminal FROM remote_slot');
    try {
      if (!slot.goToNextRow() || parseRowNumber(slot, 'id') !== 1) { throw new DocumentParseFailure('远端占用行缺失', '任务库'); }
      s.occupancy.taskId = parseRowString(slot, 'task_id'); s.occupancy.dataId = parseRowString(slot, 'data_id'); s.occupancy.batchId = parseRowString(slot, 'batch_id');
      s.occupancy.credentialRevision = parseRowNumber(slot, 'revision'); s.occupancy.lastState = parseStoredRemote(parseRowString(slot, 'state')); s.occupancy.terminalObserved = parseRowBool(slot, 'terminal');
      if (slot.goToNextRow() || s.occupancy.taskId.length > 0 && (!documentSafeId(s.occupancy.taskId) || !documentSafeId(s.occupancy.dataId)) || s.occupancy.batchId.length > 0 && !documentSafeId(s.occupancy.batchId)) { throw new DocumentParseFailure('远端占用身份非法', '任务库'); }
    } finally { slot.close(); }
    const results: relationalStore.ResultSet = await store.querySql('SELECT asset,task_id,data_id,original_hash,version,bytes,hash,received,status,complete,signature FROM result');
    try { while (results.goToNextRow()) {
      const r: DocumentParseResultEnvelope = new DocumentParseResultEnvelope(); r.assetId = parseRowString(results, 'asset'); r.taskId = parseRowString(results, 'task_id'); r.dataId = parseRowString(results, 'data_id');
      r.originalHash = parseRowString(results, 'original_hash'); r.version = parseRowNumber(results, 'version'); r.bytes = parseRowNumber(results, 'bytes'); r.hash = parseRowString(results, 'hash');
      r.receivedAt = parseRowNumber(results, 'received'); r.status = parseRowString(results, 'status'); r.completeTransport = parseRowBool(results, 'complete'); r.signature = parseRowBool(results, 'signature');
      if (!documentSafeId(r.assetId) || !documentSafeId(r.taskId) || !documentSafeId(r.dataId) || !documentHashValid(r.hash) || !documentHashValid(r.originalHash) || r.version < 1 || r.bytes < 1 || r.bytes > DocumentParseBudget.resultBytes || r.status !== 'UNVALIDATED' || !r.completeTransport || !r.signature) { throw new DocumentParseFailure('结果行非法', '任务库'); } s.results.push(r);
    } } finally { results.close(); }
    const cleanup: relationalStore.ResultSet = await store.querySql('SELECT id,assets,leases,original_bytes,result_bytes,failure FROM cleanup');
    try { while (cleanup.goToNextRow()) {
      const c: DocumentParseCleanup = new DocumentParseCleanup(); c.id = parseRowString(cleanup, 'id'); c.assets = parseStoredIds(parseRowString(cleanup, 'assets')); c.leases = parseStoredIds(parseRowString(cleanup, 'leases'));
      c.originalBytes = parseRowNumber(cleanup, 'original_bytes'); c.resultBytes = parseRowNumber(cleanup, 'result_bytes'); c.failure = parseRowString(cleanup, 'failure');
      if (!documentSafeId(c.id)) { throw new DocumentParseFailure('清理行非法', '任务库'); } s.cleanup.push(c);
    } } finally { cleanup.close(); }
    const originalIds: string[] = s.originals.map((o: DocumentOriginal): string => o.id);
    if (s.tasks.some((t: DocumentParseTask): boolean => originalIds.indexOf(t.originalId) < 0 || !s.grants.some((g: DocumentParseGrant): boolean => g.id === t.grantId && g.originalId === t.originalId && g.hash === t.hash && g.version === t.version)) ||
      s.results.some((r: DocumentParseResultEnvelope): boolean => !s.tasks.some((t: DocumentParseTask): boolean => t.id === r.taskId && t.hash === r.originalHash && t.version === r.version && t.dataId === r.dataId))) {
      throw new DocumentParseFailure('任务库关联缺失，拒绝空库修复', '任务库');
    }
    return s;
  }
  async save(snapshot: DocumentParseSnapshot): Promise<void> {
    const s: DocumentParseSnapshot = documentCopySnapshot(snapshot);
    const operation: Promise<void> = this.tail.then(async (): Promise<void> => {
      const tx: relationalStore.Transaction = await this.requireStore().createTransaction();
      try {
        await tx.execute('UPDATE parse_meta SET enabled=?,revision=? WHERE id=1', [s.config.enabled ? 1 : 0, s.config.credentialRevision]);
        for (const table of ['original', 'grant', 'task', 'result', 'cleanup']) { await tx.execute(`DELETE FROM ${table}`); }
        for (const o of s.originals) { await tx.execute('INSERT INTO original(id,asset,title,hash,bytes,format,version,preflight,pages,reason,saved) VALUES(?,?,?,?,?,?,?,?,?,?,?)', [o.id,o.assetId,o.title,o.hash,o.bytes,o.format,o.version,o.preflight,o.pages,o.preflightReason,o.savedAt]); }
        for (const g of s.grants) { await tx.execute('INSERT INTO grant(id,original,hash,version,format,revision,policy,parameters,full_file,images,nonsensitive,privacy_unknown,free,issued,revoked) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', [g.id,g.originalId,g.hash,g.version,g.format,g.credentialRevision,g.policy,g.parameters,g.acknowledgement.fullFile ? 1 : 0,g.acknowledgement.embeddedImages ? 1 : 0,g.acknowledgement.nonSensitive ? 1 : 0,g.acknowledgement.privacyUnknown ? 1 : 0,g.acknowledgement.freeEligible ? 1 : 0,g.issuedAt,g.revoked ? 1 : 0]); }
        for (const t of s.tasks) { await tx.execute('INSERT INTO task(id,original,data_id,batch_id,grant_id,hash,version,revision,stage,checkpoint,remote,epoch,queries,window_start,uploaded,upload_attempted,upload_lease,result_lease,failure,extracted,total) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', [t.id,t.originalId,t.dataId,t.batchId,t.grantId,t.hash,t.version,t.credentialRevision,t.stage,t.checkpoint,t.remote,t.epoch,t.queries,t.windowStart,t.uploaded ? 1 : 0,t.uploadAttempted ? 1 : 0,t.uploadLease,t.resultLease,t.failure,t.extractedPages,t.totalPages]); }
        const o: DocumentRemoteOccupancy = s.occupancy;
        await tx.execute('UPDATE remote_slot SET task_id=?,data_id=?,batch_id=?,revision=?,state=?,terminal=? WHERE id=1', [o.taskId,o.dataId,o.batchId,o.credentialRevision,o.lastState,o.terminalObserved ? 1 : 0]);
        for (const r of s.results) { await tx.execute('INSERT INTO result(asset,task_id,data_id,original_hash,version,bytes,hash,received,status,complete,signature) VALUES(?,?,?,?,?,?,?,?,?,?,?)', [r.assetId,r.taskId,r.dataId,r.originalHash,r.version,r.bytes,r.hash,r.receivedAt,r.status,r.completeTransport ? 1 : 0,r.signature ? 1 : 0]); }
        for (const c of s.cleanup) { await tx.execute('INSERT INTO cleanup(id,assets,leases,original_bytes,result_bytes,failure) VALUES(?,?,?,?,?,?)', [c.id,c.assets.join('\n'),c.leases.join('\n'),c.originalBytes,c.resultBytes,c.failure]); }
        await tx.commit();
      } catch { await tx.rollback(); throw new DocumentParseFailure('任务检查点写入失败', '持久化'); }
    });
    this.tail = operation.then((): void => {}, (_error: Error): void => {}); await operation;
  }
  async close(): Promise<void> { await this.tail; if (this.store !== undefined) { await this.store.close(); this.store = undefined; } }
}
