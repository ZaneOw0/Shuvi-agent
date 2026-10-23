import { KnowledgeRangeReader } from '../domain/KnowledgePorts';
import { PdfBudget, PdfZipManifest, PdfZipMember, KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { documentUtf8Bytes } from '../domain/DocumentParseModels';

export function pdfZipReserve(current: number, increment: number, limit: number): number {
  if (!Number.isSafeInteger(current) || !Number.isSafeInteger(increment) || current < 0 || increment < 0 || increment > limit-current) { throw new KnowledgeFailure('BudgetExceeded','zip'); } return current+increment;
}
export function pdfStrictUtf8(bytes: Uint8Array): string {
  let result: string = '';
  for (let i: number = 0; i < bytes.length;) {
    const first: number = bytes[i++]; let cp: number = first; let count: number = 0; let minimum: number = 0;
    if (first >= 0xc2 && first <= 0xdf) { count = 1; cp = first & 31; minimum = 0x80; }
    else if (first >= 0xe0 && first <= 0xef) { count = 2; cp = first & 15; minimum = 0x800; }
    else if (first >= 0xf0 && first <= 0xf4) { count = 3; cp = first & 7; minimum = 0x10000; }
    else if (first > 0x7f) { throw new KnowledgeFailure('InvalidUtf8','zip-json'); }
    if (i+count > bytes.length) { throw new KnowledgeFailure('TruncatedUtf8','zip-json'); }
    for (let n: number = 0; n < count; n++) { const next: number = bytes[i++]; if (next < 0x80 || next > 0xbf) { throw new KnowledgeFailure('InvalidUtf8','zip-json'); } cp = cp*64+(next&63); }
    if (cp < minimum || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) { throw new KnowledgeFailure('InvalidUtf8','zip-json'); }
    result += String.fromCodePoint(cp);
  } return result;
}
export function pdfZipLogicalName(name: string): string {
  if (name.length === 0 || documentUtf8Bytes(name) > 512 || new RegExp('[\\\\:\\x00-\\x20\\x7f]').test(name) || name.startsWith('/') || name.startsWith('~')) { throw new KnowledgeFailure('UnsafeMemberName','zip'); }
  const path: string = name.endsWith('/') ? name.slice(0,-1) : name; const parts: string[] = path.split('/');
  if (parts.length > 8 || parts.some((part: string): boolean => part.length === 0 || part === '.' || part === '..' || part.endsWith('.') || part.endsWith(' '))) { throw new KnowledgeFailure('UnsafeMemberPath','zip'); }
  if (new RegExp('\\.(zip|gz|tgz|tar|7z|rar|bz2|xz|docx|pptx|xlsx)$','i').test(path)) { throw new KnowledgeFailure('NestedArchive','zip'); }
  return path.normalize('NFKC').toLowerCase();
}
function zipU16(bytes: Uint8Array, offset: number): number { if (offset < 0 || offset+2 > bytes.length) { throw new KnowledgeFailure('TruncatedHeader','zip'); } return bytes[offset]+bytes[offset+1]*256; }
function zipU32(bytes: Uint8Array, offset: number): number { return zipU16(bytes,offset)+zipU16(bytes,offset+2)*65536; }
function zipExtras(bytes: Uint8Array): void {
  for (let at: number = 0; at < bytes.length;) {
    const id: number = zipU16(bytes,at); const size: number = zipU16(bytes,at+2); at += 4;
    if (at+size > bytes.length || (id !== 0x5455 && id !== 0x7875)) { throw new KnowledgeFailure('UnsupportedExtra','zip'); } at += size;
  }
}
export async function pdfInspectZip(reader: KnowledgeRangeReader, cancel: KnowledgeCancellation): Promise<PdfZipManifest> {
  if (!Number.isSafeInteger(reader.length) || reader.length < 22 || reader.length > PdfBudget.zipBytes) { throw new KnowledgeFailure('ZipSize','zip'); }
  const tailBytes: number = Math.min(reader.length,65557); const tail: Uint8Array = await reader.read(reader.length-tailBytes,tailBytes,cancel);
  let end: number = -1;
  for (let at: number = tail.length-22; at >= 0; at--) { if (zipU32(tail,at) === 0x06054b50 && at+22+zipU16(tail,at+20) === tail.length) { if (end >= 0) { throw new KnowledgeFailure('AmbiguousEocd','zip'); } end = at; } }
  if (end < 0 || zipU16(tail,end+4) !== 0 || zipU16(tail,end+6) !== 0 || zipU16(tail,end+8) !== zipU16(tail,end+10) || zipU16(tail,end+20) !== 0) { throw new KnowledgeFailure('EocdUnsupported','zip'); }
  const entries: number = zipU16(tail,end+10); const directoryBytes: number = zipU32(tail,end+12); const directoryOffset: number = zipU32(tail,end+16);
  if (entries < 1 || entries > PdfBudget.members || directoryBytes > 1048576 || directoryOffset+directoryBytes !== reader.length-tailBytes+end) { throw new KnowledgeFailure('DirectoryBudgetOrRange','zip'); }
  const directory: Uint8Array = await reader.read(directoryOffset,directoryBytes,cancel);
  const manifest: PdfZipManifest = new PdfZipManifest(); manifest.zipBytes = reader.length;
  const names: Set<string> = new Set<string>(); let at: number = 0; let declared: number = 0; let compressed: number = 0;
  for (let index: number = 0; index < entries; index++) {
    cancel.check(); if (zipU32(directory,at) !== 0x02014b50 || at+46 > directory.length) { throw new KnowledgeFailure('CentralHeader','zip'); }
    const extract: number = zipU16(directory,at+6); const flags: number = zipU16(directory,at+8); const method: number = zipU16(directory,at+10);
    const packed: number = zipU32(directory,at+20); const size: number = zipU32(directory,at+24); const nameBytes: number = zipU16(directory,at+28);
    const extra: number = zipU16(directory,at+30); const comment: number = zipU16(directory,at+32); const external: number = zipU32(directory,at+38); const local: number = zipU32(directory,at+42);
    if (extract > 20 || (flags !== 0 && flags !== 0x800) || (method !== 0 && method !== 8) || packed === 0xffffffff || size === 0xffffffff || local === 0xffffffff || zipU16(directory,at+34) !== 0 || nameBytes < 1 || nameBytes > 512 || at+46+nameBytes+extra+comment > directory.length || comment !== 0) { throw new KnowledgeFailure('UnsupportedZipFeature','zip'); }
    const rawName: Uint8Array = directory.slice(at+46,at+46+nameBytes); const name: string = pdfStrictUtf8(rawName);
    if (flags === 0 && rawName.some((byte: number): boolean => byte > 127)) { throw new KnowledgeFailure('NameEncodingUnverified','zip'); }
    const key: string = pdfZipLogicalName(name); if (names.has(key)) { throw new KnowledgeFailure('MemberCollision','zip'); } names.add(key);
    const mode: number = Math.floor(external/65536)&0xf000; const directoryMember: boolean = name.endsWith('/');
    if ((mode !== 0 && mode !== (directoryMember ? 0x4000 : 0x8000)) || (!directoryMember && (external&16) !== 0)) { throw new KnowledgeFailure('LinkOrSpecialMember','zip'); }
    if (size > PdfBudget.memberBytes || (name.toLowerCase().endsWith('.json') && size > PdfBudget.jsonBytes) || size > Math.max(1,packed)*128 || (method === 0 && packed !== size) || (directoryMember && (size !== 0 || packed !== 0))) { throw new KnowledgeFailure('MemberBudget','zip'); }
    zipExtras(directory.slice(at+46+nameBytes,at+46+nameBytes+extra));
    const member: PdfZipMember = new PdfZipMember(); member.id = `member-${index}`; member.logicalName = name; member.method = method; member.flags = flags;
    member.localOffset = local; member.compressedBytes = packed; member.declaredBytes = size; member.crc32 = zipU32(directory,at+16); member.directory = directoryMember;
    manifest.members.push(member); declared = pdfZipReserve(declared,size,PdfBudget.expandedBytes); compressed += packed; at += 46+nameBytes+extra+comment;
  }
  if (at !== directory.length || declared > Math.max(1,compressed)*128) { throw new KnowledgeFailure('DirectoryTrailingOrRatio','zip'); }
  const ordered: PdfZipMember[] = manifest.members.slice().sort((a: PdfZipMember,b: PdfZipMember): number => a.localOffset-b.localOffset); let expected: number = 0;
  for (const member of ordered) {
    cancel.check(); if (member.localOffset !== expected || member.localOffset+30 > directoryOffset) { throw new KnowledgeFailure('MemberOverlapOrGap','zip'); }
    const header: Uint8Array = await reader.read(member.localOffset,30,cancel); const nameSize: number = zipU16(header,26); const extraSize: number = zipU16(header,28);
    if (zipU32(header,0) !== 0x04034b50 || zipU16(header,4) > 20 || zipU16(header,6) !== member.flags || zipU16(header,8) !== member.method || zipU32(header,14) !== member.crc32 || zipU32(header,18) !== member.compressedBytes || zipU32(header,22) !== member.declaredBytes || nameSize > 512 || extraSize > 65535) { throw new KnowledgeFailure('LocalCentralMismatch','zip'); }
    member.payloadOffset = member.localOffset+30+nameSize+extraSize;
    if (member.payloadOffset+member.compressedBytes > directoryOffset) { throw new KnowledgeFailure('PayloadRange','zip'); }
    const variable: Uint8Array = await reader.read(member.localOffset+30,nameSize+extraSize,cancel);
    if (pdfStrictUtf8(variable.slice(0,nameSize)) !== member.logicalName) { throw new KnowledgeFailure('LocalNameMismatch','zip'); } zipExtras(variable.slice(nameSize));
    expected = member.payloadOffset+member.compressedBytes;
    const key: string = pdfZipLogicalName(member.logicalName);
    if (!member.directory && Array.from(names).some((other: string): boolean => other.startsWith(key+'/'))) { throw new KnowledgeFailure('DirectoryFileCollision','zip'); }
  }
  if (expected !== directoryOffset) { throw new KnowledgeFailure('UnknownZipPrefixOrTrailer','zip'); } return manifest;
}
