import { taskpool } from '@kit.ArkTS';
import { DocxProcessingPort, DocxZipDirectory, DocxZipMember, DocxResultPort } from '../domain/DocxKnowledgePorts';
import { DocxOriginal, DocxSnapshot, DocxResultBinding, DocxRelationship, DocxFailure, DocxCoverageIssue, DocxCoverageKind } from '../domain/DocxKnowledgeModels';
import { DocxXmlNode, docxXmlAttr, DocxNativeWorkerInput, DocxNativeWorkerResult } from '../domain/DocxXmlModels';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { DocxArchiveAdapter, docxOpenVerified, docxPackageMain } from './DocxArchiveAdapter';
import { DocxXmlAdapter } from './DocxXmlAdapter';
import { documentAssetPath } from './DocumentFileOperations';
import { docxResolvePart } from '../pipeline/DocxPackagePolicy';
import { docxReadNative, docxReadUnifiedNative } from '../pipeline/DocxNativeReader';
import { docxCorrespond } from '../pipeline/DocxCorrespondence';
import { docxSealSnapshot } from '../pipeline/DocxSnapshotCodec';
import { DocxResultReader, ParsedArchiveImageBytes } from './DocxResultReader';
import { ParsedDocumentAdapters, ParsedImageProduction } from './ParsedDocumentAdapters';
import { ParsedProvenance } from '../domain/ParsedDocumentModels';
import { ParsedOutputProjection, ParsedOutputImageLink } from '../pipeline/ParsedOutputDecoder';

