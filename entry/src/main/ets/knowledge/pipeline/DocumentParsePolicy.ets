import {
  DocumentOriginal, DocumentParseGrant, DocumentParseSnapshot, DocumentCredentialStatus, DocumentParseUsage,
  DocumentParseFailure, DocumentParseBudget, DocumentParseFormat, DocumentPreflightStatus,
  DocumentRemoteState, DocumentTestAcknowledgement
} from '../domain/DocumentParseModels';

export function documentSubmitReason(original: DocumentOriginal, grant: DocumentParseGrant | undefined, snapshot: DocumentParseSnapshot, credential: DocumentCredentialStatus): string {
  if (!snapshot.config.enabled) { return '全局解析关闭'; }
  if (credential !== DocumentCredentialStatus.Configured) { return '凭据未配置或安全存储不可用'; }
  if (snapshot.occupancy.taskId.length > 0 && !snapshot.occupancy.terminalObserved && !snapshot.occupancy.retired) { return '存在未决远端占用；暂停或本机删除不等于云取消'; }
  if (original.preflight !== DocumentPreflightStatus.Passed) { return original.preflightReason || '身份预检尚未通过'; }
  if (!Number.isSafeInteger(original.bytes) || original.bytes < 1 || original.bytes > DocumentParseBudget.originalBytes) { return '原件大小超限'; }
  if (original.format === DocumentParseFormat.Pdf && (!Number.isSafeInteger(original.pages) || original.pages < 1 || original.pages > 50)) { return '无法核定PDF为1–50原页'; }
  if (grant === undefined || !documentGrantMatches(original, grant, snapshot.config.credentialRevision)) { return '需重新逐文件确认测试用途、未知隐私和免费资格'; }
  return '';
}
export function documentBudgetCheck(bytes: number, files: number, batchBytes: number, usage: DocumentParseUsage): void {
  if (!Number.isSafeInteger(bytes) || bytes < 1 || bytes > DocumentParseBudget.originalBytes ||
    !Number.isSafeInteger(files) || files < 1 || files > 3 || !Number.isSafeInteger(batchBytes) || batchBytes < bytes || batchBytes > DocumentParseBudget.batchBytes ||
    usage.originalBytes + bytes > DocumentParseBudget.originalsTotal || usage.originalTemp > 0) {
    throw new DocumentParseFailure('原件或批次预算超限/有临时资产待清理', '预算');
  }
}
export function documentAcknowledged(a: DocumentTestAcknowledgement): boolean {
  return a.fullFile && a.embeddedImages && a.nonSensitive && a.privacyUnknown && a.freeEligible;
}
export function documentGrantMatches(original: DocumentOriginal, grant: DocumentParseGrant, revision: number): boolean {
  return !grant.revoked && grant.id.length > 0 && grant.originalId === original.id && grant.hash === original.hash &&
    grant.version === original.version && grant.format === original.format && grant.credentialRevision === revision &&
    grant.policy === DocumentParseBudget.policy && grant.parameters === DocumentParseBudget.parameters &&
    Number.isSafeInteger(grant.issuedAt) && grant.issuedAt > 0 && documentAcknowledged(grant.acknowledgement);
}
export function documentUsage(snapshot: DocumentParseSnapshot): DocumentParseUsage {
  const usage: DocumentParseUsage = new DocumentParseUsage();
  for (const original of snapshot.originals) { usage.originalBytes += original.bytes; }
  for (const result of snapshot.results) { usage.resultBytes += result.bytes; }
  for (const cleanup of snapshot.cleanup) { usage.originalBytes += cleanup.originalBytes; usage.resultBytes += cleanup.resultBytes; }
  return usage;
}
export function documentRemoteTerminal(state: DocumentRemoteState): boolean { return state === DocumentRemoteState.Done || state === DocumentRemoteState.Failed; }
export function documentSafeId(id: string): boolean { return new RegExp('^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$').test(id); }
export function documentHashValid(hash: string): boolean { return new RegExp('^[a-f0-9]{64}$').test(hash); }
export function documentSuffix(title: string): DocumentParseFormat {
  const suffix: string = title.toLowerCase();
  if (suffix.endsWith('.pdf')) { return DocumentParseFormat.Pdf; }
  if (suffix.endsWith('.docx')) { return DocumentParseFormat.Docx; }
  if (suffix.endsWith('.pptx')) { return DocumentParseFormat.Pptx; }
  if (suffix.endsWith('.xlsx')) { return DocumentParseFormat.Xlsx; }
  throw new DocumentParseFailure('只允许PDF/DOCX/PPTX/XLSX', '原件');
}
export function documentU16(bytes: Uint8Array, at: number): number { return bytes[at] + bytes[at + 1] * 256; }
export function documentU32(bytes: Uint8Array, at: number): number { return documentU16(bytes, at) + documentU16(bytes, at + 2) * 65536; }
export class DocumentZipBoundary { directoryOffset: number = 0; directoryBytes: number = 0; entries: number = 0; }
export function documentZipBoundary(head: Uint8Array, tail: Uint8Array, bytes: number): DocumentZipBoundary {
  if (head.length < 4 || documentU32(head, 0) !== 0x04034B50 || bytes < 22) { throw new DocumentParseFailure('ZIP外层签名不符', '传输校验'); }
  for (let i: number = tail.length - 22; i >= 0; i--) {
    if (documentU32(tail, i) !== 0x06054B50 || i + 22 + documentU16(tail, i + 20) !== tail.length) { continue; }
    const result: DocumentZipBoundary = new DocumentZipBoundary(); result.entries = documentU16(tail, i + 10);
    result.directoryBytes = documentU32(tail, i + 12); result.directoryOffset = documentU32(tail, i + 16);
    const absoluteEnd: number = bytes - tail.length + i;
    if (documentU16(tail, i + 4) !== 0 || documentU16(tail, i + 6) !== 0 || documentU16(tail, i + 8) !== result.entries ||
      result.entries === 0 || result.entries === 65535 || result.directoryBytes === 0xFFFFFFFF || result.directoryOffset === 0xFFFFFFFF ||
      result.directoryOffset < 4 || result.directoryBytes < 46 || result.directoryOffset + result.directoryBytes !== absoluteEnd) {
      throw new DocumentParseFailure('ZIP结束记录不完整或本轮不支持的变体', '传输校验');
    }
    return result;
  }
  throw new DocumentParseFailure('ZIP完整结束记录缺失', '传输校验');
}
export function documentOfficeIdentity(directory: Uint8Array, boundary: DocumentZipBoundary, format: DocumentParseFormat): void {
  if (directory.length !== boundary.directoryBytes || directory.length > DocumentParseBudget.directoryBytes || boundary.entries > 4096) {
    throw new DocumentParseFailure('OOXML目录预算超限', '身份预检');
  }
  const names: string[] = []; let at: number = 0;
  for (let count: number = 0; count < boundary.entries; count++) {
    if (at + 46 > directory.length || documentU32(directory, at) !== 0x02014B50) { throw new DocumentParseFailure('OOXML目录损坏', '身份预检'); }
    const flags: number = documentU16(directory, at + 8); const nameSize: number = documentU16(directory, at + 28);
    const extra: number = documentU16(directory, at + 30); const comment: number = documentU16(directory, at + 32);
    const next: number = at + 46 + nameSize + extra + comment;
    if (nameSize < 1 || next > directory.length || (flags & 0x2041) !== 0 || documentU16(directory, at + 34) !== 0 ||
      documentU32(directory, at + 20) === 0xFFFFFFFF || documentU32(directory, at + 24) === 0xFFFFFFFF || documentU32(directory, at + 42) === 0xFFFFFFFF ||
      documentU32(directory, at + 42) >= boundary.directoryOffset || (documentU16(directory, at + 40) & 0xF000) === 0xA000) {
      throw new DocumentParseFailure('OOXML加密/链接/ZIP64/目录越界', '身份预检');
    }
    let name: string = '';
    for (let j: number = at + 46; j < at + 46 + nameSize; j++) {
      const c: number = directory[j];
      // ASCII package paths cover the required OOXML identities; unsupported encodings fail closed.
      if (c < 32 || c > 126 || c === 92 || c === 58 || c === 37) { throw new DocumentParseFailure('OOXML路径编码不受支持', '身份预检'); }
      name += String.fromCharCode(c);
    }
    if (name.startsWith('/') || name.split('/').some((p: string): boolean => p === '..' || p === '.') || names.indexOf(name.toLowerCase()) >= 0) {
      throw new DocumentParseFailure('OOXML路径越界或重复', '身份预检');
    }
    let e: number = at + 46 + nameSize;
    while (e < at + 46 + nameSize + extra) {
      if (e + 4 > at + 46 + nameSize + extra) { throw new DocumentParseFailure('OOXML扩展目录截断', '身份预检'); }
      const tag: number = documentU16(directory, e); const length: number = documentU16(directory, e + 2);
      if (tag === 1 || tag === 0x9901 || e + 4 + length > at + 46 + nameSize + extra) { throw new DocumentParseFailure('OOXML ZIP64或加密扩展', '身份预检'); }
      e += 4 + length;
    }
    names.push(name.toLowerCase()); at = next;
  }
  const required: string = format === DocumentParseFormat.Docx ? 'word/document.xml' : format === DocumentParseFormat.Pptx ? 'ppt/presentation.xml' : 'xl/workbook.xml';
  const identities: string[] = ['word/document.xml', 'ppt/presentation.xml', 'xl/workbook.xml'];
  if (at !== directory.length || names.indexOf('[content_types].xml') < 0 || names.indexOf(required) < 0 || identities.filter((n: string): boolean => names.indexOf(n) >= 0).length !== 1) {
    throw new DocumentParseFailure('OOXML主包身份与扩展名不符', '身份预检');
  }
}
