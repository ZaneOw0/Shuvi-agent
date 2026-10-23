import { zlib } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { KnowledgeRangeReader } from '../domain/KnowledgePorts';
import { PdfZipMember, PdfBudget, KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { pdfZipReserve } from '../pipeline/SafeZipPolicy';
import { documentDigestHex } from './DocumentFileOperations';

export interface PdfMemberSink { accept(bytes: Uint8Array): Promise<void>; }
export class PdfExpansionAccount { actual: number = 0; }
export class PdfNativeAudit {
  calls: number = 0; consumed: number = 0; produced: number = 0; residualCalls: number = 0;
  streamEnd: boolean = false; releaseStatus: number = -999;
}
function pdfNativeCounter(value: number | undefined): number {
  if (value === undefined || !Number.isSafeInteger(value) || value < 0) { throw new KnowledgeFailure('NativeCounterUnverified','inflate'); } return value;
}
export async function pdfNativeReadMember(reader: KnowledgeRangeReader, member: PdfZipMember, sink: PdfMemberSink, account: PdfExpansionAccount, cancel: KnowledgeCancellation, audit: PdfNativeAudit = new PdfNativeAudit()): Promise<void> {
  if (member.method !== 0 && member.method !== 8) { throw new KnowledgeFailure('CompressionUnsupported','inflate'); }
  const checksum: zlib.Checksum = await zlib.createChecksum(); const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  let crc: number = 0; let actual: number = 0; let loaded: number = 0; let consumed: number = 0;
  let zip: zlib.Zip | undefined = undefined; let initialized: boolean = false;
  try {
    if (member.method === 8) {
      zip = await zlib.createZip(); const initial: zlib.ZStream = {};
      if (await zip.inflateInit2(initial,-15) !== zlib.ReturnStatus.OK) { throw new KnowledgeFailure('NativeInitRejected','inflate'); } initialized = true;
    }
    let ended: boolean = member.method === 0; let available: number = 0;
    while (member.method === 0 ? loaded < member.compressedBytes : !ended) {
      cancel.check(); let input: Uint8Array | undefined = undefined;
      if (available === 0 && loaded < member.compressedBytes) {
        const requested: number = Math.min(65536,member.compressedBytes-loaded);
        input = await reader.read(member.payloadOffset+loaded,requested,cancel);
        if (input.length !== requested) { throw new KnowledgeFailure('FileTruncated','inflate'); }
        loaded += input.length; available = input.length;
      }
      let output: Uint8Array;
      if (member.method === 0) { if (input === undefined) { throw new KnowledgeFailure('StoredProgress','archive'); } output = input; consumed += input.length; available = 0; }
      else {
        if (zip === undefined) { throw new KnowledgeFailure('NativeMissing','inflate'); }
        const buffer: ArrayBuffer = new ArrayBuffer(65536);
        const stream: zlib.ZStream = { nextOut: buffer, availableOut: buffer.byteLength };
        if (input !== undefined) {
          const inputBuffer: ArrayBuffer = new ArrayBuffer(input.length); new Uint8Array(inputBuffer).set(input);
          stream.nextIn = inputBuffer; stream.availableIn = input.length;
        }
        const beforeIn: number = consumed; const beforeOut: number = actual;
        const status: zlib.ReturnStatus = await zip.inflate(stream,zlib.CompressFlushMode.NO_FLUSH); audit.calls++;
        cancel.check(); const state: zlib.ZStream = await zip.getZStream();
        const totalIn: number = pdfNativeCounter(state.totalIn); const totalOut: number = pdfNativeCounter(state.totalOut);
        available = pdfNativeCounter(state.availableIn); const remainingOut: number = pdfNativeCounter(state.availableOut);
        if (totalIn < consumed || totalIn > loaded || available !== loaded-totalIn || totalOut < actual || totalOut-actual > 65536 || remainingOut !== 65536-(totalOut-actual)) { throw new KnowledgeFailure('NativeAccountingMismatch','inflate'); }
        consumed = totalIn; output = new Uint8Array(buffer,0,totalOut-actual);
        audit.consumed = consumed; audit.produced = totalOut; if (available > 0) { audit.residualCalls++; }
        ended = status === zlib.ReturnStatus.STREAM_END; audit.streamEnd = ended;
        if (status !== zlib.ReturnStatus.OK && !ended) { throw new KnowledgeFailure('NativeStreamRejected','inflate'); }
        if (!ended && beforeIn === totalIn && beforeOut === totalOut) { throw new KnowledgeFailure('NativeNoProgress','inflate'); }
        if (ended && (consumed !== member.compressedBytes || loaded !== member.compressedBytes || available !== 0)) { throw new KnowledgeFailure('CompressedTrailingBytes','inflate'); }
      }
      actual = pdfZipReserve(actual,output.length,Math.min(PdfBudget.memberBytes,member.declaredBytes));
      audit.consumed = consumed; audit.produced = actual;
      account.actual = pdfZipReserve(account.actual,output.length,PdfBudget.expandedBytes);
      crc = await checksum.crc32(crc,output.slice().buffer); const blob: cryptoFramework.DataBlob = { data: output }; await digest.update(blob);
      cancel.check(); await sink.accept(output); cancel.check();
    }
    if (!ended || actual !== member.declaredBytes || consumed !== member.compressedBytes || (crc>>>0) !== member.crc32) { throw new KnowledgeFailure('MemberLengthCrcOrEndMismatch','archive'); }
    member.actualBytes = actual; member.actualCrc32 = crc>>>0; member.sha256 = documentDigestHex((await digest.digest()).data); member.verified = true;
  } finally {
    if (initialized && zip !== undefined) {
      const empty: zlib.ZStream = {}; audit.releaseStatus = await zip.inflateEnd(empty);
      if (audit.releaseStatus !== zlib.ReturnStatus.OK) { throw new KnowledgeFailure('NativeReleaseUnconfirmed','inflate'); }
    }
  }
}
