import { DocxArchivePort, DocxZipDirectory, DocxZipMember, DocxResultPort } from '../domain/DocxKnowledgePorts';
import { DocxResultBinding, DocxProjection, DocxFailure, docxHash, docxId } from '../domain/DocxKnowledgeModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { DocxArchiveAdapter, docxOpenVerified } from './DocxArchiveAdapter';
import { DocumentParseService } from '../application/DocumentParseService';
import { DocumentParseResultEnvelope, DocumentParseTask, DocumentParseStage, DocumentParseCleanup } from '../domain/DocumentParseModels';
import { documentAssetPath } from './DocumentFileOperations';
import { pdfStrictUtf8 } from '../pipeline/SafeZipPolicy';
import { docxProjectMarkdown } from '../pipeline/DocxCorrespondence';
import { taskpool } from '@kit.ArkTS';
import { DocxProjectionWorkerResult } from '../domain/DocxXmlModels';
import { ParsedDocumentAdapters, ParsedImageProduction } from './ParsedDocumentAdapters';
import { ParsedCancellation, ParsedProvenance, ParsedFailure } from '../domain/ParsedDocumentModels';
import { ParsedImageBytesPort } from '../domain/ParsedDocumentPorts';

export class ParsedArchiveImageBytes implements ParsedImageBytesPort {
  private archive: DocxArchivePort; private member: DocxZipMember;
  constructor(archive: DocxArchivePort, member: DocxZipMember) { this.archive = archive; this.member = member; }
  async read(cancel: ParsedCancellation): Promise<Uint8Array> { const token: KnowledgeCancellation = new KnowledgeCancellation(); token.deadline = cancel.deadline; cancel.check(); const bytes: Uint8Array = await this.archive.read(this.member,token); cancel.check(); return bytes; }
}
export async function docxReadUnifiedOutput(archive: DocxArchivePort, directory: DocxZipDirectory, identity: KnowledgeIdentityPort, cancel: KnowledgeCancellation): Promise<ParsedDocumentAdapters> {
  const md: DocxZipMember[] = directory.members.filter((m: DocxZipMember): boolean => ['full.md','markdown.md'].indexOf(m.name.split('/').pop() ?? '') >= 0);
  if (md.length > 1) { throw new ParsedFailure('AmbiguousMarkdownMember','output'); }
  const lists: DocxZipMember[] = directory.members.filter((m: DocxZipMember): boolean => m.name.endsWith('_content_list_v2.json'));
  const v1: DocxZipMember[] = directory.members.filter((m: DocxZipMember): boolean => m.name.endsWith('_content_list.json'));
  const selected: DocxZipMember[] = lists.length > 0 ? lists : v1;
  if (selected.length > 1) { throw new ParsedFailure('AmbiguousContentList','output'); }
  if (md.length === 0 && selected.length === 0) { throw new ParsedFailure('SupportedOutputMissing','output'); }
  const a: ParsedDocumentAdapters = new ParsedDocumentAdapters(identity);
  const markdown: string = md.length > 0 ? pdfStrictUtf8(await archive.read(md[0],cancel)) : '';
  let content: Uint8Array | undefined;
  if (selected.length > 0) {
    try { content = await archive.read(selected[0],cancel); }
    catch (error) { cancel.check(); if (markdown.trim().length === 0) { if (error instanceof Error) { throw error; } throw new DocxFailure('StructuredMemberUnreadable','output'); } a.addWarning('StructuredMemberUnavailableMarkdownPreserved'); }
  }
  a.setOutput(markdown,content,md[0]?.name ?? selected[0]?.name ?? '');
  a.setOutputBase(md[0]?.name ?? selected[0]?.name ?? '');
  for (const member of directory.members) {
    if (member.name.endsWith('/') || !member.name.split('/').includes('images')) { continue; }
    const image: ParsedImageProduction = new ParsedImageProduction(new ParsedArchiveImageBytes(archive,member)); image.member = member.name; image.provenance = ParsedProvenance.Derived; a.addProduction(image);
  }
  return a;
}

@Concurrent
function docxProjectionWorker(bytes: Uint8Array, member: string, hash: string, deadline: number): DocxProjectionWorkerResult {
  const result: DocxProjectionWorkerResult = new DocxProjectionWorkerResult(); const cancel: KnowledgeCancellation = new KnowledgeCancellation(); cancel.deadline = deadline;
  try { result.projection = docxProjectMarkdown(pdfStrictUtf8(bytes),member,hash,cancel); } catch (error) { result.failure = error instanceof DocxFailure ? error.category : 'MarkdownProjectionFailed'; } return result;
}

