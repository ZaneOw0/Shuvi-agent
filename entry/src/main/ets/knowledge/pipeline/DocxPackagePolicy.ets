import { KnowledgeRangeReader } from '../domain/KnowledgePorts';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { DocxZipDirectory, DocxZipMember } from '../domain/DocxKnowledgePorts';
import { DocxFailure, DocxLimits } from '../domain/DocxKnowledgeModels';
import { documentU16, documentU32, documentZipBoundary } from './DocumentParsePolicy';
import { pdfStrictUtf8 } from './SafeZipPolicy';

function docxExtra(bytes: Uint8Array): void {
  let at: number = 0;
  while (at < bytes.length) {
    if (at+4 > bytes.length) { throw new DocxFailure('ZipExtraTruncated','package'); }
    const tag: number = documentU16(bytes,at); const size: number = documentU16(bytes,at+2);
    if (tag === 1) { throw new DocxFailure('Zip64Unsupported','package'); }
    if (tag === 0x9901) { throw new DocxFailure('EncryptedUnsupported','package'); }
    at += 4+size; if (at > bytes.length) { throw new DocxFailure('ZipExtraTruncated','package'); }
  }
}
export function docxPartName(name: string): boolean {
  return name.length > 0 && name.length <= 1024 && !name.startsWith('/') && !new RegExp('[\\\\\u0000-\u001f\u007f:#?]').test(name) && !name.split('/').some((part: string): boolean => part === '.' || part === '..' || part.length === 0);
}
export function docxResolvePart(source: string, target: string): string {
  if (target.length === 0 || new RegExp('[\\\\\u0000-\u001f:#?]').test(target)) { throw new DocxFailure('RelationshipTargetUnsupported','relationship'); }
  let decoded: string;
  try { decoded = decodeURI(target); } catch { throw new DocxFailure('RelationshipTargetEncoding','relationship'); }
  const parts: string[] = target.startsWith('/') ? [] : source.split('/').slice(0,-1);
  if (decoded.indexOf('\\') >= 0 || decoded.indexOf('?') >= 0 || decoded.indexOf('#') >= 0) { throw new DocxFailure('RelationshipTargetEncoding','relationship'); }
  for (const part of decoded.replace(new RegExp('^/'),'').split('/')) {
    if (part === '..') { if (parts.length === 0) { throw new DocxFailure('RelationshipOutsidePackage','relationship'); } parts.pop(); }
    else if (part !== '.') { parts.push(part); }
  }
  const result: string = parts.join('/'); if (!docxPartName(result)) { throw new DocxFailure('RelationshipPartInvalid','relationship'); } return result;
}
export async function docxInspectZip(reader: KnowledgeRangeReader, role: string, cancel: KnowledgeCancellation): Promise<DocxZipDirectory> {
  if (role !== 'Original' && role !== 'Result') { throw new DocxFailure('PackageRoleUnknown','package'); }
  if (reader.length < 22 || reader.length > (role === 'Original' ? 20 : 30)*1024*1024) { throw new DocxFailure('PackageBytes','package'); }
  const tailSize: number = Math.min(reader.length,65557);
  const boundary = documentZipBoundary(await reader.read(0,4,cancel),await reader.read(reader.length-tailSize,tailSize,cancel),reader.length);
  if (boundary.directoryBytes > DocxLimits.directory || boundary.entries > DocxLimits.entries) { throw new DocxFailure('DirectoryBudget','package'); }
  const bytes: Uint8Array = await reader.read(boundary.directoryOffset,boundary.directoryBytes,cancel);
  const result: DocxZipDirectory = new DocxZipDirectory(); result.role = role; result.length = reader.length; result.directoryOffset = boundary.directoryOffset;
  let at: number = 0;
  for (let count: number = 0; count < boundary.entries; count++) {
    cancel.check(); if (at+46 > bytes.length || documentU32(bytes,at) !== 0x02014b50) { throw new DocxFailure('CentralDirectoryTruncated','package'); }
    const nameSize: number = documentU16(bytes,at+28); const extra: number = documentU16(bytes,at+30); const comment: number = documentU16(bytes,at+32);
    const next: number = at+46+nameSize+extra+comment;
    if (nameSize < 1 || next > bytes.length || documentU16(bytes,at+34) !== 0) { throw new DocxFailure('CentralDirectoryBounds','package'); }
    const m: DocxZipMember = new DocxZipMember(); m.flags = documentU16(bytes,at+8); m.method = documentU16(bytes,at+10);
    if ((m.flags & 0x2041) !== 0) { throw new DocxFailure('EncryptedUnsupported','package'); }
    if ((m.flags & ~0x080e) !== 0 || m.method !== 0 && m.method !== 8 || m.method === 0 && (m.flags & 6) !== 0) { throw new DocxFailure('ZipVariantUnsupported','package'); }
    const rawName: Uint8Array = bytes.subarray(at+46,at+46+nameSize);
    if ((m.flags & 0x800) === 0 && rawName.some((n: number): boolean => n > 127)) { throw new DocxFailure('LegacyZipNameEncodingUnsupported','package'); }
    m.name = pdfStrictUtf8(rawName); const directory: boolean = m.name.endsWith('/');
    if (!docxPartName(directory ? m.name.slice(0,-1) : m.name) || result.members.some((old: DocxZipMember): boolean => old.name === m.name)) { throw new DocxFailure('PartNameInvalidOrDuplicate','package'); }
    m.crc = documentU32(bytes,at+16); m.compressed = documentU32(bytes,at+20); m.expanded = documentU32(bytes,at+24); m.localOffset = documentU32(bytes,at+42);
    if (m.compressed === 0xffffffff || m.expanded === 0xffffffff || m.localOffset === 0xffffffff) { throw new DocxFailure('Zip64Unsupported','package'); }
    if ((documentU16(bytes,at+40)&0xf000) === 0xa000) { throw new DocxFailure('ZipLinkUnsupported','package'); }
    docxExtra(bytes.subarray(at+46+nameSize,at+46+nameSize+extra));
    if (m.localOffset+30 > boundary.directoryOffset) { throw new DocxFailure('LocalHeaderBounds','package'); }
    const local: Uint8Array = await reader.read(m.localOffset,30,cancel);
    if (documentU32(local,0) !== 0x04034b50 || documentU16(local,6) !== m.flags || documentU16(local,8) !== m.method || documentU16(local,26) !== nameSize) { throw new DocxFailure('LocalCentralConflict','package'); }
    const localExtra: number = documentU16(local,28); m.dataOffset = m.localOffset+30+nameSize+localExtra;
    if (m.dataOffset+m.compressed > boundary.directoryOffset) { throw new DocxFailure('MemberBounds','package'); }
    const localMeta: Uint8Array = await reader.read(m.localOffset+30,nameSize+localExtra,cancel);
    if (pdfStrictUtf8(localMeta.subarray(0,nameSize)) !== m.name) { throw new DocxFailure('LocalPartNameConflict','package'); } docxExtra(localMeta.subarray(nameSize));
    m.endOffset = m.dataOffset+m.compressed;
    if ((m.flags&8) === 0) {
      if (documentU32(local,14) !== m.crc || documentU32(local,18) !== m.compressed || documentU32(local,22) !== m.expanded) { throw new DocxFailure('LocalSizeConflict','package'); }
    } else {
      if (m.endOffset+12 > boundary.directoryOffset) { throw new DocxFailure('DescriptorTruncated','package'); }
      const descriptor: Uint8Array = await reader.read(m.endOffset,Math.min(16,boundary.directoryOffset-m.endOffset),cancel);
      const signed: boolean = descriptor.length >= 16 && documentU32(descriptor,0) === 0x08074b50 && documentU32(descriptor,4) === m.crc && documentU32(descriptor,8) === m.compressed && documentU32(descriptor,12) === m.expanded;
      const unsigned: boolean = documentU32(descriptor,0) === m.crc && documentU32(descriptor,4) === m.compressed && documentU32(descriptor,8) === m.expanded;
      if (signed === unsigned) { throw new DocxFailure('DescriptorConflict','package'); } m.endOffset += signed ? 16 : 12;
    }
    if (result.members.some((old: DocxZipMember): boolean => m.localOffset < old.endOffset && old.localOffset < m.endOffset)) { throw new DocxFailure('MemberOverlap','package'); }
    if (m.method === 0 && m.compressed !== m.expanded || directory && (m.compressed !== 0 || m.expanded !== 0)) { throw new DocxFailure('StoredSizeConflict','package'); }
    result.members.push(m); at = next;
  }
  if (at !== bytes.length) { throw new DocxFailure('CentralDirectoryTrailing','package'); } return result;
}
