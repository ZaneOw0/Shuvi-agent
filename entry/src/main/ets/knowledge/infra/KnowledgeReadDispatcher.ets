import { KnowledgeSourceReadPort } from '../domain/KnowledgePorts';
import { KnowledgeReadLease, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { ImageReadLease, ImageReleaseReceipt } from '../domain/ImageKnowledgeModels';
import { ImageKnowledgeRepository } from './ImageKnowledgeRepository';
import { DocxKnowledgeRepository } from './DocxKnowledgeRepository';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { DocxReadLease, DocxReleaseReceipt } from '../domain/DocxKnowledgeModels';

export class KnowledgeReadDispatcher implements KnowledgeSourceReadPort {
  private pdf: KnowledgeSourceReadPort; private image: ImageKnowledgeRepository; private imageLeaseIds: Set<string> = new Set<string>();
  private docx: DocxKnowledgeRepository | undefined; private host: KnowledgeStoreHost | undefined;
  constructor(pdf: KnowledgeSourceReadPort, image: ImageKnowledgeRepository, docx?: DocxKnowledgeRepository, host?: KnowledgeStoreHost) { this.pdf = pdf; this.image = image; this.docx = docx; this.host = host; }
  async acquireRead(lease: KnowledgeReadLease): Promise<void> {
    if (this.docx !== undefined) {
      if (!this.docx.ready()) { throw new KnowledgeFailure('DocxOwnerUnavailable','vector-read'); }
      const document = await this.docx.documentForSource(lease.sourceId);
      if (document !== undefined) {
        if (document.activeGeneration !== lease.generation) { throw new KnowledgeFailure('DocxReadGenerationChanged','vector-read'); }
        const read: DocxReadLease = new DocxReadLease(); read.id = lease.id; read.documentId = document.id; read.assetId = document.activeOriginal; read.owner = lease.sessionId; read.epoch = document.epoch; await this.docx.acquireRead(read); return;
      }
    }
    if (!this.image.ready()) { throw new KnowledgeFailure('ImageOwnerUnavailable','vector-read'); }
    const doc = await this.image.documentForSource(lease.sourceId);
    if (doc === undefined) {
      if (this.host !== undefined) { const owner = await this.host.requireStore().querySql('SELECT count(*) FROM kb_document WHERE original_id=? AND active_content=? AND tombstone=0',[lease.sourceId,lease.generation]); try { if (!owner.goToNextRow() || owner.getLong(0) !== 1) { throw new KnowledgeFailure('SourceOwnerUnknownOrAmbiguous','vector-read'); } } finally { owner.close(); } }
      await this.pdf.acquireRead(lease); return;
    }
    if (doc.activeGeneration !== lease.generation) { throw new KnowledgeFailure('ImageReadGenerationChanged','vector-read'); }
    const read: ImageReadLease = new ImageReadLease(); read.id = lease.id; read.documentId = doc.id; read.assetId = doc.activeOriginal; read.epoch = doc.epoch; read.owner = lease.sessionId;
    await this.image.acquireRead(read); this.imageLeaseIds.add(lease.id);
  }
  async releaseRead(id: string): Promise<void> {
    if (this.host !== undefined && this.docx !== undefined) {
      const rows = await this.host.requireStore().querySql('SELECT (SELECT count(*) FROM kb_docx_lease WHERE id=?),(SELECT count(*) FROM kb_image_lease WHERE id=?),(SELECT count(*) FROM kb_read_lease WHERE id=?)',[id,id,id]);
      let owner: number = -1;
      try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('LeaseOwnerUnknownOrAmbiguous','release'); } const count: number = rows.getLong(0)+rows.getLong(1)+rows.getLong(2); if (count > 1) { throw new KnowledgeFailure('LeaseOwnerUnknownOrAmbiguous','release'); } if (count === 1) { owner = rows.getLong(0) === 1 ? 0 : rows.getLong(1) === 1 ? 1 : 2; } } finally { rows.close(); }
      if (owner < 0) { const receipt = await this.host.requireStore().querySql("SELECT id FROM kb_docx_release WHERE id=? AND state='Released' AND failure=''",[id]); try { if (!receipt.goToNextRow()) { throw new KnowledgeFailure('LeaseOwnerUnknownOrAmbiguous','release'); } return; } finally { receipt.close(); } }
      if (owner === 0) { const receipt: DocxReleaseReceipt = new DocxReleaseReceipt(); receipt.leaseId = id; receipt.resource = 'Released'; await this.docx.releaseRead(receipt); return; }
      if (owner === 1) { const receipt: ImageReleaseReceipt = new ImageReleaseReceipt(); receipt.leaseId = id; await this.image.releaseRead(receipt); return; }
      await this.pdf.releaseRead(id); return;
    }
    if (!this.imageLeaseIds.has(id)) { await this.pdf.releaseRead(id); return; }
    const receipt: ImageReleaseReceipt = new ImageReleaseReceipt(); receipt.leaseId = id; await this.image.releaseRead(receipt); this.imageLeaseIds.delete(id);
  }
}