export class DocxResultReader implements DocxResultPort {
  private root: string; private parse: DocumentParseService; private identity: KnowledgeIdentityPort;
  private pending: DocxArchiveAdapter | undefined = undefined;
  constructor(root: string, parse: DocumentParseService, identity: KnowledgeIdentityPort) { this.root = root; this.parse = parse; this.identity = identity; }
  async read(binding: DocxResultBinding, cancel: KnowledgeCancellation): Promise<DocxProjection> {
    if (this.pending !== undefined) { throw new DocxFailure('ProcessingResourceReleaseUnconfirmed','result'); }
    const state = this.parse.viewState().snapshot;
    const task: DocumentParseTask | undefined = state.tasks.find((t: DocumentParseTask): boolean => t.id === binding.taskId && t.dataId === binding.dataId && t.hash === binding.originalHash && t.version === binding.originalVersion && t.stage === DocumentParseStage.Received);
    const received: DocumentParseResultEnvelope | undefined = state.results.find((r: DocumentParseResultEnvelope): boolean => r.assetId === binding.assetId && r.taskId === binding.taskId && r.dataId === binding.dataId && r.hash === binding.hash && r.bytes === binding.bytes && r.originalHash === binding.originalHash && r.version === binding.originalVersion && r.completeTransport && r.signature);
    if (task === undefined || received === undefined || !docxId(binding.assetId) || !docxHash(binding.hash)) { throw new DocxFailure('ReceivedResultOwnerBindingMissing','result'); }
    const archive: DocxArchiveAdapter = new DocxArchiveAdapter();
    try {
      const directory: DocxZipDirectory = await archive.inspect(await docxOpenVerified(documentAssetPath(this.root,binding.assetId),binding.bytes,binding.hash,this.identity,cancel),'Result',cancel);
      return await docxReadMarkdownResult(archive,directory,this.identity,cancel);
    } finally { try { await archive.release(); } catch { this.pending = archive; throw new DocxFailure('ProcessingResourceReleaseUnconfirmed','result'); } }
  }
  async retryRelease(): Promise<void> { if (this.pending !== undefined) { await this.pending.release(); this.pending = undefined; } }
  async withUnified<T>(binding: DocxResultBinding, cancel: KnowledgeCancellation, action: (adapter: ParsedDocumentAdapters) => Promise<T>): Promise<T> {
    const state = this.parse.viewState().snapshot;
    const task: DocumentParseTask | undefined = state.tasks.find((t: DocumentParseTask): boolean => t.id === binding.taskId && t.dataId === binding.dataId && t.hash === binding.originalHash && t.version === binding.originalVersion);
    const received: DocumentParseResultEnvelope | undefined = state.results.find((r: DocumentParseResultEnvelope): boolean => r.assetId === binding.assetId && r.hash === binding.hash && r.taskId === binding.taskId && r.originalHash === binding.originalHash && r.version === binding.originalVersion && r.completeTransport && r.signature);
    if (task === undefined || received === undefined || state.cleanup.some((c: DocumentParseCleanup): boolean => c.assets.indexOf(binding.assetId) >= 0)) { throw new ParsedFailure('ReceivedResultOwnerBindingMissing','unified-result'); }
    const archive: DocxArchiveAdapter = new DocxArchiveAdapter();
    try {
      const directory: DocxZipDirectory = await archive.inspect(await docxOpenVerified(documentAssetPath(this.root,binding.assetId),binding.bytes,binding.hash,this.identity,cancel),'Result',cancel);
      return await action(await docxReadUnifiedOutput(archive,directory,this.identity,cancel));
    } finally { await archive.release(); }
  }
}
export async function docxReadMarkdownResult(archive: DocxArchivePort, directory: DocxZipDirectory, identity: KnowledgeIdentityPort, cancel: KnowledgeCancellation): Promise<DocxProjection> {
  const members: DocxZipMember[] = directory.members.filter((m: DocxZipMember): boolean => ['full.md','markdown.md'].indexOf(m.name.split('/').pop() ?? '') >= 0);
  if (members.length !== 1) { throw new DocxFailure(members.length === 0 ? 'SupportedResultProjectionNotFound' : 'ResultProjectionAmbiguous','result'); }
  const bytes: Uint8Array = await archive.read(members[0],cancel); cancel.check();
  const task: taskpool.GenericsTask<[Uint8Array,string,string,number],DocxProjectionWorkerResult> = new taskpool.GenericsTask<[Uint8Array,string,string,number],DocxProjectionWorkerResult>(docxProjectionWorker,bytes,members[0].name,await identity.hash(bytes),cancel.deadline);
  const result: DocxProjectionWorkerResult = await taskpool.execute<[Uint8Array,string,string,number],DocxProjectionWorkerResult>(task); cancel.check(); if (result.failure.length > 0) { throw new DocxFailure(result.failure,'result'); } return result.projection;
}
