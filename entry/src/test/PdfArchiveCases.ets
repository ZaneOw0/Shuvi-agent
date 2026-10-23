import { pdfZipLogicalName, pdfZipReserve, pdfStrictUtf8 } from '../main/ets/knowledge/pipeline/SafeZipPolicy';
export interface PdfArchiveTestCase { name: string; run: () => Promise<void>; }
function pdfArchiveRejects(action: () => void): void { let rejected: boolean = false; try { action(); } catch { rejected = true; } if (!rejected) { throw new Error('Expected archive boundary rejection'); } }
export function pdfArchiveCases(): PdfArchiveTestCase[] {
  return [
    { name: 'ZIP危险路径/嵌套归档/编码拒绝', run: async (): Promise<void> => {
      for (const name of ['/x','../x','a/../x','a//b','a\\b','C:a','a/./b','a.zip','a.tar.gz','a\u0000b']) { pdfArchiveRejects((): void => { pdfZipLogicalName(name); }); }
      pdfZipLogicalName('images/formula.jpg');
      for (const bytes of [new Uint8Array([0xc0,0x80]),new Uint8Array([0xed,0xa0,0x80]),new Uint8Array([0xf4,0x90,0x80,0x80]),new Uint8Array([0xe2,0x82])]) { pdfArchiveRejects((): void => { pdfStrictUtf8(bytes); }); }
    } },
    { name: 'ZIP实际预算在写入前预约', run: async (): Promise<void> => {
      pdfZipReserve(10,20,30); pdfArchiveRejects((): void => { pdfZipReserve(10,21,30); });
      pdfArchiveRejects((): void => { pdfZipReserve(-1,1,30); });
    } }
  ];
}
// Prepared only. Must receive the real platform adapter; host never calls this.
export interface PdfNativeArchiveCapabilityCase {
  name: string; requiredEvidence: string[];
}
export function pdfNativeArchiveCapabilityCases(): PdfNativeArchiveCapabilityCase[] {
  return [{ name: 'raw-DEFLATE multi-buffer capability', requiredEvidence: ['exact compressed consumption','STREAM_END','64KiB input/output','incremental CRC32','independent SHA256','no-progress rejection','trailing input rejection','cancel keeps Releasing until inflateEnd','CRC failure releases stream/file','STORED actual accounting'] }];
}
