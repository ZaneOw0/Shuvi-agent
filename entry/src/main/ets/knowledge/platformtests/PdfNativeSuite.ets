import { BusinessError } from '@kit.BasicServicesKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { PdfZipMember, KnowledgeCancellation, KnowledgeFailure, PdfBudget } from '../domain/PdfKnowledgeModels';
import { pdfNativeReadMember, PdfExpansionAccount, PdfMemberSink, PdfNativeAudit } from '../infra/PdfNativeReader';
import { PdfFixtureReader, pdfFixtureCrc, pdfFixtureSmall, pdfFixtureSmallPlain, pdfFixtureRawBlocks, pdfFixtureResidual } from './PdfNativeFixtures';

export class PdfNativeCaseResult {
  id: string = ''; passed: boolean = false; reason: string = ''; code: number = 0;
  input: number = 0; output: number = 0; calls: number = 0; residuals: number = 0; ends: number = 0;
}
export class PdfNativeSuiteResult { run: string = ''; version: string = 'R2-NATIVE-1'; cases: PdfNativeCaseResult[] = []; }
class PdfFixtureSink implements PdfMemberSink {
  private expected: Uint8Array; private cancel: KnowledgeCancellation; private stop: boolean;
  actual: number = 0;
  constructor(expected: Uint8Array, cancel: KnowledgeCancellation, stop: boolean) { this.expected = expected; this.cancel = cancel; this.stop = stop; }
  async accept(bytes: Uint8Array): Promise<void> {
    for (let at: number = 0; at < bytes.length; at++) { if (bytes[at] !== this.expected[this.actual+at]) { throw new KnowledgeFailure('OutputBytesDiffer','suite'); } }
    this.actual += bytes.length; if (this.stop) { this.cancel.invalid = true; }
  }
}
export async function pdfRunNativeSuite(scope: KnowledgeStorageScope, smallOnly: boolean = false): Promise<PdfNativeSuiteResult> {
  scope.requireTestOwner(scope.key);
  const result: PdfNativeSuiteResult = new PdfNativeSuiteResult(); result.run = scope.key;
  const names: string[] = smallOnly ? ['stored','raw-small','raw-multi','raw-residual'] : ['stored','raw-small','raw-multi','raw-residual','crc','truncated','trailing','declared-limit','global-limit','cancel','release-reopen'];
  for (const name of names) {
    const row: PdfNativeCaseResult = new PdfNativeCaseResult(); row.id = name;
    const cancel: KnowledgeCancellation = new KnowledgeCancellation(); const audit: PdfNativeAudit = new PdfNativeAudit();
    let plain: Uint8Array = pdfFixtureSmallPlain(); let bytes: Uint8Array = name === 'stored' ? plain : pdfFixtureSmall();
    if (name === 'raw-multi' || name === 'cancel') { plain = new Uint8Array(196613); plain.fill(65); bytes = pdfFixtureRawBlocks(plain); }
    if (name === 'raw-residual') { plain = new Uint8Array(196613); plain.fill(65); bytes = pdfFixtureResidual(); }
    if (name === 'truncated') { bytes = bytes.slice(0,bytes.length-2); }
    if (name === 'trailing') { const extra: Uint8Array = new Uint8Array(bytes.length+1); extra.set(bytes); bytes = extra; }
    const member: PdfZipMember = new PdfZipMember(); member.method = name === 'stored' ? 0 : 8;
    member.compressedBytes = bytes.length; member.declaredBytes = plain.length; member.crc32 = pdfFixtureCrc(plain);
    if (name === 'crc') { member.crc32 ^= 1; }
    if (name === 'declared-limit') { member.declaredBytes--; }
    const account: PdfExpansionAccount = new PdfExpansionAccount(); if (name === 'global-limit') { account.actual = PdfBudget.expandedBytes; }
    const reader: PdfFixtureReader = new PdfFixtureReader(bytes); const sink: PdfFixtureSink = new PdfFixtureSink(plain,cancel,name === 'cancel');
    let observed: string = '';
    try {
      await pdfNativeReadMember(reader,member,sink,account,cancel,audit);
      if (!member.verified || sink.actual !== plain.length || member.actualCrc32 !== pdfFixtureCrc(plain) || audit.consumed !== bytes.length || (member.method === 8 && (!audit.streamEnd || audit.releaseStatus !== 0))) { throw new KnowledgeFailure('FinalAssertion','suite'); }
      if (name === 'raw-multi' && (audit.calls < 3 || reader.reads < 3)) { throw new KnowledgeFailure('MultipleBuffersNotExercised','suite'); }
      if (name === 'raw-residual' && (audit.calls < 3 || audit.residualCalls < 1)) { throw new KnowledgeFailure('ResidualInputNotExercised','suite'); }
      observed = 'ok';
    } catch (error) {
      const system: BusinessError = error;
      row.code = typeof system.code === 'number' ? system.code : 0;
      observed = error instanceof KnowledgeFailure ? error.category : 'NativeApiRejected';
    } finally { await reader.close(); }
    const expected: boolean = name === 'crc' ? observed === 'MemberLengthCrcOrEndMismatch' :
      name === 'truncated' ? (observed === 'NativeStreamRejected' || observed === 'NativeNoProgress' || (observed === 'NativeApiRejected' && row.code === 17800007) || observed === 'MemberLengthCrcOrEndMismatch') :
      name === 'trailing' ? observed === 'CompressedTrailingBytes' :
      name === 'declared-limit' || name === 'global-limit' ? observed === 'BudgetExceeded' :
      name === 'cancel' ? observed === 'Canceled' : observed === 'ok';
    row.passed = expected && reader.closed && (member.method === 0 || audit.releaseStatus === 0);
    row.reason = observed; row.input = audit.consumed; row.output = audit.produced; row.calls = audit.calls;
    row.residuals = audit.residualCalls; row.ends = audit.releaseStatus === 0 ? 1 : 0;
    result.cases.push(row);
  } return result;
}
