import {
  ParsedImportState, ParsedDocument, ParsedDocumentRecord, ParsedAssetRef, ParsedCancellation, ParsedFailure, ParsedTextChunk, ParsedAssetPreview, parsedHash
} from '../domain/ParsedDocumentModels';
import { ParsedRepositoryPort, ParsedAssetPort, ParsedProducerPort, ParsedIdentityPort, ParsedImportRequest } from '../domain/ParsedDocumentPorts';
import { parsedValidate, parsedUtf8 } from '../pipeline/ParsedDocumentCodec';
import { parsedDocumentChunks } from '../pipeline/ParsedDocumentChunker';

export class ParsedDocumentIngestionService {
  state: ParsedImportState = new ParsedImportState(); private repository: ParsedRepositoryPort; private assets: ParsedAssetPort; private identity: ParsedIdentityPort;
  private cancel: ParsedCancellation | undefined; private listeners: Array<() => void> = [];
  private previews: ParsedAssetPreview[] = [];
  private previewEpoch: number = 0;
  private openEpoch: number = 0;
  private published: ((document: ParsedDocument) => Promise<void>) | undefined;
  attachPublished(callback: (document: ParsedDocument) => Promise<void>): void { this.published=callback; }
  constructor(repository: ParsedRepositoryPort, assets: ParsedAssetPort, identity: ParsedIdentityPort) { this.repository = repository; this.assets = assets; this.identity = identity; }
  subscribe(listener: () => void): void { if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); } }
  unsubscribe(listener: () => void): void { this.listeners = this.listeners.filter((l: () => void): boolean => l !== listener); }
  private emit(): void { for (const listener of this.listeners) { listener(); } }
  pause(): void { if (this.cancel !== undefined) { this.cancel.invalid = true; } }
  async previewImage(id: string): Promise<string> { const opened: ParsedAssetPreview[] = await this.previewImages([id]); return opened.length > 0 ? opened[0].path : ''; }
  // 详情页图片网格需要同时持有同页多张预览租约；任一步失败都要释放已开租约。
  async previewImages(ids: string[]): Promise<ParsedAssetPreview[]> {
    await this.closePreview();
    const epoch: number = this.previewEpoch; const opened: ParsedAssetPreview[] = [];
    try {
      for (const id of ids) { opened.push(await this.assets.openPreview(id,new ParsedCancellation())); }
    } catch (error) {
      for (const preview of opened) { await this.assets.closePreview(preview); }
      if (error instanceof Error) { throw error; } throw new ParsedFailure('PreviewOpenFailed','asset');
    }
    if (epoch !== this.previewEpoch) { for (const preview of opened) { await this.assets.closePreview(preview); } throw new ParsedFailure('PreviewCanceled','preview'); }
    this.previews = opened; return opened;
  }
  async closePreview(): Promise<void> { this.previewEpoch++; const opened: ParsedAssetPreview[] = this.previews; this.previews = []; for (const preview of opened) { await this.assets.closePreview(preview); } }
  async refresh(): Promise<void> { this.state.documents = await this.repository.list(); this.emit(); }
  async retryLocal(): Promise<void> {
    if (this.state.busy) { return; } const current: ParsedDocument = this.state.document;
    if (current.generation.length === 0) { throw new ParsedFailure('SelectReceivedResultToRecover','retry'); }
    await this.assets.reconcile(new ParsedCancellation());
    const document: ParsedDocument = await this.assets.readSnapshot(`${current.generation}-manifest`,new ParsedCancellation());
    const owner: ParsedDocumentRecord | undefined = await this.repository.get(document.documentKey);
    if (owner === undefined || owner.tombstone) { throw new ParsedFailure('OwnerUnavailable','retry'); }
    if (owner.activeGeneration === document.generation) { await this.open(owner.id); return; }
    const snapshot = await this.assets.saveSnapshot(document,new ParsedCancellation()); const chunks: ParsedTextChunk[] = await parsedDocumentChunks(document,this.identity,new ParsedCancellation());
    if (!await this.repository.publish(document,chunks,`${document.generation}-manifest`,snapshot.manifest.contentHash,owner.epoch,owner.activeGeneration)) { throw new ParsedFailure('PublicationStale','retry'); }
    await this.open(owner.id); await this.refresh();
    if (this.published!==undefined) { try { await this.published(this.state.document); this.state.enhancement='QueuedOrAwaitingConfig'; } catch { this.state.enhancement='QueueCheckpointFailed'; } this.emit(); }
  }
  async open(id: string): Promise<void> {
    const epoch: number=++this.openEpoch; await this.closePreview();
    const record: ParsedDocumentRecord | undefined = await this.repository.get(id);
    if (record === undefined || record.tombstone || record.activeGeneration.length === 0) { throw new ParsedFailure('DocumentUnavailable','open'); }
    const document: ParsedDocument=await this.assets.readSnapshot(`${record.activeGeneration}-manifest`,new ParsedCancellation());
    const chunks: ParsedTextChunk[]=await this.repository.chunks(id);
    if (epoch!==this.openEpoch) { return; }
    this.state.document=document; this.state.chunks=chunks; this.state.stage='Published'; this.state.message=''; this.emit();
  }
  async ingest(request: ParsedImportRequest, producer: ParsedProducerPort, rebuild: boolean = false): Promise<void> {
    if (this.state.busy) { throw new ParsedFailure('ImportBusy','ingest'); }
    this.openEpoch++; const cancel: ParsedCancellation = new ParsedCancellation(); this.cancel = cancel; this.state.busy = true; this.state.stage = 'Preparing'; this.state.message = ''; this.emit();
    try {
      if (!parsedHash(request.sourceHash) || request.namespace.length === 0 || request.sourceId.length === 0 || request.sourceVersion < 1) { throw new ParsedFailure('SourceIdentity','ingest'); }
      const id: string = 'upd-'+(await this.identity.hash(parsedUtf8(`${request.namespace}\n${request.sourceId}`))).slice(0,32);
      let record: ParsedDocumentRecord | undefined = await this.repository.get(id);
      if (record !== undefined && (record.tombstone || record.sourceHash !== request.sourceHash)) { throw new ParsedFailure('SourceDeletedOrVersionChanged','ingest'); }
      if (record === undefined) { record = new ParsedDocumentRecord(); record.id = id; record.namespace = request.namespace; record.legacyId = request.sourceId; record.title = request.title; record.sourceHash = request.sourceHash; await this.repository.register(record); }
      const generation: string = rebuild ? this.identity.id() : 'upd-'+(await this.identity.hash(parsedUtf8([id,request.sourceHash,String(request.sourceVersion),request.parserSignature,request.outputIdentity].join('\n')))).slice(0,32);
      if (record.activeGeneration === generation) { await this.open(id); this.state.message = '当前产物已发布，已读回；未重复解析或外发'; return; }
      // Protect original and received ZIP independently before any producer reads them.
      for (const source of request.sources) {
        const ref: ParsedAssetRef = new ParsedAssetRef(); ref.holder = generation; ref.documentKey = id; ref.generation = generation; ref.owner = source.owner; ref.assetId = source.id; ref.role = source.role; await this.repository.addRef(ref);
      }
      this.state.stage = 'Producing'; this.emit();
      const d: ParsedDocument = await producer.produce(request,id,generation,this.assets,cancel); cancel.check(); parsedValidate(d);
      if (d.documentKey !== id || d.generation !== generation || d.source_hash !== request.sourceHash || d.sourceVersion !== request.sourceVersion || d.parser_signature !== request.parserSignature || d.engine !== request.engine) { throw new ParsedFailure('ProducerIdentityMismatch','ingest'); }
      this.state.document = d; this.state.stage = 'Saving'; this.emit();
      const snapshot = await this.assets.saveSnapshot(d,cancel); const chunks: ParsedTextChunk[] = await parsedDocumentChunks(d,this.identity,cancel); cancel.check();
      if (!await this.repository.publish(d,chunks,`${generation}-manifest`,snapshot.manifest.contentHash,record.epoch,record.activeGeneration)) { throw new ParsedFailure('PublicationStale','ingest'); }
      this.state.document = await this.assets.readSnapshot(`${generation}-manifest`,cancel); this.state.chunks = await this.repository.chunks(id);
      this.state.stage = 'Published'; this.state.enhancement = 'AwaitingConfig'; this.state.message = d.warnings.length > 0 ? '正文/OCR已发布；部分来源或图片有限制' : '正文/OCR已发布';
      if (this.published!==undefined) { try { await this.published(this.state.document); this.state.enhancement='QueuedOrAwaitingConfig'; } catch { this.state.enhancement='QueueCheckpointFailed'; this.state.message+='；增强排队待重试，正文保留'; } }
    } catch (error) {
      this.state.stage = cancel.invalid ? 'Paused' : 'Failed'; this.state.message = error instanceof ParsedFailure ? `${error.category} / ${error.stage}` : 'LocalImportFailed；原件与已发布内容保留';
      if (error instanceof Error) { throw error; } throw new ParsedFailure('LocalImportFailed','ingest');
    } finally { this.cancel = undefined; this.state.busy = false; await this.refresh(); }
  }
  async stop(): Promise<void> { this.pause(); await this.closePreview(); const deadline: number=Date.now()+120000; while (this.state.busy) { if (Date.now()>deadline) { throw new ParsedFailure('IngestionReleaseUnconfirmed','close'); } await new Promise<void>((resolve: () => void): void=> { setTimeout(resolve,20); }); } }
}
