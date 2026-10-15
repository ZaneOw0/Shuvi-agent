import {
  DocumentOriginal, DocumentParseGrant, DocumentParseSnapshot, DocumentParseUsage, DocumentParseBudget,
  DocumentParseFormat, DocumentPreflightStatus, DocumentCredentialStatus, DocumentParseFailure
} from '../main/ets/knowledge/domain/DocumentParseModels';
import { documentSubmitReason, documentBudgetCheck, documentOfficeIdentity, DocumentZipBoundary, documentZipBoundary } from '../main/ets/knowledge/pipeline/DocumentParsePolicy';
import {
  mineruDecodeAllocation, mineruDecodeInspection, mineruValidateDestination, MineruBoundedBytes,
  MINERU_UPLOAD_HOST, MINERU_RESULT_HOST, MineruAllocationDTO, MineruInspectionDTO, mineruHttpStatus
} from '../main/ets/knowledge/pipeline/MineruProtocolCodec';

export interface DocumentPolicyTestCase { name: string; run: () => Promise<void>; }
export function documentPolicyCheck(ok: boolean): void { if (!ok) { throw new Error('M2 frozen policy expectation failed'); } }
export function documentUnitOriginal(): DocumentOriginal {
  const original: DocumentOriginal = new DocumentOriginal(); original.id = 'unit-original'; original.assetId = 'original-unit';
  original.title = 'unit-only.pdf'; original.hash = 'a'.repeat(64); original.bytes = 100; original.pages = 1;
  original.preflight = DocumentPreflightStatus.Passed; return original;
}
export function documentUnitGrant(original: DocumentOriginal): DocumentParseGrant {
  const grant: DocumentParseGrant = new DocumentParseGrant(); grant.id = 'unit-grant'; grant.originalId = original.id;
  grant.hash = original.hash; grant.version = original.version; grant.format = original.format; grant.credentialRevision = 1;
  grant.issuedAt = Date.now(); grant.acknowledgement.fullFile = true; grant.acknowledgement.embeddedImages = true;
  grant.acknowledgement.nonSensitive = true; grant.acknowledgement.privacyUnknown = true; grant.acknowledgement.freeEligible = true; return grant;
}
export function documentParseCases(): DocumentPolicyTestCase[] {
  const cases: DocumentPolicyTestCase[] = [
    { name: '非敏感免费逐件完整授权才可提交', run: async (): Promise<void> => {
      const original: DocumentOriginal = documentUnitOriginal(); const grant: DocumentParseGrant = documentUnitGrant(original);
      const snapshot: DocumentParseSnapshot = new DocumentParseSnapshot(); snapshot.config.enabled = true; snapshot.config.credentialRevision = 1;
      documentPolicyCheck(documentSubmitReason(original, grant, snapshot, DocumentCredentialStatus.Configured) === '');
      grant.acknowledgement.nonSensitive = false;
      documentPolicyCheck(documentSubmitReason(original, grant, snapshot, DocumentCredentialStatus.Configured) !== '');
    } },
    { name: '关闭无凭据无Grant及hash版本revision变更均拒绝', run: async (): Promise<void> => {
      const original: DocumentOriginal = documentUnitOriginal(); const grant: DocumentParseGrant = documentUnitGrant(original);
      const snapshot: DocumentParseSnapshot = new DocumentParseSnapshot(); snapshot.config.credentialRevision = 1;
      documentPolicyCheck(documentSubmitReason(original, grant, snapshot, DocumentCredentialStatus.Configured) !== '');
      snapshot.config.enabled = true;
      documentPolicyCheck(documentSubmitReason(original, undefined, snapshot, DocumentCredentialStatus.Configured) !== '');
      documentPolicyCheck(documentSubmitReason(original, grant, snapshot, DocumentCredentialStatus.Missing) !== '');
      grant.hash = 'b'.repeat(64); documentPolicyCheck(documentSubmitReason(original, grant, snapshot, DocumentCredentialStatus.Configured) !== '');
      grant.hash = original.hash; grant.version++;
      documentPolicyCheck(documentSubmitReason(original, grant, snapshot, DocumentCredentialStatus.Configured) !== '');
      grant.version = original.version; grant.credentialRevision++;
      documentPolicyCheck(documentSubmitReason(original, grant, snapshot, DocumentCredentialStatus.Configured) !== '');
    } },
    { name: 'PDF真实页数1到50及预检不可用failclosed', run: async (): Promise<void> => {
      const original: DocumentOriginal = documentUnitOriginal(); const grant: DocumentParseGrant = documentUnitGrant(original);
      const snapshot: DocumentParseSnapshot = new DocumentParseSnapshot(); snapshot.config.enabled = true; snapshot.config.credentialRevision = 1;
      for (const pages of [1, 50]) { original.pages = pages; documentPolicyCheck(documentSubmitReason(original, grant, snapshot, DocumentCredentialStatus.Configured) === ''); }
      for (const pages of [0, 51, -1, 1.5]) { original.pages = pages; documentPolicyCheck(documentSubmitReason(original, grant, snapshot, DocumentCredentialStatus.Configured) !== ''); }
      original.pages = 1; original.preflight = DocumentPreflightStatus.Blocked;
      documentPolicyCheck(documentSubmitReason(original, grant, snapshot, DocumentCredentialStatus.Configured) !== '');
    } },
    { name: '原件单批总量实际边界加一拒绝', run: async (): Promise<void> => {
      const usage: DocumentParseUsage = new DocumentParseUsage();
      documentBudgetCheck(DocumentParseBudget.originalBytes, 3, DocumentParseBudget.batchBytes, usage);
      let rejected: number = 0;
      for (const bytes of [0, -1, 1.5, DocumentParseBudget.originalBytes + 1]) {
        try { documentBudgetCheck(bytes, 1, bytes, usage); } catch { rejected++; }
      }
      try { documentBudgetCheck(1, 4, 1, usage); } catch { rejected++; }
      try { documentBudgetCheck(1, 1, DocumentParseBudget.batchBytes + 1, usage); } catch { rejected++; }
      usage.originalBytes = DocumentParseBudget.originalsTotal;
      try { documentBudgetCheck(1, 1, 1, usage); } catch { rejected++; }
      documentPolicyCheck(rejected === 7);
    } },
    { name: '未知远端占用不能因本机暂停而释放', run: async (): Promise<void> => {
      const original: DocumentOriginal = documentUnitOriginal(); const grant: DocumentParseGrant = documentUnitGrant(original);
      const snapshot: DocumentParseSnapshot = new DocumentParseSnapshot(); snapshot.config.enabled = true; snapshot.config.credentialRevision = 1;
      snapshot.occupancy.taskId = 'other-unit';
      documentPolicyCheck(documentSubmitReason(original, grant, snapshot, DocumentCredentialStatus.Configured) !== '');
    } }
  ]; return cases.concat(documentProtocolCases(), documentMetadataCases());
}

