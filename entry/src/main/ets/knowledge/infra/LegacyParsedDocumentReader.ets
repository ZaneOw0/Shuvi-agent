import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { relationalStore } from '@kit.ArkData';
import { ParsedMigrationInput, ParsedLegacyReadPort, ParsedLegacyProjection } from '../domain/ParsedMigrationModels';
import { ParsedSourceAsset, ParsedProducerPort, ParsedImportRequest, ParsedAssetPort, ParsedImageBytesPort } from '../domain/ParsedDocumentPorts';
import { ParsedDocument, ParsedCancellation, ParsedFailure, ParsedFormat, ParsedProvenance, ParsedBlock, ParsedInline, ParsedKind, ParsedPrecision } from '../domain/ParsedDocumentModels';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { KnowledgeCancellation, PdfNormalizedDocument, PdfNodeKind, PdfContentNode, PdfDerivedImage, PdfAssetDescriptor } from '../domain/PdfKnowledgeModels';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { documentReadRange } from './DocumentFileOperations';
import { decodeSnapshot } from '../pipeline/StructuredChunker';
import { TextSnapshot } from '../domain/TextKnowledgeModels';
import { pdfStrictUtf8 } from '../pipeline/SafeZipPolicy';
import { parsedUtf8, parsedJson } from '../pipeline/ParsedDocumentCodec';
import { imageDecodeSnapshot, imageVerifySnapshot } from '../pipeline/ImageSnapshotCodec';
import { ImageSnapshot, ImageOcrBlock } from '../domain/ImageKnowledgeModels';
import { docxDecodeSnapshot, docxVerifySnapshot } from '../pipeline/DocxSnapshotCodec';
import { DocxSnapshot } from '../domain/DocxKnowledgeModels';
import { ParsedDocumentAdapters, ParsedImageProduction } from './ParsedDocumentAdapters';
import { DocxArchiveAdapter, docxOpenVerified } from './DocxArchiveAdapter';
import { DocxZipDirectory, DocxZipMember } from '../domain/DocxKnowledgePorts';
import { docxReadUnifiedOutput, ParsedArchiveImageBytes } from './DocxResultReader';
import { PdfLegacySnapshotFiles } from './PdfLegacySnapshotFiles';
import { PdfImagePayloadExporter, PdfImageDescriptorPort } from './PdfImagePayload';
import { migrationInputHash } from '../pipeline/ParsedMigrationCodec';
import { ParsedOutputProjection, ParsedOutputImageLink } from '../pipeline/ParsedOutputDecoder';

