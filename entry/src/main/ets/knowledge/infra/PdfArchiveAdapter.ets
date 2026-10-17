import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo, ReadOptions } from '@kit.CoreFileKit';
import { PdfArchivePort, KnowledgeRangeReader } from '../domain/KnowledgePorts';
import { PdfSourceBinding, PdfZipManifest, PdfZipMember, PdfBudget, KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { pdfInspectZip, pdfZipReserve } from '../pipeline/SafeZipPolicy';
import { documentAssetPath, documentDigestHex } from './DocumentFileOperations';
import { documentHashFile } from './DocumentFileOperations';
import { DocumentParseCancellation } from '../domain/DocumentParseModels';
import { pdfNativeReadMember, PdfExpansionAccount, PdfMemberSink } from './PdfNativeReader';
import { KnowledgeCapabilityService } from './KnowledgeCapabilityService';

class PdfFileRangeReader implements KnowledgeRangeReader {
  length: number = 0; private file: fileIo.File;
  constructor(file: fileIo.File, length: number) { this.file = file; this.length = length; }
  async read(offset: number, length: number, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    cancel.check();
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || offset+length > this.length || length > 1048576) { throw new KnowledgeFailure('ReadRange','archive'); }
    const output: Uint8Array = new Uint8Array(length); let done: number = 0;
    while (done < length) {
      cancel.check(); const buffer: ArrayBuffer = new ArrayBuffer(Math.min(65536,length-done));
      const options: ReadOptions = { offset: offset+done, length: buffer.byteLength }; const read: number = await fileIo.read(this.file.fd,buffer,options);
      if (read < 1 || read > buffer.byteLength) { throw new KnowledgeFailure('FileTruncated','archive'); }
      output.set(new Uint8Array(buffer,0,read),done); done += read;
    } return output;
  }
  async close(): Promise<void> { await fileIo.close(this.file); }
}
class PdfDiscardMemberSink implements PdfMemberSink { async accept(_bytes: Uint8Array): Promise<void> {} }
class PdfCollectMemberSink implements PdfMemberSink {
  blocks: Uint8Array[] = []; length: number = 0; private limit: number;
  constructor(limit: number) { this.limit = limit; }
  async accept(bytes: Uint8Array): Promise<void> { this.length = pdfZipReserve(this.length,bytes.length,this.limit); this.blocks.push(bytes.slice()); }
  bytes(): Uint8Array { const bytes: Uint8Array = new Uint8Array(this.length); let at: number = 0; for (const block of this.blocks) { bytes.set(block,at); at += block.length; } this.blocks = []; return bytes; }
}
export class PdfArchiveAdapter implements PdfArchivePort {
  private root: string; private reader: KnowledgeRangeReader | undefined = undefined;
  private verifiedManifest: PdfZipManifest | undefined = undefined;
  constructor(filesDir: string) { this.root = `${filesDir}/knowledge_parse_v1`; }
  capability(): string { return KnowledgeCapabilityService.archive().state; }
  async inspect(binding: PdfSourceBinding, cancel: KnowledgeCancellation): Promise<PdfZipManifest> {
    await KnowledgeCapabilityService.requireArchive(); cancel.check();
    return this.inspectForPlatformEvidence(binding,cancel);
  }
  async inspectForPlatformEvidence(binding: PdfSourceBinding, cancel: KnowledgeCancellation): Promise<PdfZipManifest> {
    if (this.reader !== undefined) { throw new KnowledgeFailure('ArchiveBusy','archive'); }
    const hashCancel: DocumentParseCancellation = new DocumentParseCancellation(); hashCancel.deadline = cancel.deadline;
    if (await documentHashFile(documentAssetPath(this.root,binding.originalAssetId),PdfBudget.originalBytes,hashCancel) !== binding.originalHash) { throw new KnowledgeFailure('OriginalHashMismatch','archive'); } cancel.check();
    const file: fileIo.File = await fileIo.open(documentAssetPath(this.root,binding.resultAssetId),fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
    let stat: fileIo.Stat;
    try { stat = await fileIo.stat(file.fd); } catch (error) { await fileIo.close(file); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('ZipStatFailed','archive'); }
    if (!stat.isFile() || stat.size !== binding.zipBytes || stat.size > PdfBudget.zipBytes) { await fileIo.close(file); throw new KnowledgeFailure('ZipIdentity','archive'); }
    const reader: PdfFileRangeReader = new PdfFileRangeReader(file,stat.size); this.reader = reader;
    try {
      const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      for (let at: number = 0; at < reader.length; at += 65536) { const blob: cryptoFramework.DataBlob = { data: await reader.read(at,Math.min(65536,reader.length-at),cancel) }; await digest.update(blob); }
      if (documentDigestHex((await digest.digest()).data) !== binding.zipHash) { throw new KnowledgeFailure('ZipHashMismatch','archive'); }
      const manifest: PdfZipManifest = await pdfInspectZip(reader,cancel); manifest.zipHash = binding.zipHash; manifest.id = 'archive-'+documentDigestHex(cryptoFramework.createRandom().generateRandomSync(16).data);
      const account: PdfExpansionAccount = new PdfExpansionAccount();
      for (const member of manifest.members) { await pdfNativeReadMember(reader,member,new PdfDiscardMemberSink(),account,cancel); }
      manifest.expandedBytes = account.actual; manifest.hardPassed = true; this.verifiedManifest = manifest; return manifest;
    } catch (error) { await this.release(); if (error instanceof Error) { throw error; } throw new KnowledgeFailure('ArchiveFailed','archive'); }
  }
  async readMember(manifest: PdfZipManifest, member: PdfZipMember, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    const verified: PdfZipManifest | undefined = this.verifiedManifest;
    const canonical: PdfZipMember | undefined = verified?.members.find((row: PdfZipMember): boolean => row.id === member.id);
    if (this.reader === undefined || verified === undefined || manifest.id !== verified.id || manifest.zipHash !== verified.zipHash || !manifest.hardPassed || !verified.hardPassed || canonical === undefined || !member.verified || !canonical.verified || canonical.sha256 !== member.sha256 || canonical.payloadOffset !== member.payloadOffset || canonical.compressedBytes !== member.compressedBytes || canonical.declaredBytes !== member.declaredBytes || canonical.crc32 !== member.crc32 || canonical.method !== member.method || canonical.logicalName !== member.logicalName) { throw new KnowledgeFailure('UnverifiedMember','archive'); }
    const sink: PdfCollectMemberSink = new PdfCollectMemberSink(member.logicalName.endsWith('.json') ? PdfBudget.jsonBytes : PdfBudget.memberBytes);
    const hash: string = canonical.sha256; await pdfNativeReadMember(this.reader,canonical,sink,new PdfExpansionAccount(),cancel);
    if (hash !== canonical.sha256) { throw new KnowledgeFailure('MemberChanged','archive'); } return sink.bytes();
  }
  async release(): Promise<void> { const reader: KnowledgeRangeReader | undefined = this.reader; this.verifiedManifest = undefined; await reader?.close(); this.reader = undefined; }
}