function documentProtocolCases(): DocumentPolicyTestCase[] {
  const upload: string = 'https://' + MINERU_UPLOAD_HOST + '/api-upload/unit-only';
  const result: string = 'https://' + MINERU_RESULT_HOST + '/pdf/unit-only.zip';
  const allocation: string = '{"code":0,"msg":"ok","data":{"batch_id":"unit-batch-1","file_urls":[' + JSON.stringify(upload) + ']}}';
  const cases: DocumentPolicyTestCase[] = [
    { name: 'HTTP3xx401403与429有界RetryAfter不泄原文', run: async (): Promise<void> => {
      mineruHttpStatus(200, undefined); let rejected: number = 0;
      for (const code of [301,302,307,308,401,403,500]) { try { mineruHttpStatus(code, undefined); } catch { rejected++; } }
      documentPolicyCheck(rejected === 7);
      try { mineruHttpStatus(429, '999999'); } catch (error) { documentPolicyCheck(error instanceof DocumentParseFailure && error.serviceCode === '900'); }
      try { mineruHttpStatus(429, 'unit-sensitive-invalid-header'); } catch (error) { documentPolicyCheck(error instanceof DocumentParseFailure && error.serviceCode === '' && error.message.indexOf('unit-sensitive-invalid-header') < 0); }
    } },
    { name: '公开控制fixture仅单项batch申请', run: async (): Promise<void> => {
      const dto: MineruAllocationDTO = mineruDecodeAllocation(allocation); documentPolicyCheck(dto.batchId === 'unit-batch-1');
    } },
    { name: '标准JSON转义未知字段有界跳过', run: async (): Promise<void> => {
      const dto: MineruAllocationDTO = mineruDecodeAllocation(allocation.replace('"msg":"ok"', '"msg":"o\\u006b","bounded_extra":[null,true,false,-0.25e+2,{"k":"\\ud83d\\ude00"}]'));
      documentPolicyCheck(dto.batchId === 'unit-batch-1');
    } },
    { name: '重复字段与非法数字数组schema拒绝', run: async (): Promise<void> => {
      const invalid: string[] = [allocation.replace('"code":0', '"code":0,"code":0'), allocation.replace('"code":0', '"code":0.5'),
        allocation.replace('"code":0', '"code":9007199254740992'), allocation.replace('"code":0', '"code":00'),
        allocation.replace('"code":0', '"code":NaN'), allocation.replace('"code":0', '"code":1e309'),
        allocation.replace('["https:', '[null,"https:'), allocation.replace('"unit-batch-1"', '"../unsafe"'),
        allocation + 'true', allocation.replace('"ok"', '"\\ud800"'), allocation.replace('"ok"', '"bad\ntext"')];
      let rejected: number = 0; for (const raw of invalid) { try { mineruDecodeAllocation(raw); } catch { rejected++; } }
      documentPolicyCheck(rejected === invalid.length);
    } },
    { name: '1MiB16深4096项16KiB字符串预算', run: async (): Promise<void> => {
      const invalid: string[] = [allocation + ' '.repeat(DocumentParseBudget.jsonBytes),
        allocation.replace('"ok"', JSON.stringify('x'.repeat(16385))),
        allocation.replace('"msg":"ok"', '"msg":"ok","deep":' + '['.repeat(17) + '0' + ']'.repeat(17)),
        allocation.replace('"msg":"ok"', '"msg":"ok","many":[' + '0,'.repeat(4096) + '0]')];
      let rejected: number = 0; for (const raw of invalid) { try { mineruDecodeAllocation(raw); } catch { rejected++; } }
      documentPolicyCheck(rejected === invalid.length);
    } },
    { name: '角色精确host443与路径安全拒绝混淆', run: async (): Promise<void> => {
      mineruValidateDestination(upload, 'UPLOAD'); mineruValidateDestination(result, 'RESULT');
      const invalid: string[] = [upload.replace(MINERU_UPLOAD_HOST, MINERU_UPLOAD_HOST + '.invalid'),
        upload.replace(MINERU_UPLOAD_HOST, MINERU_UPLOAD_HOST + ':444'), upload.replace(MINERU_UPLOAD_HOST, 'user@' + MINERU_UPLOAD_HOST),
        upload.replace('/api-upload/', '/api-upload/../'), upload.replace('/api-upload/', '/api-upload/%2e%2e/'),
        upload + '#fragment', upload.replace('https:', 'http:'), upload.replace(MINERU_UPLOAD_HOST, '127.0.0.1'),
        result, upload + '?a=%0D%0A', upload.replace(MINERU_UPLOAD_HOST, MINERU_UPLOAD_HOST + '.'), upload.replace('/api-upload/', '//api-upload/')];
      let rejected: number = 0; for (const address of invalid) { try { mineruValidateDestination(address, 'UPLOAD'); } catch { rejected++; } }
      documentPolicyCheck(rejected === invalid.length);
    } },
    { name: '实际字节写前cap未知ContentLength亦生效', run: async (): Promise<void> => {
      const cap: MineruBoundedBytes = new MineruBoundedBytes(); cap.reserve(65536, DocumentParseBudget.resultBytes);
      let rejected: boolean = false; try { cap.reserve(DocumentParseBudget.resultBytes, DocumentParseBudget.resultBytes); } catch { rejected = true; }
      documentPolicyCheck(rejected && cap.count === 65536);
    } }
  ];
  for (const state of ['waiting-file', 'pending', 'converting', 'running', 'done', 'failed']) {
    cases.push({ name: '公开控制状态 ' + state, run: async (): Promise<void> => {
      const raw: string = '{"code":0,"msg":"ok","data":{"batch_id":"unit-batch-1","extract_result":[{"data_id":"unit-data-1","file_name":"unit-only.pdf","state":' + JSON.stringify(state) + ',"full_zip_url":' + JSON.stringify(result) + ',"extract_progress":{"extracted_pages":1,"total_pages":2}}]}}';
      const dto: MineruInspectionDTO = mineruDecodeInspection(raw, 'unit-batch-1', 'unit-data-1'); documentPolicyCheck(dto.state === state);
      let rejected: number = 0;
      for (const bad of [raw.replace('unit-data-1', 'other-data'), raw.replace('unit-batch-1', 'other-batch'), raw.replace(JSON.stringify(state), '"future-state"'), raw.replace('"extracted_pages":1', '"extracted_pages":2.5')]) {
        try { mineruDecodeInspection(bad, 'unit-batch-1', 'unit-data-1'); } catch { rejected++; }
      } documentPolicyCheck(rejected === 4);
    } });
  } return cases;
}

