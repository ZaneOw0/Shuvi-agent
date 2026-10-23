import { DocxXmlAdapter } from '../infra/DocxXmlAdapter';
import { DocxXmlNode, docxXmlAttr } from '../domain/DocxXmlModels';
import { KnowledgeRangeReader } from '../domain/KnowledgePorts';
import { KnowledgeCancellation, PdfZipMember } from '../domain/PdfKnowledgeModels';
import { pdfNativeReadMember, PdfExpansionAccount, PdfMemberSink } from '../infra/PdfNativeReader';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { DocxFailure } from '../domain/DocxKnowledgeModels';

export class DocxPlatformCaseResult { id: string = ''; passed: boolean = false; reason: string = ''; }
class DocxPlatformMemoryReader implements KnowledgeRangeReader {
  length: number = 7;
  async read(offset: number, length: number, cancel: KnowledgeCancellation): Promise<Uint8Array> { cancel.check(); return new Uint8Array([0xcb,0x48,0xcd,0xc9,0xc9,0x07,0x00]).slice(offset,offset+length); }
  async close(): Promise<void> {}
}
class DocxPlatformMemberSink implements PdfMemberSink {
  bytes: number[] = [];
  async accept(bytes: Uint8Array): Promise<void> { for (const b of bytes) { this.bytes.push(b); } }
}
// Explicit manual entry only. Not registered with Index, never auto-runs, no network/credential/store access.
export async function docxPlatformCases(): Promise<DocxPlatformCaseResult[]> {
  const results: DocxPlatformCaseResult[] = []; const parser: DocxXmlAdapter = new DocxXmlAdapter();
  for (const id of ['namespace-attributes-entities','namespace-rebinding','doctype-rejected','utf16-and-canceled','raw-inflate-crc-release']) {
    const result: DocxPlatformCaseResult = new DocxPlatformCaseResult(); result.id = id;
    try {
      const cancel: KnowledgeCancellation = new KnowledgeCancellation();
      if (id === 'namespace-attributes-entities') {
        const root: DocxXmlNode = await parser.parse(pdfCodecUtf8('<q:r xmlns:q="urn:m4" xmlns:a="urn:attr" a:v="A &amp; B"><q:t xml:space="preserve"> 甲&#x4E59; </q:t></q:r>'),cancel);
        if (root.namespace !== 'urn:m4' || docxXmlAttr(root,'urn:attr','v') !== 'A & B' || root.children[0]?.text !== ' 甲乙 ') { throw new DocxFailure('NamespaceEntityWhitespaceMismatch','platform-case'); }
      } else if (id === 'namespace-rebinding') {
        const root: DocxXmlNode = await parser.parse(pdfCodecUtf8('<a:r xmlns:a="urn:one"><a:x xmlns:a="urn:two" a:v="2"/><a:x a:v="1"/></a:r>'),cancel);
        if (root.children[0]?.namespace !== 'urn:two' || root.children[1]?.namespace !== 'urn:one' || docxXmlAttr(root.children[0],'urn:two','v') !== '2') { throw new DocxFailure('NamespaceScopeMismatch','platform-case'); }
      } else if (id === 'doctype-rejected') {
        let rejected: boolean = false; try { await parser.parse(pdfCodecUtf8('<!DOCTYPE r [<!ENTITY x "blocked">]><r>&x;</r>'),cancel); } catch { rejected = true; }
        if (!rejected) { throw new DocxFailure('DoctypeWasNotRejected','platform-case'); }
      } else if (id === 'utf16-and-canceled') {
        const source: string = '<?xml version="1.0" encoding="UTF-16"?><r>甲</r>'; const bytes: Uint8Array = new Uint8Array(2+source.length*2); bytes[0] = 255; bytes[1] = 254;
        for (let at: number = 0; at < source.length; at++) { const c: number = source.charCodeAt(at); bytes[2+at*2] = c&255; bytes[3+at*2] = c>>8; }
        const root: DocxXmlNode = await parser.parse(bytes,cancel); if (root.text !== '甲') { throw new DocxFailure('Utf16Mismatch','platform-case'); }
        cancel.invalid = true; let rejected: boolean = false; try { await parser.parse(bytes,cancel); } catch { rejected = true; } if (!rejected) { throw new DocxFailure('CanceledAccepted','platform-case'); }
      } else {
        const raw: PdfZipMember = new PdfZipMember(); raw.method = 8; raw.compressedBytes = 7; raw.declaredBytes = 5; raw.crc32 = 0x3610a686;
        const sink: DocxPlatformMemberSink = new DocxPlatformMemberSink(); await pdfNativeReadMember(new DocxPlatformMemoryReader(),raw,sink,new PdfExpansionAccount(),cancel);
        if (!raw.verified || raw.actualBytes !== 5 || sink.bytes.join(',') !== '104,101,108,108,111') { throw new DocxFailure('NativeMemberMismatch','platform-case'); }
      }
      result.passed = true;
    } catch (error) { result.reason = error instanceof DocxFailure ? error.category : 'PlatformCallFailed'; }
    results.push(result);
  } return results;
}
