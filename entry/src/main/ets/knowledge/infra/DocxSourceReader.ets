import { KnowledgeSearchSourcePort, KnowledgeSourceScan, KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { KnowledgeHit, KnowledgeChannel } from '../domain/KnowledgeSearchModels';
import { TextQueryInput } from '../domain/TextKnowledgeModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { DocxOriginal, DocxSnapshot, DocxStage } from '../domain/DocxKnowledgeModels';
import { DocxKnowledgeRepository } from './DocxKnowledgeRepository';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';

export class DocxSourceReader implements KnowledgeSearchSourcePort {
  kind: string = 'Docx'; private repository: DocxKnowledgeRepository; private identity: KnowledgeIdentityPort; private host: KnowledgeStoreHost;
  private verifyOriginal: (original: DocxOriginal, cancel: KnowledgeCancellation) => Promise<void>;
  constructor(repository: DocxKnowledgeRepository, identity: KnowledgeIdentityPort, host: KnowledgeStoreHost, verifyOriginal: (original: DocxOriginal, cancel: KnowledgeCancellation) => Promise<void>) { this.repository = repository; this.identity = identity; this.host = host; this.verifyOriginal = verifyOriginal; }
  async visible(hit: KnowledgeHit, archived: boolean): Promise<boolean> { return (hit.channels.indexOf(KnowledgeChannel.Vector)>=0 || !await this.host.unifiedLegacyRoute(this.kind,hit.documentId,hit.generation)) && this.repository.ready() && this.repository.visible(hit,archived); }
  async scan(input: TextQueryInput, archived: boolean, _extras: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeSourceScan> {
    const scan: KnowledgeSourceScan = new KnowledgeSourceScan(); scan.kind = this.kind; scan.complete = this.repository.ready();
    if (!scan.complete) { return scan; } const revisions: string[] = [];
    for (const d of await this.repository.list()) {
      cancel.check(); if (d.tombstone || !archived && d.archived) { continue; }
      revisions.push(JSON.stringify(d));
      await this.verifyOriginal(await this.repository.original(d.activeOriginal),cancel);
      if (d.activeGeneration.length === 0 || [DocxStage.Published,DocxStage.Empty].indexOf(d.stage) < 0) { scan.complete = false; }
      if (d.activeGeneration.length > 0) {
        const s: DocxSnapshot = await this.repository.snapshot(d.activeGeneration); const chunks = await this.repository.chunks(d.activeGeneration);
        if (s.coverage.partial || chunks.length !== d.chunkCount || s.original.assetId !== d.activeOriginal) { scan.complete = false; }
        scan.count += chunks.length; revisions.push(s.hash+'|'+s.coverage.hash);
      }
      const pending = await this.host.requireStore().querySql("SELECT o.asset,o.hash,o.version FROM kb_docx_original o WHERE o.doc=? AND o.asset<>? AND NOT EXISTS(SELECT 1 FROM kb_docx_generation g WHERE g.original=o.asset AND g.state='Abandoned') ORDER BY o.version,o.asset",[d.id,d.activeOriginal]);
      try { while (pending.goToNextRow()) { revisions.push(JSON.stringify([pending.getString(0),pending.getString(1),pending.getLong(2)])); if (pending.getLong(2) > (d.activeGeneration.length === 0 ? 0 : (await this.repository.original(d.activeOriginal)).version)) { scan.complete = false; } } } finally { pending.close(); }
    }
    const mirrors = await this.host.requireStore().querySql('SELECT * FROM kb_docx_vector_mirror ORDER BY doc');
    try { while (mirrors.goToNextRow()) { revisions.push(JSON.stringify([mirrors.getString(0),mirrors.getString(1),mirrors.getString(2),mirrors.getString(3),mirrors.getLong(4),mirrors.getLong(5),mirrors.getString(6)])); } } finally { mirrors.close(); }
    const retained: KnowledgeHit[]=[]; for (const hit of await this.repository.directCandidates(input,archived,cancel)) { if (!await this.host.unifiedLegacyRoute(this.kind,hit.documentId,hit.generation)) { retained.push(hit); } } scan.hits=retained; scan.revision = await this.identity.hash(pdfCodecUtf8(JSON.stringify(revisions))); return scan;
  }
}
