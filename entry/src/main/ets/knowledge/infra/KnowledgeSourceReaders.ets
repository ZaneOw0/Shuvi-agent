import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { KnowledgeSearchSourcePort, KnowledgeSourceScan, KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { TextCandidatePort } from '../domain/TextKnowledgePorts';
import { TextQueryInput, TextCancellation, TextHit } from '../domain/TextKnowledgeModels';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { KnowledgeHit, KnowledgeSourceKind, KnowledgeChannel } from '../domain/KnowledgeSearchModels';
import { KnowledgeSearchRepository, knowledgeTextHit } from '../application/KnowledgeSearchService';
import { ImageKnowledgeRepository } from './ImageKnowledgeRepository';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';

export class KnowledgeSqlSourceReader implements KnowledgeSearchSourcePort {
  kind: string; private host: KnowledgeStoreHost; private identity: KnowledgeIdentityPort;
  private text: TextCandidatePort; private pdf: KnowledgeSearchRepository; private image: ImageKnowledgeRepository;
  constructor(kind: string, host: KnowledgeStoreHost, identity: KnowledgeIdentityPort, text: TextCandidatePort, pdf: KnowledgeSearchRepository, image: ImageKnowledgeRepository) { this.kind = kind; this.host = host; this.identity = identity; this.text = text; this.pdf = pdf; this.image = image; }
  async visible(hit: KnowledgeHit, archived: boolean): Promise<boolean> {
    if (hit.channels.indexOf(KnowledgeChannel.Vector)<0 && await this.host.unifiedLegacyRoute(this.kind,hit.documentId,hit.generation)) { return false; }
    if (this.kind === 'Image') { return this.image.visible(hit,archived); }
    if (this.kind === 'Pdf') { return this.pdf.visible(hit,archived); }
    if (this.kind !== 'Text') { return false; }
    const doc = await this.text.get(hit.documentId); return doc !== undefined && doc.activeGeneration === hit.generation && doc.original.hash === hit.originalHash && (archived || !doc.archived);
  }
  async scan(input: TextQueryInput, archived: boolean, extras: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeSourceScan> {
    if (this.kind !== 'Text' && this.kind !== 'Pdf' && this.kind !== 'Image') { throw new KnowledgeFailure('UnknownSource','scope'); }
    const scan: KnowledgeSourceScan = new KnowledgeSourceScan(); scan.kind = this.kind;
    const sql: string = this.kind === 'Text' ? 'SELECT d.id,d.active,d.hash,d.version,d.archived,d.chunks,(SELECT count(*) FROM text_chunk c JOIN text_generation g ON g.id=c.generation AND g.complete=1 WHERE c.doc=d.id AND c.generation=d.active) FROM text_doc d WHERE (?=1 OR d.archived=0) ORDER BY d.id'
      : this.kind === 'Pdf' ? 'SELECT d.id,d.active_content,d.original_hash,d.epoch,d.archived,d.chunks,(SELECT count(*) FROM kb_chunk c JOIN kb_content_generation g ON g.id=c.generation AND g.state=\'Active\' WHERE c.doc=d.id AND c.generation=d.active_content) FROM kb_document d WHERE d.tombstone=0 AND (?=1 OR d.archived=0) ORDER BY d.id'
      : 'SELECT d.id,d.active_generation,d.active_original,d.epoch,d.archived,d.chunks,(SELECT count(*) FROM kb_image_chunk c JOIN kb_image_generation g ON g.id=c.generation AND g.state=\'Active\' WHERE c.doc=d.id AND c.generation=d.active_generation) FROM kb_image_document d WHERE d.tombstone=0 AND (?=1 OR d.archived=0) ORDER BY d.id';
    const rows = await this.host.requireStore().querySql(sql,[archived ? 1 : 0]); const projection: string[] = [];
    try { while (rows.goToNextRow()) { cancel.check(); const expected: number = rows.getLong(5); const actual: number = rows.getLong(6); if (expected !== actual || expected < 0 || scan.count+actual > 10000) { throw new KnowledgeFailure('SourceCountOrGenerationIncomplete','scope'); } scan.count += actual; projection.push(JSON.stringify([rows.getString(0),rows.getString(1),rows.getString(2),rows.getLong(3),rows.getLong(4),expected,actual])); } } finally { rows.close(); }
    if (this.kind === 'Text') { const c: TextCancellation = new TextCancellation(); c.deadline = cancel.deadline; if (this.text.directCandidates === undefined) { throw new KnowledgeFailure('TextScanUnavailable','scope'); } scan.hits = (await this.text.directCandidates(input,archived,c)).hits.map((hit: TextHit): KnowledgeHit => knowledgeTextHit(hit)); }
    else if (this.kind === 'Pdf') { if (!this.pdf.ready() || this.pdf.directCandidates === undefined) { throw new KnowledgeFailure('PdfScanUnavailable','scope'); } scan.hits = await this.pdf.directCandidates(input,archived,extras,cancel); }
    else { if (!this.image.ready()) { throw new KnowledgeFailure('ImageScanUnavailable','scope'); } scan.hits = await this.image.directCandidates(input,archived,extras,cancel); }
    if (this.kind === 'Image') {
      const vectors = await this.host.requireStore().querySql('SELECT m.doc,m.content,m.generation,m.space,m.epoch,m.revision,m.state FROM kb_image_vector_mirror m ORDER BY m.doc');
      try { while (vectors.goToNextRow()) { projection.push(JSON.stringify([vectors.getString(0),vectors.getString(1),vectors.getString(2),vectors.getString(3),vectors.getLong(4),vectors.getLong(5),vectors.getString(6)])); } } finally { vectors.close(); }
    } else if (this.kind === 'Pdf') {
      const vectors = await this.host.requireStore().querySql('SELECT doc,content_generation,vector_generation,space,epoch,revision,state FROM kb_eligibility_mirror ORDER BY doc');
      try { while (vectors.goToNextRow()) { projection.push(JSON.stringify([vectors.getString(0),vectors.getString(1),vectors.getString(2),vectors.getString(3),vectors.getLong(4),vectors.getLong(5),vectors.getString(6)])); } } finally { vectors.close(); }
    }
    const retained: KnowledgeHit[]=[]; for (const hit of scan.hits) { if (!await this.host.unifiedLegacyRoute(this.kind,hit.documentId,hit.generation)) { retained.push(hit); } } scan.hits=retained;
    scan.revision = await this.identity.hash(pdfCodecUtf8(JSON.stringify(projection))); scan.complete = true; return scan;
  }
}
