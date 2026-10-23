import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ParsedDocumentIngestionService } from '../application/ParsedDocumentIngestionService';
import { DocumentParseService } from '../application/DocumentParseService';
import { ParsedDocumentAdapters, ParsedImageProduction } from './ParsedDocumentAdapters';
import { ParsedImportRequest, ParsedSourceAsset, ParsedImageBytesPort, ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { ParsedFormat, ParsedCancellation, ParsedProvenance, ParsedFailure, ParsedDocument } from '../domain/ParsedDocumentModels';
import { TextFileAdapter } from './TextFileAdapter';
import { TextOriginal, TextCancellation, TextSelectedFile, TextSelection } from '../domain/TextKnowledgeModels';
import { DocumentOriginal, DocumentParseResultEnvelope, DocumentParseTask, DocumentParseFormat, DocumentImageEvidence, DocumentParseGrant } from '../domain/DocumentParseModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { DocxOriginal, DocxResultBinding } from '../domain/DocxKnowledgeModels';
import { DocxResultReader } from './DocxResultReader';
import { DocxProcessingAdapter } from './DocxProcessingAdapter';
import { documentAssetPath, documentReadRange } from './DocumentFileOperations';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { pdfStrictUtf8 } from '../pipeline/SafeZipPolicy';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { ParsedProducerPort, ParsedAssetPort } from '../domain/ParsedDocumentPorts';
import { imageInspectHeader } from '../pipeline/ImageHeaderPolicy';
import { ImageHeaderReader } from '../domain/ImageKnowledgePorts';
import { ImageHeaderEvidence } from '../domain/ImageKnowledgeModels';
import { KnowledgeDerivedBudget } from './KnowledgeDerivedBudget';

class ParsedImportHeader implements ImageHeaderReader {
  length: number; private bytes: Uint8Array;
  constructor(bytes: Uint8Array) { this.bytes = bytes; this.length = bytes.length; }
  async read(at: number, length: number): Promise<Uint8Array> { return this.bytes.slice(at,at+length); }
}

export class ParsedOriginalImageBytes implements ParsedImageBytesPort {
  private root: string; private original: DocumentOriginal; private identity: ParsedIdentityPort;
  constructor(root: string, original: DocumentOriginal, identity: ParsedIdentityPort) { this.root = root; this.original = original; this.identity = identity; }
  async read(cancel: ParsedCancellation): Promise<Uint8Array> {
    const file: fileIo.File = await fileIo.open(documentAssetPath(this.root,this.original.assetId),fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
    try { const stat: fileIo.Stat = await fileIo.stat(file.fd); if (!stat.isFile() || stat.size !== this.original.bytes || stat.size < 1 || stat.size > 20971520) { throw new ParsedFailure('OriginalImageSize','producer'); }
      const bytes: Uint8Array = await documentReadRange(file.fd,0,stat.size); cancel.check(); if (await this.identity.hash(bytes) !== this.original.hash) { throw new ParsedFailure('OriginalImageHash','producer'); } return bytes;
    } finally { await fileIo.close(file); }
  }
}
class ParsedLocalTextProducer implements ParsedProducerPort {
  private original: TextOriginal; private files: TextFileAdapter; private identity: ParsedIdentityPort;
  constructor(original: TextOriginal, files: TextFileAdapter, identity: ParsedIdentityPort) { this.original = original; this.files = files; this.identity = identity; }
  async produce(request: ParsedImportRequest, document: string, generation: string, assets: ParsedAssetPort, cancel: ParsedCancellation): Promise<ParsedDocument> {
    const token: TextCancellation = new TextCancellation(); token.deadline = cancel.deadline;
    const raw: Uint8Array = await this.files.readOriginal(this.original,token); cancel.check();
    const adapter: ParsedDocumentAdapters = new ParsedDocumentAdapters(this.identity); adapter.setOutput(pdfStrictUtf8(raw),undefined,this.original.hash);
    return adapter.produce(request,document,generation,assets,cancel);
  }
}
export class ParsedDocumentImportAdapter {
  private root: string; private text: TextFileAdapter; private identity: KnowledgeIdentityPort; private ingestion: ParsedDocumentIngestionService;
  private budget: KnowledgeDerivedBudget;
  constructor(context: common.Context, host: KnowledgeStoreHost, identity: KnowledgeIdentityPort, ingestion: ParsedDocumentIngestionService) {
    this.root = `${context.filesDir}/knowledge_parse_v1`; this.text = new TextFileAdapter(context,host); this.identity = identity; this.ingestion = ingestion;
    this.budget = new KnowledgeDerivedBudget(context,host.storageScope);
  }
  async importText(): Promise<void> {
    const selection: TextSelection = await this.text.select(); if (selection.canceled) { return; }
    if (selection.files.length > 10 || selection.files.reduce((sum: number, f: TextSelectedFile): number => sum+f.bytes,0) > 5242880) { throw new ParsedFailure('TextBatchBudget','select'); }
    for (const file of selection.files) {
      if (file.bytes < 1 || file.bytes > 1048576) { throw new ParsedFailure('TextOriginalBudget','select'); }
      if (await this.budget.totalBytes()+file.bytes*2+1048576 > 524288000) { throw new ParsedFailure('SharedOriginalBudget','select'); }
      const cancel: TextCancellation = new TextCancellation(); const original: TextOriginal = await this.text.saveOriginal(file,'original-'+this.identity.id(),cancel);
      const request: ParsedImportRequest = new ParsedImportRequest(); request.namespace = 'Text'; request.sourceId = original.assetId; request.sourceHash = original.hash; request.title = file.name; request.format = ParsedFormat.Text;
      request.parserSignature = 'LOCAL-UTF8-MARKDOWN-UPD-1'; request.engine = 'Local'; request.outputIdentity = original.hash;
      const source: ParsedSourceAsset = new ParsedSourceAsset(); source.id = original.assetId; source.owner = 'TextFileAdapter'; source.role = 'original'; request.sources.push(source);
      await this.ingestion.ingest(request,new ParsedLocalTextProducer(original,this.text,this.identity));
    }
  }
  async consume(parse: DocumentParseService, resultId: string, rebuild: boolean = false): Promise<void> {
    await parse.withReceivedResult<void>(resultId,async (original: DocumentOriginal, result: DocumentParseResultEnvelope, task: DocumentParseTask): Promise<void> => {
      const request: ParsedImportRequest = new ParsedImportRequest(); request.namespace = original.format === DocumentParseFormat.Docx ? 'Docx' : original.format === DocumentParseFormat.Pdf ? 'Pdf' : 'Image';
      request.sourceId = original.id; request.sourceHash = original.hash; request.sourceVersion = original.version; request.title = original.title;
      request.format = original.format === DocumentParseFormat.Docx ? ParsedFormat.Docx : original.format === DocumentParseFormat.Pdf ? ParsedFormat.Pdf : ParsedFormat.Image;
      if ([DocumentParseFormat.Docx,DocumentParseFormat.Pdf,DocumentParseFormat.Jpeg,DocumentParseFormat.Png,DocumentParseFormat.Webp].indexOf(original.format) < 0) { throw new ParsedFailure('FormatNotEnabled','producer'); }
      const grant: DocumentParseGrant | undefined = parse.viewState().snapshot.grants?.find((g: DocumentParseGrant): boolean => g.id === task.grantId);
      request.parserSignature = `MINERU-REPORTED-UNVERSIONED-UPD-1|${grant?.parameters ?? 'ParametersNotRecorded'}`; request.engine = 'MinerU'; request.outputIdentity = `${task.id}|${task.dataId}|${result.hash}`;
      for (const id of [original.assetId,result.assetId]) { const source: ParsedSourceAsset = new ParsedSourceAsset(); source.id = id; source.owner = 'DocumentParseService'; source.role = id === original.assetId ? 'original' : 'result'; request.sources.push(source); }
      const binding: DocxResultBinding = new DocxResultBinding(); binding.taskId = task.id; binding.dataId = task.dataId; binding.assetId = result.assetId; binding.hash = result.hash; binding.bytes = result.bytes; binding.originalHash = original.hash; binding.originalVersion = original.version;
      const reader: DocxResultReader = new DocxResultReader(this.root,parse,this.identity); const cancel: KnowledgeCancellation = new KnowledgeCancellation(); cancel.deadline = Date.now()+900000;
      if (request.format === ParsedFormat.Docx) {
        const docx: DocxOriginal = new DocxOriginal(); docx.documentId = original.id; docx.sourceId = original.id; docx.assetId = original.assetId; docx.hash = original.hash; docx.version = original.version; docx.bytes = original.bytes; docx.title = original.title;
        await new DocxProcessingAdapter(this.root,this.identity,reader).withUnified<void>(docx,binding,cancel,async (adapter: ParsedDocumentAdapters): Promise<void> => { await this.ingestion.ingest(request,adapter,rebuild); });
      } else {
        await reader.withUnified<void>(binding,cancel,async (adapter: ParsedDocumentAdapters): Promise<void> => {
          if (request.format === ParsedFormat.Image) { const image: ParsedImageProduction = new ParsedImageProduction(new ParsedOriginalImageBytes(this.root,original,this.identity)); image.member = original.assetId; image.provenance = ParsedProvenance.Original;
            // The selected result is the existing OCR projection, not a new OCR call.
            image.ocr = ''; adapter.markBodyAsOcr(); adapter.addProduction(image); }
          await this.ingestion.ingest(request,adapter,rebuild);
        });
      }
    });
  }
  async preserveImage(parse: DocumentParseService, original: DocumentOriginal): Promise<void> {
    await parse.withImageOriginal<void>(original.id,async (): Promise<void> => {
      const raw: Uint8Array = await new ParsedOriginalImageBytes(this.root,original,this.identity).read(new ParsedCancellation());
      const header: ImageHeaderEvidence = await imageInspectHeader(new ParsedImportHeader(raw),'',new KnowledgeCancellation());
      const evidence: DocumentImageEvidence = new DocumentImageEvidence(); evidence.originalId = original.id; evidence.assetId = original.assetId; evidence.hash = original.hash; evidence.version = original.version;
      evidence.width = header.width; evidence.height = header.height; evidence.mime = header.mime; evidence.staticContainer = header.staticContainer; evidence.frames = 1; evidence.variant = header.variant;
      await parse.recordImageEvidence(evidence);
      const request: ParsedImportRequest = new ParsedImportRequest(); request.namespace = 'Image'; request.sourceId = original.id; request.sourceHash = original.hash; request.sourceVersion = original.version; request.title = original.title; request.format = ParsedFormat.Image;
      request.parserSignature = 'INDEPENDENT-IMAGE-UPD-1'; request.engine = 'Local'; request.outputIdentity = original.hash;
      const source: ParsedSourceAsset = new ParsedSourceAsset(); source.id = original.assetId; source.owner = 'DocumentParseService'; source.role = 'original'; request.sources = [source];
      const adapter: ParsedDocumentAdapters = new ParsedDocumentAdapters(this.identity); adapter.setOutput('',undefined,original.hash);
      const image: ParsedImageProduction = new ParsedImageProduction(new ParsedOriginalImageBytes(this.root,original,this.identity)); image.member = original.assetId; image.provenance = ParsedProvenance.Original; adapter.addProduction(image); await this.ingestion.ingest(request,adapter);
    });
  }
}
