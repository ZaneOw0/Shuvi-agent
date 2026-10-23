import { fileIo, ReadOptions } from '@kit.CoreFileKit';
import { PdfAssetDescriptor, PdfDerivedImage, KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { pdfStrictUtf8 } from '../pipeline/SafeZipPolicy';
import { ParsedImageAsset, ParsedAssetWrite, ParsedCancellation, ParsedAssetState } from '../domain/ParsedDocumentModels';
import { ParsedAssetPort } from '../domain/ParsedDocumentPorts';

export interface PdfImageDescriptorPort { assetDescriptor(id: string): Promise<PdfAssetDescriptor>; }
export class PdfImagePayloadExporter {
  private root: string; private ledger: PdfImageDescriptorPort; private identity: KnowledgeIdentityPort;
  constructor(root: string, ledger: PdfImageDescriptorPort, identity: KnowledgeIdentityPort) { this.root = root; this.ledger = ledger; this.identity = identity; }
  private async read(id: string, name: string, maximum: number, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    if (!new RegExp('^kb-[a-f0-9]{32}$').test(id) || !new RegExp('^(manifest|part-0-[0-9]+)$').test(name)) { throw new KnowledgeFailure('LegacyImagePath','export'); }
    const file: fileIo.File = await fileIo.open(`${this.root}/${id}/${name}`,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
    try {
      const stat: fileIo.Stat = await fileIo.stat(file.fd); if (!stat.isFile() || stat.size < 1 || stat.size > maximum) { throw new KnowledgeFailure('LegacyImageReadBudget','export'); }
      const out: Uint8Array = new Uint8Array(stat.size); let at: number = 0;
      while (at < out.length) { cancel.check(); const b: ArrayBuffer = new ArrayBuffer(Math.min(65536,out.length-at)); const options: ReadOptions = { offset: at, length: b.byteLength }; const n: number = await fileIo.read(file.fd,b,options); if (n < 1 || n > b.byteLength) { throw new KnowledgeFailure('LegacyImageTruncated','export'); } out.set(new Uint8Array(b,0,n),at); at += n; }
      return out;
    } finally { await fileIo.close(file); }
  }
  async payload(image: PdfDerivedImage, generation: string, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    const descriptor: PdfAssetDescriptor = await this.ledger.assetDescriptor(image.id);
    if (descriptor.id !== image.id || descriptor.generation !== generation || image.bytes < 1 || image.bytes > 20971520 || image.mime !== 'image/jpeg') { throw new KnowledgeFailure('LegacyImageOwner','export'); }
    let bytes: Uint8Array;
    if (descriptor.format === 'PDF-DERIVED-JPEG-1') {
      bytes = await this.read(image.id,'part-0-0',20971520,cancel);
      if (descriptor.hash !== image.sha256 || descriptor.bytes !== image.bytes) { throw new KnowledgeFailure('LegacyImageV1Identity','export'); }
    } else if (descriptor.format === 'PDF-DERIVED-JPEG-2') {
      const raw: Uint8Array = await this.read(image.id,'manifest',1048576,cancel);
      if (await this.identity.hash(raw) !== descriptor.hash) { throw new KnowledgeFailure('LegacyImageManifestHash','export'); }
      const fields: string[] = pdfStrictUtf8(raw).split('\n');
      if (fields.length !== 5 || fields[0] !== descriptor.format || fields[1] !== image.id || fields[2] !== image.sha256 || Number(fields[3]) !== image.bytes) { throw new KnowledgeFailure('LegacyImageManifestIdentity','export'); }
      const hashes: string[] = fields[4].split(','); if (hashes.length !== Math.ceil(image.bytes/65536)) { throw new KnowledgeFailure('LegacyImagePartCount','export'); }
      bytes = new Uint8Array(image.bytes); let at: number = 0;
      for (let i: number = 0; i < hashes.length; i++) {
        const part: Uint8Array = await this.read(image.id,`part-0-${i}`,65536,cancel);
        if (part.length !== Math.min(65536,image.bytes-at) || await this.identity.hash(part) !== hashes[i]) { throw new KnowledgeFailure('LegacyImagePartHash','export'); } bytes.set(part,at); at += part.length;
      }
    } else { throw new KnowledgeFailure('LegacyImageFormat','export'); }
    if (bytes.length !== image.bytes || await this.identity.hash(bytes) !== image.sha256 || bytes[0] !== 255 || bytes[1] !== 216 || bytes[bytes.length-2] !== 255 || bytes[bytes.length-1] !== 217) { throw new KnowledgeFailure('LegacyImagePayloadHash','export'); }
    return bytes;
  }
  async export(image: PdfDerivedImage, oldGeneration: string, document: string, generation: string, id: string, assets: ParsedAssetPort, cancel: KnowledgeCancellation): Promise<ParsedImageAsset> {
    const bytes: Uint8Array = await this.payload(image,oldGeneration,cancel); const descriptor: PdfAssetDescriptor = await this.ledger.assetDescriptor(image.id);
    const a: ParsedImageAsset = new ParsedImageAsset(); a.id = id; a.relativePath = `images/${id}`; a.payloadHash = image.sha256; a.bytes = image.bytes; a.mime = image.mime; a.pixelWidth = image.pixelWidth; a.pixelHeight = image.pixelHeight; a.frames = 1; a.legacyContainerHash = descriptor.hash; a.member = image.memberId; a.state = ParsedAssetState.Reserved;
    const w: ParsedAssetWrite = new ParsedAssetWrite(); w.id = id; w.documentKey = document; w.generation = generation; w.role = 'image'; w.hash = a.payloadHash; w.bytes = a.bytes; w.relativePath = a.relativePath;
    const token: ParsedCancellation = new ParsedCancellation(); token.deadline = cancel.deadline; return assets.save(a,w,bytes,token);
  }
}