class LegacyFileImage implements ParsedImageBytesPort {
  private path: string; private hash: string; private maximum: number; private identity: KnowledgeIdentityPort;
  constructor(path: string, hash: string, maximum: number, identity: KnowledgeIdentityPort) { this.path=path; this.hash=hash; this.maximum=maximum; this.identity=identity; }
  async read(cancel: ParsedCancellation): Promise<Uint8Array> { const bytes: Uint8Array=await legacyReadBytes(this.path,this.maximum,cancel); if (await this.identity.hash(bytes)!==this.hash) { throw new ParsedFailure('LegacyImageOriginalHash','migration-read'); } return bytes; }
}
class LegacyPdfImage implements ParsedImageBytesPort {
  private exporter: PdfImagePayloadExporter; private image: PdfDerivedImage; private generation: string;
  constructor(exporter: PdfImagePayloadExporter, image: PdfDerivedImage, generation: string) { this.exporter=exporter; this.image=image; this.generation=generation; }
  async read(cancel: ParsedCancellation): Promise<Uint8Array> { const c: KnowledgeCancellation=new KnowledgeCancellation(); c.deadline=cancel.deadline; cancel.check(); return this.exporter.payload(this.image,this.generation,c); }
}
export async function legacyReadBytes(path: string, maximum: number, cancel: ParsedCancellation): Promise<Uint8Array> {
  const file: fileIo.File=await fileIo.open(path,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
  try { const stat: fileIo.Stat=await fileIo.stat(file.fd); if (!stat.isFile() || stat.size<1 || stat.size>maximum) { throw new ParsedFailure('LegacyFileBudget','migration-read'); } const bytes: Uint8Array=await documentReadRange(file.fd,0,stat.size); cancel.check(); return bytes; } finally { await fileIo.close(file); }
}
class LegacyProjectionProducer implements ParsedProducerPort {
  private adapter: ParsedDocumentAdapters; private input: ParsedMigrationInput; private files: string; private identity: KnowledgeIdentityPort;
  constructor(adapter: ParsedDocumentAdapters, input: ParsedMigrationInput, files: string, identity: KnowledgeIdentityPort) { this.adapter=adapter; this.input=input; this.files=files; this.identity=identity; }
  async produce(request: ParsedImportRequest, document: string, generation: string, assets: ParsedAssetPort, cancel: ParsedCancellation): Promise<ParsedDocument> {
    const archives: DocxArchiveAdapter[]=[]; const token: KnowledgeCancellation=new KnowledgeCancellation(); token.deadline=cancel.deadline;
    try {
      if (this.input.namespace==='Docx' || this.input.namespace==='Image') {
        for (const role of this.input.namespace==='Docx'?['Original','Result']:['Result']) {
          const id: string=role==='Original'?this.input.originalAsset:this.input.resultAsset; if (id.length===0) { this.adapter.addWarning('Legacy'+role+'CacheMissing'); continue; }
          const archive: DocxArchiveAdapter=new DocxArchiveAdapter(); archives.push(archive);
          try { const directory: DocxZipDirectory=await archive.inspect(await docxOpenVerified(`${this.files}/knowledge_parse_v1/${id}`,role==='Original'?this.input.originalBytes:this.input.resultBytes,role==='Original'?this.input.sourceHash:this.input.resultHash,this.identity,token),role,token);
            let resultImagesSelected: boolean=false;
            if (role==='Result') { try { const selected: ParsedDocumentAdapters=await docxReadUnifiedOutput(archive,directory,this.identity,token); selected.absorb(this.adapter); this.adapter=selected; resultImagesSelected=true; } catch { cancel.check(); this.adapter.addWarning('LegacyResultTextUnavailableSnapshotPreserved'); } }
            if (this.input.namespace==='Image') { this.adapter.markBodyAsOcr(); }
            if (resultImagesSelected) { continue; }
            for (const member of directory.members) { if (!member.name.endsWith('/') && member.name.split('/').includes(role==='Original'?'media':'images')) { const image: ParsedImageProduction=new ParsedImageProduction(new ParsedArchiveImageBytes(archive,member)); image.member=member.name; image.provenance=role==='Original'?ParsedProvenance.Native:ParsedProvenance.Derived; this.adapter.addProduction(image); } }
          } catch { cancel.check(); this.adapter.addWarning('Legacy'+role+'CacheMissingOrInvalid'); }
        }
      }
      return await this.adapter.produce(request,document,generation,assets,cancel);
    } finally { for (const archive of archives) { await archive.release(); } }
  }
}
export class LegacyParsedDocumentReader implements ParsedLegacyReadPort, PdfImageDescriptorPort {
  private host: KnowledgeStoreHost; private files: string; private derived: string; private identity: KnowledgeIdentityPort;
  constructor(context: common.Context, host: KnowledgeStoreHost, identity: KnowledgeIdentityPort) { this.host=host; this.files=context.filesDir; this.derived=`${context.filesDir}/${host.storageScope.derivedDirectory}`; this.identity=identity; }
  private source(input: ParsedMigrationInput,id: string,owner: string,role: string): void { if (id.length>0 && !input.sources.some((s: ParsedSourceAsset): boolean=>s.id===id && s.owner===owner)) { const s: ParsedSourceAsset=new ParsedSourceAsset(); s.id=id; s.owner=owner; s.role=role; input.sources.push(s); } }
  async catalog(): Promise<ParsedMigrationInput[]> {
    const store=this.host.requireStore(); const tables=await store.querySql("SELECT name FROM sqlite_master WHERE type='table'"); const names: string[]=[]; try { while (tables.goToNextRow()) { names.push(tables.getString(0)); } } finally { tables.close(); }
    const out: ParsedMigrationInput[]=[];
    for (const kind of ['Text','Pdf','Image','Docx']) {
      const table: string=kind==='Text'?'text_doc':kind==='Pdf'?'kb_document':kind==='Image'?'kb_image_document':'kb_docx_document'; if (names.indexOf(table)<0) { continue; }
      const sql: string=kind==='Text'?'SELECT d.id,d.title,d.active,d.version,d.hash,d.version,d.archived,g.snapshot,g.hash,d.asset,d.bytes,\'\',\'\',0 FROM text_doc d JOIN text_generation g ON g.id=d.active WHERE g.complete=1':kind==='Pdf'?'SELECT d.id,d.title,d.active_content,d.epoch,d.original_hash,d.original_version,d.archived,g.snapshot,g.snapshot_hash,d.original_asset,d.original_bytes,d.result_asset,d.zip_hash,d.zip_bytes FROM kb_document d JOIN kb_content_generation g ON g.id=d.active_content WHERE d.tombstone=0':kind==='Image'?'SELECT d.id,d.title,d.active_generation,d.epoch,o.hash,o.version,d.archived,g.wire,g.hash,o.asset,o.bytes,\'\',\'\',0 FROM kb_image_document d JOIN kb_image_generation g ON g.id=d.active_generation JOIN kb_image_original o ON o.asset=d.active_original WHERE d.tombstone=0':'SELECT d.id,d.title,d.active_generation,d.epoch,o.hash,o.version,d.archived,g.asset,g.hash,o.asset,o.bytes,\'\',\'\',0 FROM kb_docx_document d JOIN kb_docx_generation g ON g.id=d.active_generation JOIN kb_docx_original o ON o.asset=d.active_original WHERE d.tombstone=0';
      const rows=await store.querySql(sql.replace('o.hash,o.version','o.hash AS source_hash,o.version').replace('g.wire,g.hash','g.wire,g.hash AS snapshot_hash').replace('g.asset,g.hash','g.asset AS snapshot_asset,g.hash AS snapshot_hash'));
      try { while (rows.goToNextRow()) { const i: ParsedMigrationInput=new ParsedMigrationInput(); i.namespace=kind; i.legacyId=rows.getString(0); i.key=kind+':'+i.legacyId; i.title=rows.getString(1); i.active=rows.getString(2); i.epoch=rows.getLong(3); i.sourceHash=rows.getString(4); i.sourceVersion=rows.getLong(5); i.archived=rows.getLong(6)===1; i.snapshotAsset=rows.getString(7); i.snapshotHash=rows.getString(8); i.originalAsset=rows.getString(9); i.originalBytes=rows.getLong(10); i.resultAsset=rows.getString(11); i.resultHash=rows.getString(12); i.resultBytes=rows.getLong(13); i.snapshotFamily=kind==='Text'?'TEXT-SNAPSHOT-1':kind==='Pdf'?'PDF-NORMALIZED-1':kind==='Image'?'IMAGE-STORED-WIRE':'DOCX-NORMALIZED-1'; out.push(i); if (out.length>10000) { throw new ParsedFailure('LegacyCatalogBudget','migration'); } } } finally { rows.close(); }
    }
    for (const i of out) {
      if (i.namespace==='Docx' || i.namespace==='Image') {
        const resultRows=await store.querySql(i.namespace==='Docx'?'SELECT result_binding FROM kb_docx_job WHERE generation=?':'SELECT result_asset,result_hash FROM kb_image_job WHERE generation=?',[i.active]);
        try { if (resultRows.goToNextRow()) {
          if (i.namespace==='Docx') { const result=parsedJson(parsedUtf8(resultRows.getString(0)),new ParsedCancellation()); i.resultAsset=result.required('assetId').string(); i.resultHash=result.required('hash').string(); i.resultBytes=result.required('bytes').integer(); }
          else { i.resultAsset=resultRows.getString(0); i.resultHash=resultRows.getString(1); if (i.resultAsset.length>0 && await fileIo.access(`${this.files}/knowledge_parse_v1/${i.resultAsset}`)) { i.resultBytes=(await fileIo.lstat(`${this.files}/knowledge_parse_v1/${i.resultAsset}`)).size; } }
        } } finally { resultRows.close(); }
      }
      this.source(i,i.originalAsset,i.namespace==='Text'?'TextFileAdapter':'DocumentParseService','original'); this.source(i,i.snapshotAsset,i.namespace==='Text'?'TextFileAdapter':i.namespace==='Pdf'?'PdfAssetAdapter':i.namespace==='Image'?'ImageSnapshotAssets':'DocxSnapshotAssets','snapshot'); this.source(i,i.resultAsset,'DocumentParseService','result');
      const assetTable: string=i.namespace==='Docx'?'kb_docx_asset':i.namespace==='Image'?'kb_image_asset':i.namespace==='Pdf'?'kb_asset':'';
      if (assetTable.length>0 && names.indexOf(assetTable)>=0) { const refs=await store.querySql(i.namespace==='Pdf'?'SELECT id,\'PdfAssetAdapter\',\'derived\' FROM kb_asset WHERE generation=?':`SELECT id,owner,role FROM ${assetTable} WHERE generation=? OR (doc=? AND owner='DocumentParseService')`,i.namespace==='Pdf'?[i.active]:[i.active,i.legacyId]); try { while (refs.goToNextRow()) { this.source(i,refs.getString(0),refs.getString(1),refs.getString(2)); } } finally { refs.close(); } }
      i.sources.sort((a: ParsedSourceAsset,b: ParsedSourceAsset): number=>(a.owner+'|'+a.id).localeCompare(b.owner+'|'+b.id)); i.inputHash=await migrationInputHash(i,this.identity);
    }
    out.sort((a: ParsedMigrationInput,b: ParsedMigrationInput): number=>a.key.localeCompare(b.key)); return out;
  }
  async assetDescriptor(id: string): Promise<PdfAssetDescriptor> {
    const rows=await this.host.requireStore().querySql('SELECT id,generation,hash,bytes,manifest FROM kb_asset WHERE id=? AND state=?',[id,'Staged']);
    try { if (!rows.goToNextRow()) { throw new ParsedFailure('LegacyPdfAssetUnavailable','migration'); } const d: PdfAssetDescriptor=new PdfAssetDescriptor(); d.id=rows.getString(0); d.generation=rows.getString(1); d.hash=rows.getString(2); d.bytes=rows.getLong(3); d.format=rows.getString(4); return d; } finally { rows.close(); }
  }
  async project(input: ParsedMigrationInput, cancel: ParsedCancellation): Promise<ParsedLegacyProjection> {
    if (await migrationInputHash(input,this.identity)!==input.inputHash) { throw new ParsedFailure('FrozenLegacyInputHash','migration-read'); }
    const adapter: ParsedDocumentAdapters=new ParsedDocumentAdapters(this.identity); const token: KnowledgeCancellation=new KnowledgeCancellation(); token.deadline=cancel.deadline;
    const originalPath: string=`${this.files}/${input.namespace==='Text'?'knowledge_user_v1':'knowledge_parse_v1'}/${input.originalAsset}`;
    if (!(await fileIo.access(originalPath))) { adapter.addWarning('LegacyOriginalCacheMissing'); }
    if (input.resultAsset.length>0 && !(await fileIo.access(`${this.files}/knowledge_parse_v1/${input.resultAsset}`))) { adapter.addWarning('LegacyResultCacheMissing'); }
    let wire: string=''; let legacyHash: string=input.snapshotHash; let rawHash: string='';
    if (input.namespace==='Text') {
      const raw: Uint8Array=await legacyReadBytes(`${this.files}/knowledge_user_v1/${input.snapshotAsset}`,12582912,cancel); const s: TextSnapshot=decodeSnapshot(pdfStrictUtf8(raw));
      if (s.id!==input.snapshotAsset || s.documentId!==input.legacyId || s.documentVersion!==input.sourceVersion || s.originalHash!==input.sourceHash) { throw new ParsedFailure('LegacyTextSnapshotIdentity','migration-read'); }
      wire='TEXT-SNAPSHOT-1'; rawHash=await this.identity.hash(raw); adapter.setOutput(s.normalized.originalText || s.normalized.text,undefined,input.snapshotAsset);
    } else if (input.namespace==='Image') {
      const raw: Uint8Array=await legacyReadBytes(`${this.derived}/image/${input.snapshotAsset}`,8388608,cancel); const s: ImageSnapshot=imageDecodeSnapshot(raw,token); await imageVerifySnapshot(s,this.identity,token);
      if (s.generation!==input.active || s.documentId!==input.legacyId || s.contentHash!==input.snapshotHash || s.original.hash!==input.sourceHash) { throw new ParsedFailure('LegacyImageSnapshotIdentity','migration-read'); }
      wire=s.wire; rawHash=await this.identity.hash(raw); adapter.setOutput(s.wire==='IMAGE-NORMALIZED-2' && s.projection.text.length>0?s.projection.text:s.blocks.map((b: ImageOcrBlock): string=>b.text).join('\n\n'),undefined,s.contentHash); adapter.markBodyAsOcr();
      const image: ParsedImageProduction=new ParsedImageProduction(new LegacyFileImage(`${this.files}/knowledge_parse_v1/${input.originalAsset}`,input.sourceHash,20971520,this.identity)); image.member=input.originalAsset; image.provenance=ParsedProvenance.Original; adapter.addProduction(image);
    } else if (input.namespace==='Docx') {
      const raw: Uint8Array=await legacyReadBytes(`${this.derived}/docx/${input.snapshotAsset}`,8388608,cancel); const s: DocxSnapshot=docxDecodeSnapshot(raw,token); await docxVerifySnapshot(s,this.identity,token);
      if (s.generation!==input.active || s.documentId!==input.legacyId || s.hash!==input.snapshotHash || s.original.hash!==input.sourceHash) { throw new ParsedFailure('LegacyDocxSnapshotIdentity','migration-read'); }
      wire=s.wire; rawHash=await this.identity.hash(raw); adapter.setOutput(s.projection.text,undefined,s.hash); adapter.addWarning('LegacyNativeLocationNotReconstructed');
      if (s.result.assetId!==input.resultAsset || s.result.hash!==input.resultHash || s.result.bytes!==input.resultBytes) { throw new ParsedFailure('LegacyDocxResultIdentity','migration-read'); }
      if (s.projection.text.trim().length===0) { const b: ParsedBlock=new ParsedBlock(); b.id='legacy-empty'; b.kind=ParsedKind.Unknown; b.limitation='LegacyNoSelectedTextObjectsNotReconstructed'; adapter.setProjectedBlocks([b],'',s.hash); }
      const native: ParsedOutputProjection=new ParsedOutputProjection();
      for (const media of s.media) { const b: ParsedBlock=new ParsedBlock(); b.id='native-legacy-media-'+native.blocks.length; b.kind=ParsedKind.Image; b.order=native.blocks.length; b.imageOccurrenceId='native-legacy-occ-'+native.links.length; b.limitation=media.external?'ExternalMediaNotRead':'LegacyMediaBlockLocationUnknown'; const link: ParsedOutputImageLink=new ParsedOutputImageLink(); link.blockId=b.id; link.occurrenceId=b.imageOccurrenceId; link.member=media.external?'':media.targetPart; link.order=native.links.length; native.blocks.push(b); native.links.push(link); }
      for (const issue of s.coverage.issues) { if (issue.code==='Formula' || issue.kind==='Unsupported') { const b: ParsedBlock=new ParsedBlock(); b.id='native-legacy-issue-'+native.blocks.length; b.kind=issue.code==='Formula'?ParsedKind.Formula:ParsedKind.Unknown; b.order=native.blocks.length; b.limitation=issue.code; b.formula.unsupportedReason=issue.code==='Formula'?'LegacyOmmlNotConverted':''; native.blocks.push(b); } }
      adapter.setNative(native);
    } else if (input.namespace==='Pdf') {
      const descriptor: PdfAssetDescriptor=await this.assetDescriptor(input.snapshotAsset); const s: PdfNormalizedDocument=await new PdfLegacySnapshotFiles(this.derived,this.identity).readBody(input.snapshotAsset,descriptor.hash,token);
      if (s.documentId!==input.legacyId || s.generation!==input.active || s.hash!==input.snapshotHash || s.binding.originalHash!==input.sourceHash) { throw new ParsedFailure('LegacyPdfSnapshotIdentity','migration-read'); }
      wire=s.wire; rawHash=descriptor.hash; const blocks: ParsedBlock[]=[];
      for (const node of s.nodes) {
        const b: ParsedBlock=new ParsedBlock(); b.id='legacy-'+blocks.length; b.order=blocks.length; b.text=node.text; b.kind=node.kind===PdfNodeKind.Formula?ParsedKind.Formula:node.kind===PdfNodeKind.Image?ParsedKind.Image:node.kind===PdfNodeKind.Unsupported?ParsedKind.Unknown:node.kind===PdfNodeKind.Table?ParsedKind.Table:ParsedKind.Text; b.locator.precision=ParsedPrecision.Block;
        if (b.kind===ParsedKind.Formula) { b.formula.latex=node.rawLatex || node.text; if (b.formula.latex.length===0) { b.formula.unsupportedReason='LegacyFormulaUnknown'; } }
        if (b.kind===ParsedKind.Unknown) { b.limitation=node.excludedReason || 'LegacyObjectUnsupported'; }
        if (b.kind===ParsedKind.Image) { b.limitation='LegacyImagePositionBlockOnly'; }
        for (const run of node.runs) { const r: ParsedInline=new ParsedInline(); r.id=b.id+'-r'+b.inlines.length; r.order=b.inlines.length; if (run.kind==='equation_inline') { r.kind=ParsedKind.Formula; r.formula.latex=run.text; } else { r.text=run.text; } b.inlines.push(r); }
        blocks.push(b);
        if (node.table!==undefined) { for (const cell of node.table.cells) { const c: ParsedBlock=new ParsedBlock(); c.id=b.id+'-cell-'+blocks.length; c.parentId=b.id; c.order=blocks.length; c.kind=ParsedKind.Cell; c.text=cell.text; c.row=cell.row; c.column=cell.column; c.rowSpan=cell.rowSpan; c.columnSpan=cell.columnSpan; c.locator.precision=ParsedPrecision.Block; blocks.push(c); } }
      }
      adapter.setProjectedBlocks(blocks,s.nodes.map((n: PdfContentNode): string=>n.text).join('\n\n'),s.hash);
      const exporter: PdfImagePayloadExporter=new PdfImagePayloadExporter(this.derived,this,this.identity);
      for (const derived of s.images) { const image: ParsedImageProduction=new ParsedImageProduction(new LegacyPdfImage(exporter,derived,input.active)); image.member=derived.memberId; image.provenance=ParsedProvenance.Derived; try { image.legacyContainerHash=(await this.assetDescriptor(derived.id)).hash; } catch { image.limitation='LegacyPdfImageDescriptorMissing'; } adapter.addProduction(image); }
    } else { throw new ParsedFailure('UnsupportedLegacyNamespace','migration-read'); }
    adapter.addWarning('LocalMigrationNoNetwork'); const projection: ParsedLegacyProjection=new ParsedLegacyProjection(new LegacyProjectionProducer(adapter,input,this.files,this.identity)); projection.legacyWire=wire; projection.legacyHash=legacyHash; projection.wireByteHash=rawHash; return projection;
  }
}
