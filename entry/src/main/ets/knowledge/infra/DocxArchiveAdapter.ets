import { fileIo } from '@kit.CoreFileKit';
import { KnowledgeRangeReader, KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { KnowledgeCancellation, PdfZipMember } from '../domain/PdfKnowledgeModels';
import { DocxArchivePort, DocxZipDirectory, DocxZipMember } from '../domain/DocxKnowledgePorts';
import { DocxFailure, DocxLimits, DocxPartEvidence } from '../domain/DocxKnowledgeModels';
import { docxInspectZip, docxResolvePart } from '../pipeline/DocxPackagePolicy';
import { DocxWorkerXmlAdapter } from './DocxXmlAdapter';
import { DocxXmlNode, DocxXmlPort, docxXmlAttr } from '../domain/DocxXmlModels';
import { pdfNativeReadMember, PdfExpansionAccount, PdfMemberSink } from './PdfNativeReader';
import { documentReadRange } from './DocumentFileOperations';

export class DocxFileRangeReader implements KnowledgeRangeReader {
  length: number; private file: fileIo.File; private closed: boolean = false;
  constructor(file: fileIo.File, length: number) { this.file = file; this.length = length; }
  async read(offset: number, length: number, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    cancel.check(); if (this.closed || !Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || length > DocxLimits.directory || offset+length > this.length) { throw new DocxFailure('ReadRangeInvalid','archive'); }
    return documentReadRange(this.file.fd,offset,length);
  }
  async close(): Promise<void> { if (!this.closed) { await fileIo.close(this.file); this.closed = true; } }
}
class DocxMemberCollector implements PdfMemberSink {
  private blocks: Uint8Array[] = []; private length: number = 0; private maximum: number;
  constructor(maximum: number) { this.maximum = maximum; }
  async accept(bytes: Uint8Array): Promise<void> {
    if (this.length+bytes.length > this.maximum) { throw new DocxFailure('SelectedMemberBudget','archive'); }
    this.blocks.push(bytes.slice()); this.length += bytes.length;
  }
  bytes(): Uint8Array { const result: Uint8Array = new Uint8Array(this.length); let at: number = 0; for (const block of this.blocks) { result.set(block,at); at += block.length; } this.blocks = []; return result; }
}
export class DocxArchiveAdapter implements DocxArchivePort {
  private reader: KnowledgeRangeReader | undefined = undefined; private directory: DocxZipDirectory | undefined = undefined;
  private account: PdfExpansionAccount = new PdfExpansionAccount(); verifiedParts: DocxPartEvidence[] = [];
  async inspect(reader: KnowledgeRangeReader, role: string, cancel: KnowledgeCancellation): Promise<DocxZipDirectory> {
    if (this.reader !== undefined) { throw new DocxFailure('ArchiveBusy','archive'); } this.reader = reader;
    try { this.directory = await docxInspectZip(reader,role,cancel); return this.directory; }
    catch (error) { await this.release(); if (error instanceof Error) { throw error; } throw new DocxFailure('ArchiveInspectFailed','archive'); }
  }
  async read(member: DocxZipMember, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    const reader: KnowledgeRangeReader | undefined = this.reader;
    const canonical: DocxZipMember | undefined = this.directory?.members.find((m: DocxZipMember): boolean => m === member);
    const maximum: number = member.name.endsWith('.xml') || member.name.endsWith('.rels') || member.name.endsWith('.md') ? DocxLimits.xml : 32*1024*1024;
    if (reader === undefined || canonical === undefined || member.name.endsWith('/') || member.expanded > maximum || this.account.actual+member.expanded > DocxLimits.expanded) { throw new DocxFailure('SelectedMemberIdentityOrBudget','archive'); }
    // PdfZipMember here is the existing raw ZIP member transport DTO only, not a PDF source/page/manifest binding.
    const raw: PdfZipMember = new PdfZipMember(); raw.method = member.method; raw.flags = member.flags; raw.localOffset = member.localOffset; raw.payloadOffset = member.dataOffset; raw.compressedBytes = member.compressed; raw.declaredBytes = member.expanded; raw.crc32 = member.crc;
    const sink: DocxMemberCollector = new DocxMemberCollector(maximum); await pdfNativeReadMember(reader,raw,sink,this.account,cancel);
    const evidence: DocxPartEvidence = new DocxPartEvidence(); evidence.part = member.name; evidence.hash = raw.sha256; evidence.bytes = raw.actualBytes; evidence.crcVerified = raw.verified;
    this.verifiedParts.push(evidence); return sink.bytes();
  }
  async release(): Promise<void> { if (this.reader !== undefined) { await this.reader.close(); this.reader = undefined; } this.directory = undefined; this.account = new PdfExpansionAccount(); }
}
export async function docxOpenVerified(path: string, length: number, hash: string, identity: KnowledgeIdentityPort, cancel: KnowledgeCancellation): Promise<DocxFileRangeReader> {
  const file: fileIo.File = await fileIo.open(path,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
  try {
    const stat: fileIo.Stat = await fileIo.stat(file.fd); if (!stat.isFile() || stat.size !== length || length < 22 || length > 30*1024*1024) { throw new DocxFailure('PackageIdentityInvalid','archive'); }
    // Whole-file digest uses the caller's bounded identity port; no original rewriting.
    const bytes: Uint8Array = await documentReadRange(file.fd,0,length); cancel.check();
    if (await identity.hash(bytes) !== hash) { throw new DocxFailure('PackageHashMismatch','archive'); }
    return new DocxFileRangeReader(file,length);
  } catch (error) { await fileIo.close(file); if (error instanceof Error) { throw error; } throw new DocxFailure('PackageOpenFailed','archive'); }
}
export async function docxPackageMain(archive: DocxArchivePort, directory: DocxZipDirectory, parser: DocxXmlPort, cancel: KnowledgeCancellation): Promise<string> {
  const types: DocxZipMember | undefined = directory.members.find((m: DocxZipMember): boolean => m.name === '[Content_Types].xml');
  const rels: DocxZipMember | undefined = directory.members.find((m: DocxZipMember): boolean => m.name === '_rels/.rels');
  if (types === undefined || rels === undefined) { throw new DocxFailure('OoxmlRootIdentityMissing','identity'); }
  const relation: DocxXmlNode = await parser.parse(await archive.read(rels,cancel),cancel);
  if (relation.localName !== 'Relationships' || relation.namespace !== 'http://schemas.openxmlformats.org/package/2006/relationships') { throw new DocxFailure('OoxmlRelationshipRoot','identity'); }
  const office: DocxXmlNode[] = relation.children.filter((n: DocxXmlNode): boolean => n.namespace === relation.namespace && n.localName === 'Relationship' && ['http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument','http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument'].indexOf(docxXmlAttr(n,'','Type') ?? '') >= 0);
  if (office.length !== 1 || docxXmlAttr(office[0],'','TargetMode') === 'External') { throw new DocxFailure('OrdinaryWordMainRelationshipRequired','identity'); }
  const main: string = docxResolvePart('',docxXmlAttr(office[0],'','Target') ?? '');
  if (directory.members.filter((m: DocxZipMember): boolean => m.name === main).length !== 1) { throw new DocxFailure('WordMainPartMissing','identity'); }
  const content: DocxXmlNode = await parser.parse(await archive.read(types,cancel),cancel);
  if (content.namespace !== 'http://schemas.openxmlformats.org/package/2006/content-types' || content.localName !== 'Types') { throw new DocxFailure('ContentTypesRoot','identity'); }
  const declarations: DocxXmlNode[] = content.children.filter((n: DocxXmlNode): boolean => n.namespace === content.namespace && n.localName === 'Override' && docxXmlAttr(n,'','PartName') === '/'+main);
  if (declarations.length !== 1 || docxXmlAttr(declarations[0],'','ContentType') !== 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml') { throw new DocxFailure('OrdinaryDocxContentTypeRequired','identity'); }
  return main;
}
export async function docxPreflightPath(path: string, length: number): Promise<string> {
  const file: fileIo.File = await fileIo.open(path,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
  const archive: DocxArchiveAdapter = new DocxArchiveAdapter(); const cancel: KnowledgeCancellation = new KnowledgeCancellation();
  try { const directory: DocxZipDirectory = await archive.inspect(new DocxFileRangeReader(file,length),'Original',cancel); return await docxPackageMain(archive,directory,new DocxWorkerXmlAdapter(),cancel); }
  finally { await archive.release(); }
}
