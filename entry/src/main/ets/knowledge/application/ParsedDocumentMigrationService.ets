import { ParsedLegacyReadPort, ParsedMigrationStorePort, ParsedMigrationBatch, ParsedMigrationInput, ParsedMigrationReceipt, ParsedLegacyProjection } from '../domain/ParsedMigrationModels';
import { ParsedAssetPort, ParsedIdentityPort, ParsedImportRequest } from '../domain/ParsedDocumentPorts';
import { ParsedDocumentRecord, ParsedDocument, ParsedCancellation, ParsedFailure, ParsedLegacyLink, ParsedFormat } from '../domain/ParsedDocumentModels';
import { migrationSetHash, migrationDecodeBatch } from '../pipeline/ParsedMigrationCodec';
import { parsedDocumentChunks } from '../pipeline/ParsedDocumentChunker';
import { parsedValidate, parsedUtf8, parsedEncodeSnapshot } from '../pipeline/ParsedDocumentCodec';

export class ParsedDocumentMigrationService {
  private reader: ParsedLegacyReadPort; private repository: ParsedMigrationStorePort; private assets: ParsedAssetPort; private identity: ParsedIdentityPort;
  private operation: Promise<void> | undefined; private cancel: ParsedCancellation | undefined;
  private listeners: Array<() => void>=[];
  batch: ParsedMigrationBatch | undefined; receipts: ParsedMigrationReceipt[]=[]; catalogRows: ParsedMigrationInput[]=[]; message: string=''; busy: boolean=false;
  constructor(reader: ParsedLegacyReadPort, repository: ParsedMigrationStorePort, assets: ParsedAssetPort, identity: ParsedIdentityPort) { this.reader=reader; this.repository=repository; this.assets=assets; this.identity=identity; }
  subscribe(listener: () => void): void { if (this.listeners.indexOf(listener)<0) { this.listeners.push(listener); } }
  unsubscribe(listener: () => void): void { this.listeners=this.listeners.filter((l: () => void): boolean=>l!==listener); }
  private emit(): void { for (const listener of this.listeners) { listener(); } }
  async catalog(): Promise<ParsedMigrationInput[]> { this.catalogRows=await this.reader.catalog(); this.emit(); return this.catalogRows; }
  async batches(): Promise<string[]> { return this.repository.migrationBatchIds(); }
  async freeze(keys: string[]): Promise<ParsedMigrationBatch> {
    if (this.busy || keys.length===0 || new Set<string>(keys).size!==keys.length) { throw new ParsedFailure('MigrationSelection','freeze'); }
    const catalog: ParsedMigrationInput[]=await this.catalog(); const inputs: ParsedMigrationInput[]=keys.map((key: string): ParsedMigrationInput=> { const input: ParsedMigrationInput | undefined=catalog.find((i: ParsedMigrationInput): boolean=>i.key===key); if (input===undefined) { throw new ParsedFailure('SelectedLegacyUnavailable','freeze'); } return input; });
    inputs.sort((a: ParsedMigrationInput,b: ParsedMigrationInput): number=>a.key.localeCompare(b.key));
    const batch: ParsedMigrationBatch=new ParsedMigrationBatch(); batch.id=this.identity.id(); batch.inputs=inputs; batch.inputSetHash=await migrationSetHash(inputs,this.identity);
    await this.repository.saveMigrationBatch(batch); this.batch=await migrationDecodeBatch(JSON.stringify(batch),this.identity); this.receipts=[]; this.message=`已冻结 ${inputs.length} 项本机范围；不会发送图片、文本或重新解析`; this.emit(); return this.batch;
  }
  async load(id: string): Promise<void> { this.batch=await this.repository.migrationBatch(id); if (this.batch===undefined) { throw new ParsedFailure('MigrationBatchMissing','resume'); } this.receipts=await this.repository.migrationReceipts(id); this.emit(); }
  pause(): void { if (this.cancel!==undefined) { this.cancel.invalid=true; } this.message='已请求本机暂停，旧活动资料保留'; this.emit(); }
  async run(id: string): Promise<void> {
    if (this.operation!==undefined) { throw new ParsedFailure('MigrationAlreadyRunning','migration'); }
    const operation: Promise<void>=this.execute(id); this.operation=operation; try { await operation; } finally { this.operation=undefined; }
  }
  async close(): Promise<void> { this.pause(); const operation: Promise<void> | undefined=this.operation; if (operation!==undefined) { await Promise.resolve(operation); } }
  private async execute(id: string): Promise<void> {
    await this.load(id); const batch: ParsedMigrationBatch | undefined=this.batch; if (batch===undefined) { return; }
    this.busy=true; const cancel: ParsedCancellation=new ParsedCancellation(); this.cancel=cancel; this.emit();
    try {
      await this.assets.reconcile(cancel);
      for (const input of batch.inputs) {
        cancel.check(); let receipt: ParsedMigrationReceipt | undefined=(await this.repository.migrationReceipts(id)).find((r: ParsedMigrationReceipt): boolean=>r.inputKey===input.key);
        if (receipt===undefined) { receipt=new ParsedMigrationReceipt(); receipt.batchId=id; receipt.inputKey=input.key; receipt.inputHash=input.inputHash; receipt.documentKey='upd-'+(await this.identity.hash(parsedUtf8('legacy|'+input.namespace+'|'+input.legacyId))).slice(0,32); receipt.generation='upd-'+(await this.identity.hash(parsedUtf8('migration|'+input.inputHash))).slice(0,32); await this.repository.saveMigrationReceipt(receipt); }
        const committed: ParsedLegacyLink | undefined=await this.repository.migrationLink(input);
        if (committed!==undefined) { const active=await this.repository.get(committed.documentKey); if (active?.activeGeneration===committed.generation && !active.tombstone) { receipt.phase='Committed'; receipt.state=receipt.warnings.length>0?'Partial':'Complete'; receipt.generation=committed.generation; await this.repository.saveMigrationReceipt(receipt); continue; } }
        try { await this.one(input,receipt,cancel); }
        catch (error) { receipt.state=cancel.invalid?'Paused':'Failed'; receipt.failure=error instanceof ParsedFailure?`${error.category} / ${error.stage}`:'LocalMigrationReadOrWriteFailed'; await this.repository.saveMigrationReceipt(receipt); if (cancel.invalid) { break; } }
        this.receipts=await this.repository.migrationReceipts(id); this.emit();
      }
      this.message='本机批次已处理；完整/部分/失败按冻结分母保留，未产生外发作业';
    } catch (error) { this.message=cancel.invalid?'本机批次已暂停':'本机恢复未完成，旧资料与检查点保留'; }
    finally { this.cancel=undefined; this.busy=false; this.receipts=await this.repository.migrationReceipts(id); this.emit(); }
  }
  private async one(input: ParsedMigrationInput, receipt: ParsedMigrationReceipt, cancel: ParsedCancellation): Promise<void> {
    let record: ParsedDocumentRecord | undefined=await this.repository.get(receipt.documentKey);
    if (record===undefined) { record=new ParsedDocumentRecord(); record.id=receipt.documentKey; record.namespace='Legacy:'+input.namespace; record.legacyId=input.legacyId; record.title=input.title; record.sourceHash=input.sourceHash; record.archived=input.archived; await this.repository.register(record); }
    if (record.tombstone || record.namespace!=='Legacy:'+input.namespace || record.legacyId!==input.legacyId) { throw new ParsedFailure('UnifiedOwnerChangedOrDeleted','migration'); }
    await this.repository.migrationHold(input,receipt.generation,record.id,receipt.generation); receipt.phase='Held'; receipt.state='Running'; receipt.failure=''; await this.repository.saveMigrationReceipt(receipt);
    let document: ParsedDocument;
    try {
      document=await this.assets.readSnapshot(`${receipt.generation}-manifest`,cancel);
      if (receipt.legacyWire.length===0 || receipt.legacyHash.length===0 || document.documentKey!==record.id || document.source_hash!==input.sourceHash) { throw new ParsedFailure('NoCompleteSnapshotCheckpoint','resume'); }
      const readback=await parsedEncodeSnapshot(document,this.identity,cancel,async (): Promise<void>=>{}); if (receipt.contentHash.length>0 && receipt.contentHash!==readback.manifest.contentHash) { throw new ParsedFailure('MigrationCheckpointHashChanged','resume'); } receipt.contentHash=readback.manifest.contentHash;
    } catch (error) {
      cancel.check(); const projection: ParsedLegacyProjection=await this.reader.project(input,cancel);
      receipt.legacyWire=projection.legacyWire; receipt.legacyHash=projection.legacyHash; receipt.wireByteHash=projection.wireByteHash; receipt.phase='Projected'; await this.repository.saveMigrationReceipt(receipt);
      const request: ParsedImportRequest=new ParsedImportRequest(); request.namespace='Legacy:'+input.namespace; request.sourceId=input.legacyId; request.sourceHash=input.sourceHash; request.sourceVersion=input.sourceVersion; request.title=input.title;
      request.format=input.namespace==='Text'?ParsedFormat.Text:input.namespace==='Pdf'?ParsedFormat.Pdf:input.namespace==='Image'?ParsedFormat.Image:ParsedFormat.Docx; request.engine='LocalMigration'; request.parserSignature=`LEGACY-TO-UPD-1|${projection.legacyWire}|${input.inputHash}`; request.outputIdentity=input.inputHash;
      document=await projection.producer.produce(request,record.id,receipt.generation,this.assets,cancel); parsedValidate(document);
      const snapshot=await this.assets.saveSnapshot(document,cancel); receipt.contentHash=snapshot.manifest.contentHash; receipt.phase='SnapshotReady'; receipt.warnings=document.warnings.filter((w: string): boolean=>w!=='LocalMigrationNoNetwork' && w!=='MarkdownProjectionStructureUnverified');
      if (document.coverage.imageRecovery.state==='Partial') { receipt.warnings.push('ImageRecoveryPartial'); }
      await this.repository.saveMigrationReceipt(receipt);
    }
    cancel.check(); document=await this.assets.readSnapshot(`${receipt.generation}-manifest`,cancel); const chunks=await parsedDocumentChunks(document,this.identity,cancel); receipt.expected=chunks.length; receipt.phase='Readback'; await this.repository.saveMigrationReceipt(receipt);
    const link: ParsedLegacyLink=new ParsedLegacyLink(); link.namespace=input.namespace; link.legacyId=input.legacyId; link.legacyGeneration=input.active; link.legacyWire=receipt.legacyWire; link.legacyHash=receipt.legacyHash; link.documentKey=record.id; link.generation=receipt.generation; link.epoch=input.epoch; link.oldActive=input.active;
    link.snapshotAsset=input.snapshotAsset; link.sourceVersion=input.sourceVersion; link.archived=input.archived;
    if (!await this.repository.publish(document,chunks,`${receipt.generation}-manifest`,receipt.contentHash,record.epoch,record.activeGeneration,link)) { throw new ParsedFailure('UnifiedRouteCASFailed','migration'); }
    receipt.phase='Committed'; receipt.state=receipt.warnings.length>0?'Partial':'Complete'; await this.repository.saveMigrationReceipt(receipt);
  }
}
