import { TextKnowledgeService } from '../main/ets/knowledge/application/TextKnowledgeService';
import { TextSelectionPort, TextAssetPort, TextProcessingPort, TextRepositoryPort } from '../main/ets/knowledge/domain/TextKnowledgePorts';
import {
  TextSelection, TextSelectedFile, TextOriginal, TextCancellation, TextSnapshot, TextDocument, TextProcessed,
  TextJob, TextChunk, TextCleanup, TextUsage, TextQueryInput, TextSearchResult, TextHistory,
  TextChannel, TextStage, TextHit, TextReferenceState, TextNormalized
} from '../main/ets/knowledge/domain/TextKnowledgeModels';
import { processText, structuredChunks, encodeSnapshot, decodeSnapshot } from '../main/ets/knowledge/pipeline/StructuredChunker';
import { encodeTextUtf8, normalizeText } from '../main/ets/knowledge/pipeline/TextNormalizer';
import { textKeywordScore, compareTextHits, prepareTextQuery } from '../main/ets/knowledge/pipeline/QueryPreparation';

export interface TextServiceTest { name: string; run: () => Promise<void>; }
function serviceCheck(ok: boolean, message: string): void { if (!ok) { throw new Error(message); } }
export class TextTestAssets implements TextSelectionPort, TextAssetPort {
  selected: TextSelection = new TextSelection();
  bytes: Uint8Array = encodeTextUtf8('真实关键词证据\n第二行');
  originals: Map<string, Uint8Array> = new Map<string, Uint8Array>();
  snapshots: Map<string, TextSnapshot> = new Map<string, TextSnapshot>();
  failRemove: boolean = false;
  constructor() {
    const file: TextSelectedFile = new TextSelectedFile(); file.name = 'authorized.txt'; file.bytes = this.bytes.length;
    file.uri = 'host-selected-only'; this.selected.files = [file];
  }
  async select(): Promise<TextSelection> { return this.selected; }
  async saveOriginal(file: TextSelectedFile, assetId: string, cancel: TextCancellation): Promise<TextOriginal> {
    cancel.check(); const original: TextOriginal = new TextOriginal();
    original.assetId = assetId; original.hash = Array.from(this.bytes).join('-'); original.bytes = this.bytes.length;
    this.originals.set(assetId, this.bytes.slice()); return original;
  }
  async readOriginal(original: TextOriginal, cancel: TextCancellation): Promise<Uint8Array> {
    cancel.check(); const bytes: Uint8Array | undefined = this.originals.get(original.assetId);
    if (bytes === undefined) { throw new Error('missing test original'); } return bytes.slice();
  }
  async saveSnapshot(snapshot: TextSnapshot): Promise<void> { this.snapshots.set(snapshot.id, snapshot); }
  async readSnapshot(id: string): Promise<TextSnapshot> {
    const snapshot: TextSnapshot | undefined = this.snapshots.get(id);
    if (snapshot === undefined) { throw new Error('missing test snapshot'); } return snapshot;
  }
  async remove(ids: string[]): Promise<void> {
    if (this.failRemove) { throw new Error('injected filesystem failure'); }
    for (const id of ids) { this.originals.delete(id); this.snapshots.delete(id); }
  }
  async reconcile(keep: string[]): Promise<void> {}
}
export class TextTestProcessor implements TextProcessingPort {
  async prepareQuery(question: string, cancel: TextCancellation): Promise<TextQueryInput> { cancel.check(); return prepareTextQuery(question); }
  async decode(bytes: Uint8Array, cancel: TextCancellation): Promise<TextNormalized> { cancel.check(); return normalizeText(bytes); }
  fail: boolean = false;
  gate: Promise<void> | undefined = undefined;
  async process(bytes: Uint8Array, document: TextDocument, generation: string, cancel: TextCancellation): Promise<TextProcessed> {
    if (this.gate !== undefined) { await this.gate; }
    cancel.check(); if (this.fail) { throw new Error('injected processing failure'); }
    return processText(bytes, document, generation);
  }
  async rebuild(snapshot: TextSnapshot, generation: string, cancel: TextCancellation): Promise<TextProcessed> {
    if (this.gate !== undefined) { await this.gate; }
    cancel.check(); if (this.fail) { throw new Error('injected processing failure'); }
    const result: TextProcessed = new TextProcessed();
    // Copy through the versioned codec in later regression, no production mock.
    result.snapshot = decodeSnapshot(encodeSnapshot(snapshot)); result.snapshot.id = `${generation}-snapshot`;
    result.chunks = structuredChunks(result.snapshot, generation); return result;
  }
}
export class TextTestRepository implements TextRepositoryPort {
  docs: TextDocument[] = [];
  jobRows: TextJob[] = [];
  chunks: TextChunk[] = [];
  cleanupRows: TextCleanup[] = [];
  records: TextHistory[] = [];
  failPublish: boolean = false;
  failCheckpoint: boolean = false;
  failPrepare: boolean = false;
  usageOverride: TextUsage | undefined = undefined;
  failHistory: boolean = false;
  failDelete: boolean = false;
  searchGate: Promise<void> | undefined = undefined;
  async open(): Promise<void> {}
  async close(): Promise<void> {}
  channel(): TextChannel { return TextChannel.Like; }
  async list(): Promise<TextDocument[]> { return this.docs.slice(); }
  async usage(): Promise<TextUsage> {
    if (this.usageOverride !== undefined) { return this.usageOverride; }
    const usage: TextUsage = new TextUsage(); usage.documents = this.docs.length;
    usage.originalBytes = this.docs.reduce((sum: number, doc: TextDocument): number => sum + doc.original.bytes, 0);
    usage.activeChunks = this.docs.reduce((sum: number, doc: TextDocument): number => sum + doc.chunkCount, 0); return usage;
  }
  async findHash(hash: string): Promise<TextDocument | undefined> { return this.docs.find((doc: TextDocument): boolean => doc.original.hash === hash); }
  async get(id: string): Promise<TextDocument | undefined> { return this.docs.find((doc: TextDocument): boolean => doc.id === id); }
  async add(doc: TextDocument, job: TextJob): Promise<void> { this.docs.push(doc); this.jobRows.push(job); }
  async start(job: TextJob): Promise<void> { this.jobRows = this.jobRows.filter((j: TextJob): boolean => j.documentId !== job.documentId).concat([job]); }
  async checkpoint(job: TextJob): Promise<void> {
    if (this.failCheckpoint) { throw new Error('injected checkpoint failure'); }
    if (await this.get(job.documentId) === undefined) { return; }
    this.jobRows = this.jobRows.filter((j: TextJob): boolean => j.id !== job.id).concat([job]);
    const doc = await this.get(job.documentId); if (doc !== undefined) { doc.stage = job.stage; doc.failure = job.failure; }
  }
  async jobs(): Promise<TextJob[]> { return this.jobRows.filter((job: TextJob): boolean => job.stage !== TextStage.Ready); }
  async prepare(doc: TextDocument, job: TextJob, chunks: TextChunk[]): Promise<void> {
    if (this.failPrepare) { throw new Error('injected index prepare failure'); }
    this.chunks = this.chunks.filter((c: TextChunk): boolean => c.generation !== job.generation).concat(chunks);
  }
  async publish(doc: TextDocument, job: TextJob, chunks: number): Promise<boolean> {
    if (this.failPublish) { throw new Error('injected transaction failure'); }
    const current = await this.get(doc.id);
    const stored = this.jobRows.find((j: TextJob): boolean => j.id === job.id);
    if (current === undefined || stored === undefined || stored.cancelGeneration !== job.cancelGeneration || stored.stage === TextStage.Paused || Date.now() - job.startedAt >= 60000) { return false; }
    current.activeGeneration = job.generation; current.chunkCount = chunks; current.stage = TextStage.Ready;
    stored.stage = TextStage.Ready; return true;
  }
  async rename(id: string, title: string): Promise<void> { const doc = await this.get(id); if (doc !== undefined) { doc.title = title; } }
  async archive(id: string, archived: boolean): Promise<void> { const doc = await this.get(id); if (doc !== undefined) { doc.archived = archived; } }
  async deleteDocuments(ids: string[]): Promise<void> {
    if (this.failDelete) { throw new Error('injected commit failure'); }
    for (const id of ids) {
      const doc = await this.get(id); if (doc === undefined) { continue; }
      const cleanup: TextCleanup = new TextCleanup(); cleanup.id = `cleanup-${id}`; cleanup.documentId = id;
      cleanup.assetIds = [doc.original.assetId];
      for (const c of this.chunks.filter((c: TextChunk): boolean => c.documentId === id)) {
        if (cleanup.assetIds.indexOf(c.snapshotId) < 0) { cleanup.assetIds.push(c.snapshotId); }
      }
      this.cleanupRows.push(cleanup);
      this.docs = this.docs.filter((d: TextDocument): boolean => d.id !== id);
      this.jobRows = this.jobRows.filter((j: TextJob): boolean => j.documentId !== id);
    }
    this.chunks = this.chunks.filter((chunk: TextChunk): boolean => ids.indexOf(chunk.documentId) < 0);
  }
  async cleanups(): Promise<TextCleanup[]> { return this.cleanupRows.slice(); }
  async finishCleanup(id: string, failure: string): Promise<void> {
    if (failure.length === 0) { this.cleanupRows = this.cleanupRows.filter((c: TextCleanup): boolean => c.id !== id); }
    else { const c = this.cleanupRows.find((c: TextCleanup): boolean => c.id === id); if (c !== undefined) { c.failure = failure; } }
  }
  async reconcile(pauseJobs: boolean = true): Promise<void> {
    if (!pauseJobs) { return; }
    for (const job of this.jobRows) {
      if (job.stage !== TextStage.Ready && job.stage !== TextStage.Failed) { job.stage = TextStage.Paused; }
    }
  }
  async assetIds(): Promise<string[]> { return this.docs.map((doc: TextDocument): string => doc.original.assetId); }
  async search(input: TextQueryInput, archived: boolean, cancel: TextCancellation): Promise<TextSearchResult> {
    if (this.searchGate !== undefined) { await this.searchGate; }
    cancel.check(); const result: TextSearchResult = new TextSearchResult(); result.input = input; result.channel = TextChannel.Like;
    for (const chunk of this.chunks) {
      const doc = await this.get(chunk.documentId);
      if (doc === undefined || doc.activeGeneration !== chunk.generation || (!archived && doc.archived)) { continue; }
      const score: number = textKeywordScore(chunk.retrievalText, input.terms); if (score === 0) { continue; }
      const hit: TextHit = new TextHit(); hit.documentId = doc.id; hit.title = doc.title;
      hit.documentVersion = doc.version; hit.originalHash = doc.original.hash; hit.generation = chunk.generation;
      hit.snapshotId = chunk.snapshotId; hit.chunkId = chunk.id; hit.text = chunk.evidenceText;
      hit.retrievalText = chunk.retrievalText; hit.ranges = chunk.ranges; hit.kind = chunk.kind;
      hit.channel = TextChannel.Like; hit.score = score; result.hits.push(hit);
    }
    result.hits.sort(compareTextHits); result.hits = result.hits.slice(0, 5); return result;
  }
  async saveHistory(history: TextHistory): Promise<void> {
    if (this.failHistory) { throw new Error('injected history failure'); } this.records.unshift(history);
  }
  async history(offset: number, limit: number): Promise<TextHistory[]> {
    const records: TextHistory[] = this.records.slice(offset, offset + limit);
    for (const record of records) {
      for (const hit of record.result.hits) {
        const doc = await this.get(hit.documentId);
        hit.referenceState = doc === undefined ? TextReferenceState.Deleted :
          (doc.activeGeneration !== hit.generation ? TextReferenceState.Old : TextReferenceState.Current);
      }
    }
    return records;
  }
}
export class TextTestSession {
  assets: TextTestAssets = new TextTestAssets();
  processor: TextTestProcessor = new TextTestProcessor();
  repository: TextTestRepository = new TextTestRepository();
  service: TextKnowledgeService;
  constructor() { this.service = new TextKnowledgeService(this.assets, this.assets, this.processor, this.repository); }
}
export function textServiceCases(): TextServiceTest[] {
  return [
    { name: '真实服务消费选择原件发布而非内置语料', run: async (): Promise<void> => {
      const session: TextTestSession = new TextTestSession(); await session.service.initialize();
      await session.service.importFiles();
      serviceCheck(session.repository.docs.length === 1 && session.repository.docs[0].chunkCount > 0, '导入未发布真实块');
      serviceCheck(session.repository.docs[0].stage === TextStage.Ready, '原件保存不等于就绪');
      session.service.questionChanged('关键词证据'); await session.service.search();
      serviceCheck(session.service.state.result.hits.length === 1 && session.service.state.result.channel === TextChannel.Like, '真实字面结果/通道错误');
      await session.service.openHit(session.service.state.result.hits[0]);
      serviceCheck(session.service.state.detail.excerpts[0] === '真实关键词证据\n第二行', '原文核对不一致');
      await session.service.importFiles(); serviceCheck(session.repository.docs.length === 1, '原件判重失败');
    } },
    { name: '选择取消/不支持/单 file 和 batch 超限均不截断', run: async (): Promise<void> => {
      const s: TextTestSession = new TextTestSession(); await s.service.initialize();
      s.assets.selected.canceled = true; await s.service.importFiles(); serviceCheck(s.repository.docs.length === 0, '取消有副作用');
      s.assets.selected.canceled = false; s.assets.selected.files[0].name = 'binary.pdf'; await s.service.importFiles();
      serviceCheck(s.repository.docs.length === 0, '错误格式入库');
      s.assets.selected.files[0].name = 'big.txt'; s.assets.selected.files[0].bytes = 1048577; await s.service.importFiles();
      serviceCheck(s.repository.docs.length === 0, '超限入库');
      s.assets.selected.files = Array<TextSelectedFile>(11).fill(s.assets.selected.files[0]); await s.service.importFiles();
      serviceCheck(s.service.state.message.includes('10') && s.repository.docs.length === 0, '批次未拒绝');
    } },
    { name: '管理/归档独立/重建失败旧活动保持/删除后清理失败', run: async (): Promise<void> => {
      const s: TextTestSession = new TextTestSession(); await s.service.initialize(); await s.service.importFiles();
      const doc: TextDocument = s.repository.docs[0]; const old: string = doc.activeGeneration;
      await s.service.rename(doc.id, '新的展示标题'); serviceCheck(doc.title === '新的展示标题', '重命名未实现');
      await s.service.setArchived(doc.id, true); s.service.questionChanged('关键词证据'); await s.service.search();
      serviceCheck(s.service.state.result.hits.length === 0 && doc.stage === TextStage.Ready, '归档必须独立且过滤');
      s.service.setIncludeArchived(true); await s.service.search(); serviceCheck(s.service.state.result.hits.length === 1, '包含归档未命中');
      await s.service.setArchived(doc.id, false); s.processor.fail = true; await s.service.rebuild(doc.id);
      serviceCheck(doc.activeGeneration === old, '失败重建破坏旧活动版本');
      await s.service.search(); serviceCheck(s.service.state.result.hits.length === 1, '失败后旧内容不可查');
      s.assets.failRemove = true; await s.service.deleteDocuments([doc.id], true);
      serviceCheck(s.repository.docs.length === 0 && s.repository.cleanupRows.length === 1, '逻辑删除未提交或清理失败回滚');
      await s.service.search(); serviceCheck(s.service.state.result.hits.length === 0, '孤儿块仍可召回');
      s.assets.failRemove = false; await s.service.retryCleanup(); serviceCheck(s.repository.cleanupRows.length === 0, '待清理无法重试');
    } },
    { name: '取消保留检查点/删除晚到不复活/手动恢复幂等', run: async (): Promise<void> => {
      const s: TextTestSession = new TextTestSession(); await s.service.initialize();
      let release: () => void = (): void => {};
      s.processor.gate = new Promise<void>((resolve: () => void): void => { release = resolve; });
      const pending: Promise<void> = s.service.importFiles();
      for (let i: number = 0; i < 30 && s.repository.docs.length === 0; i++) { await Promise.resolve(); }
      await s.service.cancel(); release(); await pending;
      serviceCheck(s.repository.docs.length === 1 && s.repository.docs[0].stage === TextStage.Paused, '取消丢原件或假就绪');
      const id: string = s.repository.docs[0].id; s.processor.gate = undefined;
      await s.service.resume(id); serviceCheck(s.repository.docs[0].stage === TextStage.Ready, '未从原件恢复');
      const old: string = s.repository.docs[0].activeGeneration;
      s.processor.gate = new Promise<void>((resolve: () => void): void => { release = resolve; });
      const rebuild: Promise<void> = s.service.rebuild(id);
      for (let i: number = 0; i < 20; i++) { await Promise.resolve(); }
      serviceCheck(s.repository.docs[0].activeGeneration === old, '重建中旧活动已丢');
      await s.service.deleteDocuments([id], true); release(); await rebuild;
      serviceCheck(s.repository.docs.length === 0, '晚到复活');
      await s.service.initialize(); serviceCheck(s.repository.docs.length === 0, '启动对账复活');
    } },
    { name: 'L0历史完整问题/输入/旧版删除快照不假跳', run: async (): Promise<void> => {
      const s: TextTestSession = new TextTestSession(); await s.service.initialize(); await s.service.importFiles();
      s.service.questionChanged('  关键词证据  '); await s.service.search();
      serviceCheck(s.repository.records.length === 1 && s.repository.records[0].result.input.fullQuestion === '  关键词证据  ', '完整问题未保存');
      serviceCheck(s.repository.records[0].result.input.actualInput === '关键词证据', '实际输入未独立保存');
      const doc: TextDocument = s.repository.docs[0]; await s.service.setArchived(doc.id, true);
      await s.service.loadHistory(false); serviceCheck(s.service.state.history[0].result.hits[0].referenceState === TextReferenceState.Current, '归档错误失效');
      await s.service.rebuild(doc.id); await s.service.loadHistory(false);
      serviceCheck(s.service.state.history[0].result.hits[0].referenceState === TextReferenceState.Old, '旧版冒当前');
      await s.service.deleteDocuments([doc.id], true); await s.service.loadHistory(false);
      const hit: TextHit = s.service.state.history[0].result.hits[0];
      serviceCheck(hit.referenceState === TextReferenceState.Deleted && hit.text.includes('关键词证据'), '已删快照丢失');
      await s.service.openHit(hit); serviceCheck(s.service.state.detail.originalText === '' && s.service.state.detail.note.includes('失效'), '已删引用假跳');
      s.repository.failHistory = true; s.service.questionChanged('不存在'); await s.service.search();
      serviceCheck(s.service.state.message.includes('历史保存失败'), '历史失败静默');
    } },
    { name: '库 100篇/20MiB/10000活动块 超限保持存量', run: async (): Promise<void> => {
      for (const kind of ['documents', 'bytes', 'chunks']) {
        const s: TextTestSession = new TextTestSession(); await s.service.initialize();
        const usage: TextUsage = new TextUsage(); usage.documents = kind === 'documents' ? 100 : 0;
        usage.originalBytes = kind === 'bytes' ? 20971520 : 0; usage.activeChunks = kind === 'chunks' ? 10000 : 0;
        s.repository.usageOverride = usage; await s.service.importFiles();
        serviceCheck(s.repository.docs.every((doc: TextDocument): boolean => doc.stage !== TextStage.Ready), '超预算假就绪');
        serviceCheck(s.service.state.message.includes('BUDGET'), '超限原因不明确');
      }
    } },
    { name: '发布/准备/检查点故障保留原件与旧索引', run: async (): Promise<void> => {
      for (const phase of ['prepare', 'publish', 'checkpoint']) {
        const s: TextTestSession = new TextTestSession(); await s.service.initialize(); await s.service.importFiles();
        const doc: TextDocument = s.repository.docs[0]; const old: string = doc.activeGeneration;
        s.repository.failPrepare = phase === 'prepare'; s.repository.failPublish = phase === 'publish'; s.repository.failCheckpoint = phase === 'checkpoint';
        await s.service.rebuild(doc.id);
        serviceCheck(doc.activeGeneration === old && s.assets.originals.size === 1, '阶段失败删原件或旧索引');
        s.repository.failCheckpoint = false; s.service.questionChanged('关键词证据'); await s.service.search();
        serviceCheck(s.service.state.result.hits.length === 1, '失败后旧索引被状态过滤');
      }
    } },
    { name: '未确认删除/事务失败/批量清空作用域', run: async (): Promise<void> => {
      const s: TextTestSession = new TextTestSession(); await s.service.initialize(); await s.service.importFiles();
      const id: string = s.repository.docs[0].id;
      await s.service.deleteDocuments([id], false); serviceCheck(s.repository.docs.length === 1, '未确认删除');
      s.repository.failDelete = true; await s.service.deleteDocuments([id], true);
      serviceCheck(s.repository.docs.length === 1 && s.assets.originals.size === 1, '提交失败先删文件');
      s.repository.failDelete = false; await s.service.purge(true);
      serviceCheck(s.repository.docs.length === 0 && s.assets.originals.size === 0, '清空未完成用户范围');
    } },
    { name: '完整长问题历史/分页/新会话读取', run: async (): Promise<void> => {
      const s: TextTestSession = new TextTestSession(); await s.service.initialize(); await s.service.importFiles();
      const question: string = '关键词证据 ' + '汉😀'.repeat(500);
      s.service.questionChanged(question); await s.service.search();
      for (let i: number = 0; i < 21; i++) { s.service.questionChanged(`问题 ${i}`); await s.service.search(); }
      const reopened: TextKnowledgeService = new TextKnowledgeService(s.assets, s.assets, s.processor, s.repository);
      await reopened.initialize(); await reopened.loadHistory(false); serviceCheck(reopened.state.history.length === 20, '分页不有界');
      await reopened.loadHistory(true); serviceCheck(reopened.state.history.length === 2, '后页缺失或无界累积');
      serviceCheck(reopened.state.history[1].result.input.fullQuestion === question, '重开长问题失真');
      await reopened.previousHistoryPage(); serviceCheck(reopened.state.history.length === 20, '上一页缺失');
    } },
    { name: '取消批次未开始文件不写入', run: async (): Promise<void> => {
      const s: TextTestSession = new TextTestSession(); await s.service.initialize();
      s.assets.selected.files = [s.assets.selected.files[0], s.assets.selected.files[0]];
      let release: () => void = (): void => {};
      s.processor.gate = new Promise<void>((resolve: () => void): void => { release = resolve; });
      const pending: Promise<void> = s.service.importFiles();
      for (let i: number = 0; i < 50 && s.repository.docs.length === 0; i++) { await Promise.resolve(); }
      await s.service.cancel(); release(); await pending;
      serviceCheck(s.repository.docs.length === 1 && s.service.state.message.includes('未开始读取'), '批次取消继续保存后续文件');
    } },
    { name: '真实 10秒 查询超时保留旧结果且晚到不覆盖', run: async (): Promise<void> => {
      const s: TextTestSession = new TextTestSession(); await s.service.initialize(); await s.service.importFiles();
      s.service.questionChanged('关键词证据'); await s.service.search(); const old: TextSearchResult = s.service.state.result;
      let release: () => void = (): void => {};
      s.repository.searchGate = new Promise<void>((resolve: () => void): void => { release = resolve; });
      const started: number = Date.now(); s.service.questionChanged('迟到结果'); await s.service.search();
      serviceCheck(Date.now() - started >= 10000 && s.service.state.message.includes('TIMEOUT'), '未执行真实查询窗口');
      release(); await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 10); });
      serviceCheck(s.service.state.result === old, '超时清空或被晚到覆盖');
    } },
    { name: '真实 60秒 索引窗口到期不发布/保留原件', run: async (): Promise<void> => {
      const s: TextTestSession = new TextTestSession(); await s.service.initialize();
      let release: () => void = (): void => {};
      s.processor.gate = new Promise<void>((resolve: () => void): void => { release = resolve; });
      const pending: Promise<void> = s.service.importFiles();
      for (let i: number = 0; i < 50 && s.repository.docs.length === 0; i++) { await Promise.resolve(); }
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 60100); });
      release(); await pending;
      serviceCheck(s.repository.docs.length === 1 && s.repository.docs[0].activeGeneration === '' && s.repository.docs[0].stage === TextStage.Failed, '索引超时发布');
      serviceCheck(s.service.state.message.includes('TIMEOUT') && s.assets.originals.size === 1, '超时原件丢失/未报告');
    } }
  ];
}
