import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { DocumentParseRepositoryPort } from '../domain/DocumentParsePorts';
import {
  DocumentParseSnapshot, DocumentOriginal, DocumentParseGrant, DocumentParseTask, DocumentParseResultEnvelope,
  DocumentParseCleanup, DocumentParseFailure, DocumentParseFormat, DocumentPreflightStatus, DocumentParseStage,
  DocumentRemoteState, DocumentParseBudget, documentCopySnapshot, DocumentRemoteOccupancy, DocumentImageEvidence, ImageParsePermit, ParseFailureKind, DocxParsePermit
} from '../domain/DocumentParseModels';
import { documentSafeId, documentHashValid } from '../pipeline/DocumentParsePolicy';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';

export const DOCUMENT_PARSE_STORE: string = 'shuvi_parse_stage_v1.db';
const DOCUMENT_PARSE_LAYOUT: string = 'parse-stage-explicit-columns-v1';
const DOCUMENT_TRANSFER_LAYOUT: string = 'parse-stage-transfer-additive-v2';
const DOCUMENT_SLOT_RETIRE_LAYOUT: string = 'parse-stage-slot-retire-additive-v3';
const DOCUMENT_IMAGE_LAYOUT: string = 'parse-stage-image-additive-v4';
const DOCUMENT_HAPPY_LAYOUT: string = 'parse-stage-image-permit-failure-v5';
const DOCUMENT_DOCX_LAYOUT: string = 'parse-stage-docx-permit-v6';
const DOCUMENT_DOCX_PERMIT_DDL: string = 'CREATE TABLE docx_parse_permit (original TEXT PRIMARY KEY,hash TEXT NOT NULL,version INTEGER NOT NULL,format TEXT NOT NULL,revision INTEGER NOT NULL,parameters TEXT NOT NULL,full_file INTEGER NOT NULL,free INTEGER NOT NULL,task_id TEXT NOT NULL,allocation INTEGER NOT NULL,put_count INTEGER NOT NULL,query_count INTEGER NOT NULL,download INTEGER NOT NULL,stopped_reason TEXT NOT NULL)';
const DOCUMENT_PERMIT_DDL: string = 'CREATE TABLE image_parse_permit (original TEXT PRIMARY KEY,hash TEXT NOT NULL,version INTEGER NOT NULL,format TEXT NOT NULL,input_id TEXT NOT NULL,full_file INTEGER NOT NULL,free INTEGER NOT NULL,task_id TEXT NOT NULL,allocation INTEGER NOT NULL,put_count INTEGER NOT NULL,query_count INTEGER NOT NULL,download INTEGER NOT NULL,stopped_reason TEXT NOT NULL)';
const DOCUMENT_FAILURE_DDL: string = 'CREATE TABLE task_failure_detail (task_id TEXT PRIMARY KEY,kind TEXT NOT NULL,stage TEXT NOT NULL,http INTEGER NOT NULL,sdk TEXT NOT NULL,provider TEXT NOT NULL,reason TEXT NOT NULL,retry_after TEXT NOT NULL,uncertain INTEGER NOT NULL)';
const DOCUMENT_IMAGE_DDL: string = 'CREATE TABLE image_evidence (original TEXT PRIMARY KEY,asset TEXT NOT NULL,hash TEXT NOT NULL,version INTEGER NOT NULL,width INTEGER NOT NULL,height INTEGER NOT NULL,orientation INTEGER NOT NULL,orientation_evidence TEXT NOT NULL,frames INTEGER NOT NULL,static INTEGER NOT NULL,sdk INTEGER NOT NULL,mime TEXT NOT NULL,variant TEXT NOT NULL,alpha INTEGER NOT NULL)';
const DOCUMENT_SLOT_RETIRE_ALTER: string = 'ALTER TABLE remote_slot ADD COLUMN retired INTEGER DEFAULT 0';
const DOCUMENT_TRANSFER_DDL: string = 'CREATE TABLE task_transfer (task_id TEXT PRIMARY KEY,recovery_used INTEGER,request_started INTEGER,upload_bytes INTEGER,download_bytes INTEGER,download_total INTEGER,last_query INTEGER,last_action TEXT,failure_stage TEXT,failure_code TEXT)';
function documentSlotRetireDDL(statement: string): boolean {
  return statement.startsWith('CREATE TABLE remote_slot (') && new RegExp(',\\s*retired\\s+INTEGER\\s+DEFAULT\\s+0\\s*\\)$').test(statement);
}
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
  for (const f of [DocumentParseFormat.Pdf, DocumentParseFormat.Docx, DocumentParseFormat.Pptx, DocumentParseFormat.Xlsx, DocumentParseFormat.Jpeg, DocumentParseFormat.Png, DocumentParseFormat.Webp]) { if (raw === f) { return f; } }
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
    !documentHashValid(t.hash) || t.version < 1 || t.totalPages > 200 || t.extractedPages > t.totalPages) { throw new DocumentParseFailure('任务行非法', '任务库'); }
  return t;
}
export class DocumentParseRepository implements DocumentParseRepositoryPort {
  private context: common.Context; private store: relationalStore.RdbStore | undefined = undefined;
  private tail: Promise<void> = Promise.resolve();
  private storeName: string;
  constructor(context: common.Context, scope: KnowledgeStorageScope = KnowledgeStorageScope.production()) { this.context = context; this.storeName = scope.testing ? `shuvi_r2_parse_${scope.key}.db` : DOCUMENT_PARSE_STORE; }
  private requireStore(): relationalStore.RdbStore { if (this.store === undefined) { throw new DocumentParseFailure('任务库未打开', '持久化'); } return this.store; }
  async open(): Promise<void> {
    if (this.store !== undefined) { return; }
    const existed: boolean = await fileIo.access(`${this.context.databaseDir}/rdb/${this.storeName}`) || await fileIo.access(`${this.context.databaseDir}/${this.storeName}`);
    for (const path of [`${this.context.databaseDir}/rdb/${this.storeName}`, `${this.context.databaseDir}/${this.storeName}`]) {
      if (await fileIo.access(path)) { const stat: fileIo.Stat = await fileIo.lstat(path); if (!stat.isFile() || stat.isSymbolicLink()) { throw new DocumentParseFailure('解析库路径非法，未打开或覆盖', '持久化'); } }
    }
    const config: relationalStore.StoreConfig = { name: this.storeName, securityLevel: relationalStore.SecurityLevel.S3, vector: false };
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
      } else {
        const oldLayout: boolean = store.version === 1 && ddl.length === 7 && ddl.every((statement: string): boolean => DOCUMENT_PARSE_DDL.indexOf(statement) >= 0);
        const extendedLayout: boolean = (store.version === 1 || store.version === 2) && ddl.length === 8 && ddl.every((statement: string): boolean => DOCUMENT_PARSE_DDL.indexOf(statement) >= 0 || statement === DOCUMENT_TRANSFER_DDL);
        const retireLayout: boolean = (store.version === 2 || store.version === 3) && ddl.length === 8 && ddl.every((statement: string): boolean => DOCUMENT_PARSE_DDL.indexOf(statement) >= 0 || statement === DOCUMENT_TRANSFER_DDL || documentSlotRetireDDL(statement));
        const imageLayout: boolean = (store.version === 3 || store.version === 4) && ddl.length === 9 && ddl.every((statement: string): boolean => DOCUMENT_PARSE_DDL.indexOf(statement) >= 0 || statement === DOCUMENT_TRANSFER_DDL || statement === DOCUMENT_IMAGE_DDL || documentSlotRetireDDL(statement));
        const happyLayout: boolean = (store.version === 4 || store.version === 5) && ddl.length === 11 && ddl.every((statement: string): boolean => DOCUMENT_PARSE_DDL.indexOf(statement) >= 0 || statement === DOCUMENT_TRANSFER_DDL || statement === DOCUMENT_IMAGE_DDL || statement === DOCUMENT_PERMIT_DDL || statement === DOCUMENT_FAILURE_DDL || documentSlotRetireDDL(statement));
        const docxLayout: boolean = (store.version === 5 || store.version === 6) && ddl.length === 12 && ddl.every((statement: string): boolean => DOCUMENT_PARSE_DDL.indexOf(statement) >= 0 || statement === DOCUMENT_TRANSFER_DDL || statement === DOCUMENT_IMAGE_DDL || statement === DOCUMENT_PERMIT_DDL || statement === DOCUMENT_FAILURE_DDL || statement === DOCUMENT_DOCX_PERMIT_DDL || documentSlotRetireDDL(statement));
        if (!oldLayout && !extendedLayout && !retireLayout && !imageLayout && !happyLayout && !docxLayout) { throw new DocumentParseFailure('既有解析库版本或布局未知，拒绝覆盖/清库', '持久化'); }
      }
      const meta: relationalStore.ResultSet = await store.querySql('SELECT layout FROM parse_meta WHERE id=1');
      let layout: string = '';
      try { if (!meta.goToNextRow()) { throw new DocumentParseFailure('布局标识缺失', '持久化'); } layout = meta.getString(0); if (meta.goToNextRow()) { throw new DocumentParseFailure('布局标识重复', '持久化'); } }
      finally { meta.close(); }
      if (layout === DOCUMENT_PARSE_LAYOUT && store.version === 1 && ddl.length <= 7) {
        const migration: relationalStore.Transaction = await store.createTransaction();
        try {
          await migration.execute(DOCUMENT_TRANSFER_DDL);
          await migration.execute("INSERT INTO task_transfer(task_id,recovery_used,request_started,upload_bytes,download_bytes,download_total,last_query,last_action,failure_stage,failure_code) SELECT id,0,0,0,0,0,0,'旧记录：实际PUT是否发出未知','','' FROM task");
          await migration.execute('UPDATE parse_meta SET layout=? WHERE id=1', [DOCUMENT_TRANSFER_LAYOUT]);
          await migration.commit(); layout = DOCUMENT_TRANSFER_LAYOUT;
        } catch { await migration.rollback(); throw new DocumentParseFailure('增量迁移未完成，旧库未清空', '持久化'); }
      }
      if (layout === DOCUMENT_TRANSFER_LAYOUT) {
        const migration: relationalStore.Transaction = await store.createTransaction();
        try {
          await migration.execute(DOCUMENT_SLOT_RETIRE_ALTER);
          await migration.execute('UPDATE parse_meta SET layout=? WHERE id=1', [DOCUMENT_SLOT_RETIRE_LAYOUT]);
          await migration.commit(); layout = DOCUMENT_SLOT_RETIRE_LAYOUT;
        } catch { await migration.rollback(); throw new DocumentParseFailure('停止跟踪迁移未完成，旧库未清空', '持久化'); }
      }
      if (layout === DOCUMENT_SLOT_RETIRE_LAYOUT) {
        const migration: relationalStore.Transaction = await store.createTransaction();
        try { await migration.execute(DOCUMENT_IMAGE_DDL); await migration.execute('UPDATE parse_meta SET layout=? WHERE id=1',[DOCUMENT_IMAGE_LAYOUT]); await migration.commit(); layout = DOCUMENT_IMAGE_LAYOUT; }
        catch { await migration.rollback(); throw new DocumentParseFailure('图片证据迁移未完成，旧库未清空', '持久化'); }
      }
      if (layout === DOCUMENT_IMAGE_LAYOUT) {
        const migration: relationalStore.Transaction = await store.createTransaction();
        try { await migration.execute(DOCUMENT_PERMIT_DDL); await migration.execute(DOCUMENT_FAILURE_DDL); await migration.execute('UPDATE parse_meta SET layout=? WHERE id=1',[DOCUMENT_HAPPY_LAYOUT]); await migration.commit(); layout = DOCUMENT_HAPPY_LAYOUT; }
        catch { await migration.rollback(); throw new DocumentParseFailure('图片许可迁移失败，旧库保留','持久化'); }
      }
      if (layout === DOCUMENT_HAPPY_LAYOUT) {
        const migration: relationalStore.Transaction = await store.createTransaction();
        try { await migration.execute(DOCUMENT_DOCX_PERMIT_DDL); await migration.execute('UPDATE parse_meta SET layout=? WHERE id=1',[DOCUMENT_DOCX_LAYOUT]); await migration.commit(); layout = DOCUMENT_DOCX_LAYOUT; }
        catch { await migration.rollback(); throw new DocumentParseFailure('DOCX许可增量迁移失败，旧库保留','持久化'); }
      }
      if (layout !== DOCUMENT_DOCX_LAYOUT) { throw new DocumentParseFailure('布局标识未知', '持久化'); }
      try { const probe: relationalStore.ResultSet = await store.querySql('SELECT retired FROM remote_slot WHERE id=1'); probe.close(); }
      catch { throw new DocumentParseFailure('停止跟踪字段缺失，拒绝旧布局冒用', '持久化'); }
      // Version finalization is restart-safe after a committed migration. No existing table or asset is replaced.
      store.version = 6;
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
    const transfers: relationalStore.ResultSet = await store.querySql('SELECT task_id,recovery_used,request_started,upload_bytes,download_bytes,download_total,last_query,last_action,failure_stage,failure_code FROM task_transfer');
    const transferIds: string[] = [];
    try { while (transfers.goToNextRow()) {
      const id: string = parseRowString(transfers, 'task_id'); const t: DocumentParseTask | undefined = s.tasks.find((task: DocumentParseTask): boolean => task.id === id);
      if (t === undefined || transferIds.indexOf(id) >= 0) { throw new DocumentParseFailure('传输记录关联非法', '任务库'); } transferIds.push(id);
      t.recoveryUploadUsed = parseRowBool(transfers, 'recovery_used'); t.uploadRequestStarted = parseRowBool(transfers, 'request_started');
      t.uploadBytes = parseRowNumber(transfers, 'upload_bytes'); t.downloadBytes = parseRowNumber(transfers, 'download_bytes'); t.downloadTotal = parseRowNumber(transfers, 'download_total');
      t.lastQueryAt = parseRowNumber(transfers, 'last_query'); t.lastAction = parseRowString(transfers, 'last_action');
      t.failureStage = parseRowString(transfers, 'failure_stage'); t.failureCode = parseRowString(transfers, 'failure_code');
      if (t.uploadBytes > DocumentParseBudget.originalBytes || t.downloadBytes > DocumentParseBudget.resultBytes || t.downloadTotal > DocumentParseBudget.resultBytes ||
        t.lastAction.length > 300 || t.failureStage.length > 100 || !new RegExp('^[A-Za-z0-9_.-]{0,64}$').test(t.failureCode)) { throw new DocumentParseFailure('传输记录非法', '任务库'); }
    } } finally { transfers.close(); }
    if (transferIds.length !== s.tasks.length) { throw new DocumentParseFailure('任务传输记录缺失，拒绝重置', '任务库'); }
    const slot: relationalStore.ResultSet = await store.querySql('SELECT id,task_id,data_id,batch_id,revision,state,terminal,retired FROM remote_slot');
    try {
      if (!slot.goToNextRow() || parseRowNumber(slot, 'id') !== 1) { throw new DocumentParseFailure('远端占用行缺失', '任务库'); }
      s.occupancy.taskId = parseRowString(slot, 'task_id'); s.occupancy.dataId = parseRowString(slot, 'data_id'); s.occupancy.batchId = parseRowString(slot, 'batch_id');
      s.occupancy.credentialRevision = parseRowNumber(slot, 'revision'); s.occupancy.lastState = parseStoredRemote(parseRowString(slot, 'state')); s.occupancy.terminalObserved = parseRowBool(slot, 'terminal');
      s.occupancy.retired = parseRowBool(slot, 'retired');
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
    const evidence: relationalStore.ResultSet = await store.querySql('SELECT original,asset,hash,version,width,height,orientation,orientation_evidence,frames,static,sdk,mime,variant,alpha FROM image_evidence ORDER BY original');
    try { while (evidence.goToNextRow()) {
      const e: DocumentImageEvidence = new DocumentImageEvidence(); e.originalId = parseRowString(evidence,'original'); e.assetId = parseRowString(evidence,'asset'); e.hash = parseRowString(evidence,'hash'); e.version = parseRowNumber(evidence,'version');
      e.width = parseRowNumber(evidence,'width'); e.height = parseRowNumber(evidence,'height'); e.orientation = parseRowNumber(evidence,'orientation'); e.orientationEvidence = parseRowString(evidence,'orientation_evidence');
      e.frames = parseRowNumber(evidence,'frames'); e.staticContainer = parseRowBool(evidence,'static'); e.sdkVerified = parseRowBool(evidence,'sdk'); e.mime = parseRowString(evidence,'mime'); e.variant = parseRowString(evidence,'variant'); e.alpha = parseRowBool(evidence,'alpha');
      const original: DocumentOriginal | undefined = s.originals.find((o: DocumentOriginal): boolean => o.id === e.originalId && o.assetId === e.assetId && o.hash === e.hash && o.version === e.version);
      if (original === undefined || [DocumentParseFormat.Jpeg,DocumentParseFormat.Png,DocumentParseFormat.Webp].indexOf(original.format) < 0 || e.width < 1 || e.height < 1 || e.width*e.height > 20000000 || e.orientation > 8 || e.frames > 1 || !e.staticContainer || ['image/jpeg','image/png','image/webp'].indexOf(e.mime) < 0) { throw new DocumentParseFailure('图片证据关联或预算非法','任务库'); } s.imageEvidence.push(e);
    } } finally { evidence.close(); }
    if (s.tasks.some((t: DocumentParseTask): boolean => originalIds.indexOf(t.originalId) < 0 || !s.grants.some((g: DocumentParseGrant): boolean => g.id === t.grantId && g.originalId === t.originalId && g.hash === t.hash && g.version === t.version)) ||
      s.results.some((r: DocumentParseResultEnvelope): boolean => !s.tasks.some((t: DocumentParseTask): boolean => t.id === r.taskId && t.hash === r.originalHash && t.version === r.version && t.dataId === r.dataId))) {
      throw new DocumentParseFailure('任务库关联缺失，拒绝空库修复', '任务库');
    }
    const permits: relationalStore.ResultSet = await store.querySql('SELECT * FROM image_parse_permit');
    try { while (permits.goToNextRow()) {
      const p: ImageParsePermit = new ImageParsePermit(); p.originalId = parseRowString(permits,'original'); p.hash = parseRowString(permits,'hash'); p.version = parseRowNumber(permits,'version'); p.actualFormat = parseStoredFormat(parseRowString(permits,'format'));
      p.testInputId = parseRowString(permits,'input_id'); p.fullFile = parseRowBool(permits,'full_file'); p.freeEligible = parseRowBool(permits,'free'); p.taskId = parseRowString(permits,'task_id');
      p.usage.allocation = parseRowNumber(permits,'allocation'); p.usage.put = parseRowNumber(permits,'put_count'); p.usage.query = parseRowNumber(permits,'query_count'); p.usage.download = parseRowNumber(permits,'download');
      p.stoppedReason = parseRowString(permits,'stopped_reason'); if (p.stoppedReason.length > 300 || s.imagePermits.some((prior: ImageParsePermit): boolean => prior.testInputId === p.testInputId)) { throw new DocumentParseFailure('图片许可重复或停止原因非法','任务库'); }
      if (!documentHashValid(p.hash) || !documentSafeId(p.originalId) || !(new RegExp('^U(0[1-9]|10|11)$').test(p.testInputId) || p.testInputId === 'image-'+p.hash) || [DocumentParseFormat.Jpeg,DocumentParseFormat.Png,DocumentParseFormat.Webp].indexOf(p.actualFormat) < 0 || p.version < 1 || p.usage.allocation > 1 || p.usage.put > (p.testInputId.startsWith('image-')?2:1) || p.usage.query > 90 || p.usage.download > (p.testInputId.startsWith('image-')?3:1)) { throw new DocumentParseFailure('图片许可账本非法','任务库'); }
      const task = s.tasks.find((t: DocumentParseTask): boolean => t.id === p.taskId);
      if (task !== undefined) { task.usage = p.usage; } s.imagePermits.push(p);
    } } finally { permits.close(); }
    const docxPermits: relationalStore.ResultSet = await store.querySql('SELECT * FROM docx_parse_permit');
    try { while (docxPermits.goToNextRow()) {
      const p: DocxParsePermit = new DocxParsePermit(); p.originalId = parseRowString(docxPermits,'original'); p.hash = parseRowString(docxPermits,'hash');
      p.version = parseRowNumber(docxPermits,'version'); p.actualFormat = parseStoredFormat(parseRowString(docxPermits,'format'));
      p.credentialRevision = parseRowNumber(docxPermits,'revision'); p.parameters = parseRowString(docxPermits,'parameters');
      p.fullFile = parseRowBool(docxPermits,'full_file'); p.freeEligible = parseRowBool(docxPermits,'free'); p.taskId = parseRowString(docxPermits,'task_id');
      p.usage.allocation = parseRowNumber(docxPermits,'allocation'); p.usage.put = parseRowNumber(docxPermits,'put_count'); p.usage.query = parseRowNumber(docxPermits,'query_count'); p.usage.download = parseRowNumber(docxPermits,'download'); p.stoppedReason = parseRowString(docxPermits,'stopped_reason');
      if (!documentSafeId(p.originalId) || !documentHashValid(p.hash) || p.version < 1 || p.actualFormat !== DocumentParseFormat.Docx || p.parameters !== DocxParsePermit.parameters || p.stoppedReason.length > 300 || p.taskId.length > 0 && !documentSafeId(p.taskId) || p.usage.allocation > 1 || p.usage.put > 2 || p.usage.query > 90 || p.usage.download > 3 || s.docxPermits.some((prior: DocxParsePermit): boolean => prior.originalId === p.originalId)) { throw new DocumentParseFailure('DOCX许可账本非法','任务库'); }
      const task: DocumentParseTask | undefined = s.tasks.find((t: DocumentParseTask): boolean => t.id === p.taskId);
      if (task !== undefined) {
        if (task.originalId !== p.originalId || task.hash !== p.hash || task.version !== p.version || task.credentialRevision !== p.credentialRevision) { throw new DocumentParseFailure('DOCX许可任务关联非法','任务库'); }
        task.usage = p.usage;
      }
      s.docxPermits.push(p);
    } } finally { docxPermits.close(); }
    const failures: relationalStore.ResultSet = await store.querySql('SELECT * FROM task_failure_detail');
    try { while (failures.goToNextRow()) {
      const task = s.tasks.find((t: DocumentParseTask): boolean => t.id === parseRowString(failures,'task_id'));
      if (task === undefined) { throw new DocumentParseFailure('错误关联缺失','任务库'); }
      const kind: string = parseRowString(failures,'kind'); const kinds: ParseFailureKind[] = [ParseFailureKind.Network,ParseFailureKind.Format,ParseFailureKind.Auth,ParseFailureKind.Quota,ParseFailureKind.RateLimit,ParseFailureKind.Service,ParseFailureKind.Artifact,ParseFailureKind.Unknown];
      const matched = kinds.find((k: ParseFailureKind): boolean => k === kind); if (matched === undefined) { throw new DocumentParseFailure('错误类别未知','任务库'); }
      task.failureDetail.kind = matched; task.failureDetail.stage = parseRowString(failures,'stage'); task.failureDetail.httpStatus = parseRowNumber(failures,'http');
      task.failureDetail.sdkCode = parseRowString(failures,'sdk'); task.failureDetail.providerCode = parseRowString(failures,'provider'); task.failureDetail.sanitizedReason = parseRowString(failures,'reason'); task.failureDetail.retryAfter = parseRowString(failures,'retry_after'); task.failureDetail.outcomeUnknown = parseRowBool(failures,'uncertain');
      if (task.failureDetail.sanitizedReason.length > 300 || task.failureDetail.stage.length > 100 || task.failureDetail.httpStatus > 599 || !new RegExp('^[A-Za-z0-9_.-]{0,64}$').test(task.failureDetail.providerCode) || !new RegExp('^[A-Za-z0-9_.-]{0,64}$').test(task.failureDetail.sdkCode) || task.failureDetail.retryAfter.length > 80) { throw new DocumentParseFailure('错误详情非法','任务库'); }
    } } finally { failures.close(); }
    return s;
  }
  async save(snapshot: DocumentParseSnapshot): Promise<void> {
    const s: DocumentParseSnapshot = documentCopySnapshot(snapshot);
    const operation: Promise<void> = this.tail.then(async (): Promise<void> => {
      const tx: relationalStore.Transaction = await this.requireStore().createTransaction();
      try {
        await tx.execute('UPDATE parse_meta SET enabled=?,revision=? WHERE id=1', [s.config.enabled ? 1 : 0, s.config.credentialRevision]);
        for (const table of ['original', 'grant', 'task', 'task_transfer', 'result', 'cleanup', 'image_evidence', 'image_parse_permit', 'task_failure_detail', 'docx_parse_permit']) { await tx.execute(`DELETE FROM ${table}`); }
        for (const p of s.docxPermits) { await tx.execute('INSERT INTO docx_parse_permit VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[p.originalId,p.hash,p.version,p.actualFormat,p.credentialRevision,p.parameters,p.fullFile ? 1 : 0,p.freeEligible ? 1 : 0,p.taskId,p.usage.allocation,p.usage.put,p.usage.query,p.usage.download,p.stoppedReason]); }
        for (const p of s.imagePermits) { await tx.execute('INSERT INTO image_parse_permit VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',[p.originalId,p.hash,p.version,p.actualFormat,p.testInputId,p.fullFile ? 1 : 0,p.freeEligible ? 1 : 0,p.taskId,p.usage.allocation,p.usage.put,p.usage.query,p.usage.download,p.stoppedReason]); }
        for (const task of s.tasks) { const d = task.failureDetail; await tx.execute('INSERT INTO task_failure_detail VALUES(?,?,?,?,?,?,?,?,?)',[task.id,d.kind,d.stage,d.httpStatus,d.sdkCode,d.providerCode,d.sanitizedReason,d.retryAfter,d.outcomeUnknown ? 1 : 0]); }
        for (const e of s.imageEvidence) { await tx.execute('INSERT INTO image_evidence VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[e.originalId,e.assetId,e.hash,e.version,e.width,e.height,e.orientation,e.orientationEvidence,e.frames,e.staticContainer ? 1 : 0,e.sdkVerified ? 1 : 0,e.mime,e.variant,e.alpha ? 1 : 0]); }
        for (const o of s.originals) { await tx.execute('INSERT INTO original(id,asset,title,hash,bytes,format,version,preflight,pages,reason,saved) VALUES(?,?,?,?,?,?,?,?,?,?,?)', [o.id,o.assetId,o.title,o.hash,o.bytes,o.format,o.version,o.preflight,o.pages,o.preflightReason,o.savedAt]); }
        for (const g of s.grants) { await tx.execute('INSERT INTO grant(id,original,hash,version,format,revision,policy,parameters,full_file,images,nonsensitive,privacy_unknown,free,issued,revoked) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', [g.id,g.originalId,g.hash,g.version,g.format,g.credentialRevision,g.policy,g.parameters,g.acknowledgement.fullFile ? 1 : 0,g.acknowledgement.embeddedImages ? 1 : 0,g.acknowledgement.nonSensitive ? 1 : 0,g.acknowledgement.privacyUnknown ? 1 : 0,g.acknowledgement.freeEligible ? 1 : 0,g.issuedAt,g.revoked ? 1 : 0]); }
        for (const t of s.tasks) { await tx.execute('INSERT INTO task(id,original,data_id,batch_id,grant_id,hash,version,revision,stage,checkpoint,remote,epoch,queries,window_start,uploaded,upload_attempted,upload_lease,result_lease,failure,extracted,total) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', [t.id,t.originalId,t.dataId,t.batchId,t.grantId,t.hash,t.version,t.credentialRevision,t.stage,t.checkpoint,t.remote,t.epoch,t.queries,t.windowStart,t.uploaded ? 1 : 0,t.uploadAttempted ? 1 : 0,t.uploadLease,t.resultLease,t.failure,t.extractedPages,t.totalPages]); }
        for (const t of s.tasks) { await tx.execute('INSERT INTO task_transfer(task_id,recovery_used,request_started,upload_bytes,download_bytes,download_total,last_query,last_action,failure_stage,failure_code) VALUES(?,?,?,?,?,?,?,?,?,?)', [t.id,t.recoveryUploadUsed ? 1 : 0,t.uploadRequestStarted ? 1 : 0,t.uploadBytes,t.downloadBytes,t.downloadTotal,t.lastQueryAt,t.lastAction,t.failureStage,t.failureCode]); }
        const o: DocumentRemoteOccupancy = s.occupancy;
        await tx.execute('UPDATE remote_slot SET task_id=?,data_id=?,batch_id=?,revision=?,state=?,terminal=?,retired=? WHERE id=1', [o.taskId,o.dataId,o.batchId,o.credentialRevision,o.lastState,o.terminalObserved ? 1 : 0,o.retired ? 1 : 0]);
        for (const r of s.results) { await tx.execute('INSERT INTO result(asset,task_id,data_id,original_hash,version,bytes,hash,received,status,complete,signature) VALUES(?,?,?,?,?,?,?,?,?,?,?)', [r.assetId,r.taskId,r.dataId,r.originalHash,r.version,r.bytes,r.hash,r.receivedAt,r.status,r.completeTransport ? 1 : 0,r.signature ? 1 : 0]); }
        for (const c of s.cleanup) { await tx.execute('INSERT INTO cleanup(id,assets,leases,original_bytes,result_bytes,failure) VALUES(?,?,?,?,?,?)', [c.id,c.assets.join('\n'),c.leases.join('\n'),c.originalBytes,c.resultBytes,c.failure]); }
        await tx.commit();
      } catch { await tx.rollback(); throw new DocumentParseFailure('任务检查点写入失败', '持久化'); }
    });
    this.tail = operation.then((): void => {}, (_error: Error): void => {}); await operation;
  }
  async close(): Promise<void> { await this.tail; if (this.store !== undefined) { await this.store.close(); this.store = undefined; } }
}