// Constructed directory metadata ONLY, never a complete Office/ZIP file or cloud artifact.
function documentWriteU16(bytes: Uint8Array, at: number, n: number): void { bytes[at] = n % 256; bytes[at + 1] = Math.floor(n / 256) % 256; }
function documentWriteU32(bytes: Uint8Array, at: number, n: number): void { documentWriteU16(bytes, at, n % 65536); documentWriteU16(bytes, at + 2, Math.floor(n / 65536)); }
function documentUnitDirectory(names: string[]): Uint8Array {
  let size: number = 0; for (const name of names) { size += 46 + name.length; }
  const bytes: Uint8Array = new Uint8Array(size); let at: number = 0;
  for (const name of names) {
    documentWriteU32(bytes, at, 0x02014B50); documentWriteU16(bytes, at + 28, name.length); documentWriteU32(bytes, at + 42, 0);
    for (let j: number = 0; j < name.length; j++) { bytes[at + 46 + j] = name.charCodeAt(j); } at += 46 + name.length;
  } return bytes;
}
function documentMetadataCases(): DocumentPolicyTestCase[] {
  const tests: DocumentPolicyTestCase[] = [];
  const formats: DocumentParseFormat[] = [DocumentParseFormat.Docx, DocumentParseFormat.Pptx, DocumentParseFormat.Xlsx];
  const mains: string[] = ['word/document.xml', 'ppt/presentation.xml', 'xl/workbook.xml'];
  for (let i: number = 0; i < 3; i++) {
    const format: DocumentParseFormat = formats[i]; const main: string = mains[i];
    tests.push({ name: 'OOXML目录身份与负例 ' + format, run: async (): Promise<void> => {
      const names: string[] = ['[Content_Types].xml', main]; const directory: Uint8Array = documentUnitDirectory(names);
      const b: DocumentZipBoundary = new DocumentZipBoundary(); b.directoryOffset = 512; b.directoryBytes = directory.length; b.entries = 2;
      documentOfficeIdentity(directory, b, format);
      let rejected: number = 0;
      for (const paths of [[main, main], ['[Content_Types].xml', '../' + main], ['[Content_Types].xml', '/' + main], ['[Content_Types].xml', main + '%2f'], ['[Content_Types].xml', 'fake/content.xml']]) {
        const invalid: Uint8Array = documentUnitDirectory(paths); b.directoryBytes = invalid.length;
        try { documentOfficeIdentity(invalid, b, format); } catch { rejected++; }
      }
      b.directoryBytes = directory.length;
      for (const mode of ['ENCRYPT', 'LINK', 'ZIP64', 'MULTIVOLUME', 'TRUNCATED']) {
        const invalid: Uint8Array = directory.slice();
        if (mode === 'ENCRYPT') { documentWriteU16(invalid, 8, 1); }
        if (mode === 'LINK') { documentWriteU16(invalid, 40, 0xA000); }
        if (mode === 'ZIP64') { documentWriteU32(invalid, 20, 0xFFFFFFFF); }
        if (mode === 'MULTIVOLUME') { documentWriteU16(invalid, 34, 1); }
        if (mode === 'TRUNCATED') { documentWriteU16(invalid, 28, 65535); }
        try { documentOfficeIdentity(invalid, b, format); } catch { rejected++; }
      }
      documentPolicyCheck(rejected === 10);
    } });
  }
  tests.push({ name: 'ZIP外层结束完整性不代表成员schema或CRC', run: async (): Promise<void> => {
    const head: Uint8Array = new Uint8Array(4); documentWriteU32(head, 0, 0x04034B50);
    const tail: Uint8Array = new Uint8Array(22); documentWriteU32(tail, 0, 0x06054B50); documentWriteU16(tail, 8, 1); documentWriteU16(tail, 10, 1);
    documentWriteU32(tail, 12, 46); documentWriteU32(tail, 16, 4);
    documentPolicyCheck(documentZipBoundary(head, tail, 72).entries === 1);
    let rejected: number = 0;
    try { documentZipBoundary(head, tail, 73); } catch { rejected++; }
    documentWriteU16(tail, 4, 1); try { documentZipBoundary(head, tail, 72); } catch { rejected++; }
    documentWriteU16(tail, 4, 0); documentWriteU16(tail, 20, 2); try { documentZipBoundary(head, tail, 72); } catch { rejected++; }
    documentPolicyCheck(rejected === 3);
  } }); return tests;
}