@Concurrent
function docxNativeWorker(input: DocxNativeWorkerInput, deadline: number): DocxNativeWorkerResult {
  const result: DocxNativeWorkerResult = new DocxNativeWorkerResult(); const cancel: KnowledgeCancellation = new KnowledgeCancellation(); cancel.deadline = deadline;
  try { result.snapshot = docxReadNative(input.original,input.root,input.styles,input.numbering,input.relationships,cancel); } catch (error) { result.failure = error instanceof DocxFailure ? error.category : 'NativeWorkerFailed'; } return result;
}
@Concurrent
function docxCorrespondWorker(snapshot: DocxSnapshot, deadline: number): DocxNativeWorkerResult {
  const result: DocxNativeWorkerResult = new DocxNativeWorkerResult(); const cancel: KnowledgeCancellation = new KnowledgeCancellation(); cancel.deadline = deadline;
  try { docxCorrespond(snapshot,cancel); result.snapshot = snapshot; } catch (error) { result.failure = error instanceof DocxFailure ? error.category : 'CorrespondenceWorkerFailed'; } return result;
}
export class DocxProcessingAdapter implements DocxProcessingPort {
  private root: string; private identity: KnowledgeIdentityPort; private results: DocxResultPort; private current: KnowledgeCancellation | undefined = undefined;
  private pendingArchive: DocxArchiveAdapter | undefined = undefined;
  constructor(root: string, identity: KnowledgeIdentityPort, results: DocxResultPort) { this.root = root; this.identity = identity; this.results = results; }
  cancel(): void { if (this.current !== undefined) { this.current.invalid = true; } }
  async retryRelease(): Promise<void> { if (this.pendingArchive !== undefined) { await this.pendingArchive.release(); this.pendingArchive = undefined; } await this.results.retryRelease?.(); }
  async withUnified<T>(original: DocxOriginal, result: DocxResultBinding, cancel: KnowledgeCancellation, action: (adapter: ParsedDocumentAdapters) => Promise<T>): Promise<T> {
    const results = this.results;
    if (!(results instanceof DocxResultReader)) { throw new DocxFailure('UnifiedResultReaderRequired','unified'); }
    return results.withUnified<T>(result,cancel,async (adapter: ParsedDocumentAdapters): Promise<T> => {
      const archive: DocxArchiveAdapter = new DocxArchiveAdapter();
      try {
        try {
          const directory: DocxZipDirectory = await archive.inspect(await docxOpenVerified(documentAssetPath(this.root,original.assetId),original.bytes,original.hash,this.identity,cancel),'Original',cancel);
          // Media recovery does not depend on native XML/correspondence succeeding.
          for (const media of directory.members) {
            if (media.name.endsWith('/') || !media.name.split('/').includes('media')) { continue; }
            const image: ParsedImageProduction = new ParsedImageProduction(new ParsedArchiveImageBytes(archive,media)); image.member = media.name; image.provenance = ParsedProvenance.Native; adapter.addProduction(image);
          }
          const parser: DocxXmlAdapter = new DocxXmlAdapter(); const main: string = await docxPackageMain(archive,directory,parser,cancel);
          const member: DocxZipMember | undefined = directory.members.find((m: DocxZipMember): boolean => m.name === main);
          if (member === undefined) { throw new DocxFailure('MainPartMissing','unified'); }
          const root: DocxXmlNode = await parser.parse(await archive.read(member,cancel),cancel);
          const relName: string = main.slice(0,main.lastIndexOf('/')+1)+'_rels/'+main.slice(main.lastIndexOf('/')+1)+'.rels';
          const relMember: DocxZipMember | undefined = directory.members.find((m: DocxZipMember): boolean => m.name === relName);
          const relationships: DocxRelationship[] = [];
          if (relMember !== undefined) {
            const relRoot: DocxXmlNode = await parser.parse(await archive.read(relMember,cancel),cancel);
            if (relRoot.localName !== 'Relationships' || relRoot.namespace !== 'http://schemas.openxmlformats.org/package/2006/relationships') { throw new DocxFailure('RelationshipsRootInvalid','unified'); }
            for (const n of relRoot.children) {
              if (n.localName !== 'Relationship' || n.namespace !== relRoot.namespace) { continue; }
              const r: DocxRelationship = new DocxRelationship(); r.id = docxXmlAttr(n,'','Id') ?? ''; r.sourcePart = main; r.type = docxXmlAttr(n,'','Type') ?? '';
              r.external = docxXmlAttr(n,'','TargetMode') === 'External'; r.target = r.external ? docxXmlAttr(n,'','Target') ?? '' : docxResolvePart(main,docxXmlAttr(n,'','Target') ?? ''); relationships.push(r);
            }
          }
          const native: ParsedOutputProjection = docxReadUnifiedNative(root,relationships,cancel); adapter.setNative(native);
        } catch (error) { cancel.check(); const partial: ParsedOutputProjection = new ParsedOutputProjection(); partial.warnings = ['NativeEnhancementUnavailableParserBodyPreserved']; adapter.setNative(partial); }
        return await action(adapter);
      } finally { await archive.release(); }
    });
  }
  async prepare(original: DocxOriginal, result: DocxResultBinding, generation: string, cancel: KnowledgeCancellation): Promise<DocxSnapshot> {
    if (this.current !== undefined || this.pendingArchive !== undefined) { throw new DocxFailure('ProcessingBusyOrReleasePending','prepare'); } this.current = cancel;
    const archive: DocxArchiveAdapter = new DocxArchiveAdapter(); const parser: DocxXmlAdapter = new DocxXmlAdapter();
    try {
      const directory: DocxZipDirectory = await archive.inspect(await docxOpenVerified(documentAssetPath(this.root,original.assetId),original.bytes,original.hash,this.identity,cancel),'Original',cancel);
      const main: string = await docxPackageMain(archive,directory,parser,cancel); original.mainPart = main;
      const member: DocxZipMember | undefined = directory.members.find((m: DocxZipMember): boolean => m.name === main); if (member === undefined) { throw new DocxFailure('MainPartMissing','prepare'); }
      const root: DocxXmlNode = await parser.parse(await archive.read(member,cancel),cancel);
      const slash: number = main.lastIndexOf('/'); const relName: string = (slash < 0 ? '' : main.slice(0,slash+1))+'_rels/'+main.slice(slash+1)+'.rels';
      const relMember: DocxZipMember | undefined = directory.members.find((m: DocxZipMember): boolean => m.name === relName); const relationships: DocxRelationship[] = [];
      if (relMember !== undefined) {
        const relRoot: DocxXmlNode = await parser.parse(await archive.read(relMember,cancel),cancel);
        if (relRoot.localName !== 'Relationships' || relRoot.namespace !== 'http://schemas.openxmlformats.org/package/2006/relationships') { throw new DocxFailure('RelationshipsRootInvalid','prepare'); }
        for (const n of relRoot.children) {
          if (n.localName !== 'Relationship' || n.namespace !== relRoot.namespace) { continue; }
          const rel: DocxRelationship = new DocxRelationship(); rel.sourcePart = main; rel.id = docxXmlAttr(n,'','Id') ?? ''; rel.type = docxXmlAttr(n,'','Type') ?? ''; rel.external = docxXmlAttr(n,'','TargetMode') === 'External';
          rel.target = rel.external ? docxXmlAttr(n,'','Target') ?? '' : docxResolvePart(main,docxXmlAttr(n,'','Target') ?? '');
          if (rel.id.length === 0 || relationships.some((r: DocxRelationship): boolean => r.id === rel.id)) { throw new DocxFailure('RelationshipIdInvalid','prepare'); } relationships.push(rel);
        }
      }
      let styles: DocxXmlNode | undefined = undefined; let numbering: DocxXmlNode | undefined = undefined;
      for (const type of ['styles','numbering']) {
        const rels: DocxRelationship[] = relationships.filter((r: DocxRelationship): boolean => !r.external && r.type.endsWith('/'+type));
        if (rels.length > 1) { throw new DocxFailure('RequiredRelationshipAmbiguous','prepare'); }
        if (rels.length === 1) {
          const part: DocxZipMember | undefined = directory.members.find((m: DocxZipMember): boolean => m.name === rels[0].target); if (part === undefined) { throw new DocxFailure('ReferencedPartMissing','prepare'); }
          const tree: DocxXmlNode = await parser.parse(await archive.read(part,cancel),cancel); if (type === 'styles') { styles = tree; } else { numbering = tree; }
        }
      }
      const input: DocxNativeWorkerInput = new DocxNativeWorkerInput(); input.original = original; input.root = root; input.styles = styles; input.numbering = numbering; input.relationships = relationships;
      const task: taskpool.GenericsTask<[DocxNativeWorkerInput,number],DocxNativeWorkerResult> = new taskpool.GenericsTask<[DocxNativeWorkerInput,number],DocxNativeWorkerResult>(docxNativeWorker,input,cancel.deadline);
      const native: DocxNativeWorkerResult = await taskpool.execute<[DocxNativeWorkerInput,number],DocxNativeWorkerResult>(task); cancel.check(); if (native.failure.length > 0) { throw new DocxFailure(native.failure,'prepare'); }
      const s: DocxSnapshot = native.snapshot; s.generation = generation; s.result = result;
      for (const media of s.media) {
        if (media.external || media.targetPart.length === 0) { continue; }
        const part: DocxZipMember | undefined = directory.members.find((m: DocxZipMember): boolean => m.name === media.targetPart);
        if (part !== undefined && part.expanded <= 32*1024*1024) { media.hash = await this.identity.hash(await archive.read(part,cancel)); }
        else { const issue: DocxCoverageIssue = new DocxCoverageIssue(); issue.kind = DocxCoverageKind.Unsupported; issue.code = part === undefined ? 'ReferencedMediaMissing' : 'ReferencedMediaMemberBudget'; issue.part = main; issue.nodeId = media.parentId; issue.path = media.parentPath; s.coverage.issues.push(issue); s.coverage.unsupported++; }
      }
      for (const rel of relationships) {
        if (['/header','/footer','/comments'].some((suffix: string): boolean => rel.type.endsWith(suffix))) {
          const issue: DocxCoverageIssue = new DocxCoverageIssue(); issue.kind = DocxCoverageKind.Excluded; issue.code = 'AuxiliaryPartNotIndexed'; issue.part = rel.target; s.coverage.issues.push(issue); s.coverage.excluded++;
        }
      }
      s.parts = archive.verifiedParts.slice(); s.projection = await this.results.read(result,cancel);
      const corresponding: taskpool.GenericsTask<[DocxSnapshot,number],DocxNativeWorkerResult> = new taskpool.GenericsTask<[DocxSnapshot,number],DocxNativeWorkerResult>(docxCorrespondWorker,s,cancel.deadline);
      const matched: DocxNativeWorkerResult = await taskpool.execute<[DocxSnapshot,number],DocxNativeWorkerResult>(corresponding); cancel.check(); if (matched.failure.length > 0) { throw new DocxFailure(matched.failure,'correspondence'); }
      await docxSealSnapshot(matched.snapshot,this.identity,cancel); cancel.check(); return matched.snapshot;
    } finally {
      try { await archive.release(); } catch { this.pendingArchive = archive; throw new DocxFailure('ProcessingResourceReleaseUnconfirmed','prepare'); }
      finally { this.current = undefined; }
    }
  }
}
