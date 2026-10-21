import { DocxKnowledgeRepository } from './DocxKnowledgeRepository';
import { DocxDocument, DocxNativeNode, DocxSnapshot, DocxReadLease, DocxReleaseReceipt, DocxFailure, DocxChunk, DocxOriginal } from '../domain/DocxKnowledgeModels';
import { KnowledgeHit, KnowledgeResultSegment } from '../domain/KnowledgeSearchModels';
import { KnowledgeIdentityPort, KnowledgeStateListener } from '../domain/KnowledgePorts';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { knowledgeSegments } from '../pipeline/KnowledgeMatchPolicy';

export class DocxSourceSession {
  nodes: DocxNativeNode[] = []; title: string = ''; message: string = ''; total: number = 0; page: number = 0;
  segments: KnowledgeResultSegment[] = []; address: string = ''; releasing: boolean = false;
  private repository: DocxKnowledgeRepository; private identity: KnowledgeIdentityPort;
  private snapshot: DocxSnapshot | undefined = undefined; private document: DocxDocument | undefined = undefined;
  private lease: DocxReadLease | undefined = undefined; private epoch: number = 0; private listeners: KnowledgeStateListener[] = [];
  private verifyOriginal: (original: DocxOriginal, cancel: KnowledgeCancellation) => Promise<void>;
  constructor(repository: DocxKnowledgeRepository, identity: KnowledgeIdentityPort, verifyOriginal: (original: DocxOriginal, cancel: KnowledgeCancellation) => Promise<void>) { this.repository = repository; this.identity = identity; this.verifyOriginal = verifyOriginal; }
  subscribe(listener: KnowledgeStateListener): void { this.listeners.push(listener); }
  unsubscribe(listener: KnowledgeStateListener): void { this.listeners = this.listeners.filter((l: KnowledgeStateListener): boolean => l !== listener); }
  private changed(): void { for (const l of this.listeners) { l.changed(); } }
  invalidate(): void { this.epoch++; this.nodes = []; this.segments = []; this.snapshot = undefined; this.document = undefined; this.address = ''; this.changed(); }
  async open(document: DocxDocument, hit?: KnowledgeHit): Promise<void> {
    await this.close(); const epoch: number = ++this.epoch; const cancel: KnowledgeCancellation = new KnowledgeCancellation();
    const current: DocxDocument | undefined = await this.repository.get(document.id);
    if (current === undefined || current.tombstone || current.activeGeneration.length === 0 || hit !== undefined && !(await this.repository.visible(hit,true))) { throw new DocxFailure('CurrentSourceUnavailableOrOld','source'); }
    const lease: DocxReadLease = new DocxReadLease(); lease.id = this.identity.id(); lease.assetId = current.activeOriginal; lease.documentId = current.id; lease.owner = 'DocxSourceSession'; lease.epoch = current.epoch;
    await this.repository.acquireRead(lease); this.lease = lease;
    try {
      const snapshot: DocxSnapshot = await this.repository.snapshot(hit?.generation ?? current.activeGeneration); cancel.check();
      await this.verifyOriginal(snapshot.original,cancel); cancel.check();
      if (epoch !== this.epoch || snapshot.original.assetId !== current.activeOriginal) { throw new DocxFailure('SourceChangedWhileOpening','source'); }
      this.snapshot = snapshot; this.document = current; this.title = current.title; this.total = snapshot.nodes.length; this.page = 0;
      if (hit !== undefined) {
        const chunk: DocxChunk | undefined = (await this.repository.chunks(hit.generation)).find((c: DocxChunk): boolean => c.id === hit.chunkId && c.text === hit.text && JSON.stringify(c.locator) === JSON.stringify(hit.locator.docx));
        if (chunk === undefined) { throw new DocxFailure('SourceChunkLocatorChanged','source'); }
        const index: number = snapshot.nodes.findIndex((n: DocxNativeNode): boolean => n.id === chunk.locator.nodeId); this.page = Math.max(0,Math.floor(index/8)); this.segments = knowledgeSegments(hit);
        const cell = chunk.locator.cell; this.address = `${chunk.locator.part} · 段落 ${chunk.locator.paragraph+1}`+(cell === undefined ? '' : ` · 表 ${cell.tableId} 行 ${cell.row+1} 列 ${cell.column+1} 合并 ${cell.rowSpan}×${cell.columnSpan}`)+` · UTF16 [${chunk.locator.start},${chunk.locator.end})`;
      }
      this.nodes = snapshot.nodes.slice(this.page*8,this.page*8+8); this.message = '原件版本内只读结构；不对应Word页码'; this.changed();
    } catch (error) { await this.close(); if (error instanceof Error) { throw error; } throw new DocxFailure('SourceOpenFailed','source'); }
  }
  async turn(delta: number): Promise<void> {
    const document: DocxDocument | undefined = this.document; const snapshot: DocxSnapshot | undefined = this.snapshot; const epoch: number = this.epoch;
    if (document === undefined || snapshot === undefined) { return; }
    const current: DocxDocument | undefined = await this.repository.get(document.id);
    try { await this.verifyOriginal(snapshot.original,new KnowledgeCancellation()); }
    catch { this.invalidate(); this.message = '原件已变化或不可读，来源显示已失效'; this.changed(); return; }
    if (epoch !== this.epoch || current === undefined || current.tombstone || current.epoch !== document.epoch || current.activeGeneration !== snapshot.generation) { this.invalidate(); this.message = '来源已变化或删除'; return; }
    this.page = Math.max(0,Math.min(Math.max(0,Math.ceil(this.total/8)-1),this.page+delta)); this.nodes = snapshot.nodes.slice(this.page*8,this.page*8+8); this.changed();
  }
  async close(): Promise<void> {
    this.invalidate(); const lease: DocxReadLease | undefined = this.lease; if (lease === undefined) { return; } this.releasing = true;
    const receipt: DocxReleaseReceipt = new DocxReleaseReceipt(); receipt.leaseId = lease.id; receipt.resource = 'Released';
    try { await this.repository.releaseRead(receipt); this.lease = undefined; this.releasing = false; }
    catch { receipt.resource = 'Unknown'; receipt.failure = 'LeaseReleaseUnconfirmed'; try { await this.repository.releaseRead(receipt); } catch {} this.message = '来源释放未确认，可重试；清理保持阻止'; this.changed(); throw new DocxFailure('ReleaseUnconfirmed','source'); }
    this.changed();
  }
}
