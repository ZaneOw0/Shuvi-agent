import { fileIo, ReadOptions, WriteOptions } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util, taskpool } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { PdfAssetPort, PdfArchivePort } from '../domain/KnowledgePorts';
import { PdfNormalizedDocument, PdfContentNode, PdfBudget, KnowledgeCancellation, KnowledgeCleanupIntent, KnowledgeFailure, PdfDerivedImage, PdfZipMember, PdfAssetWriteRecord, PdfAssetDescriptor } from '../domain/PdfKnowledgeModels';
import { documentEnsureDirectory, documentDigestHex } from './DocumentFileOperations';
import { pdfCodecUtf8, pdfDecodeSnapshotHeader, pdfDecodeSnapshotNode } from '../pipeline/PdfSnapshotCodec';
import { BoundedDocumentJson, PdfJsonNode } from '../pipeline/BoundedDocumentJson';
import { KnowledgeDerivedCleanupPort } from '../application/KnowledgeLifecycleService';
import { pdfEncodeNodeWorker, pdfHydrateHeaderWorker, pdfHydrateNodeWorker } from './PdfSnapshotWorker';
import { PdfWorkerResult } from '../domain/PdfWorkerModels';
import { pdfWorkerPayload, pdfWorkerReadNode, pdfWorkerReadSnapshot, pdfWorkerRejected } from '../pipeline/PdfWorkerPolicy';
import { pdfWorkerAwait } from './PdfWorkerSupport';
import { PdfImageDescriptorPort, PdfImagePayloadExporter } from './PdfImagePayload';
import { ParsedImageAsset } from '../domain/ParsedDocumentModels';
import { ParsedAssetPort } from '../domain/ParsedDocumentPorts';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';

export interface PdfAssetLedgerPort extends PdfImageDescriptorPort {
  reserveAsset(id: string, generation: string, bytes: number): Promise<void>;
  commitAsset(id: string, hash: string, bytes: number, manifest: string): Promise<void>;
  derivedBytes(): Promise<number>;
  assetIds(): Promise<string[]>;
  assetHash(id: string): Promise<string>;
  describeAsset(id: string, member: string, type: string, hash: string): Promise<void>;
  assetPhase(id: string, phase: string, hash: string, actual: number): Promise<void>;
  assetWrites(): Promise<PdfAssetWriteRecord[]>;
  relateAsset(id: string, node: string, relationship: string): Promise<void>;
  assetDescriptor(id: string): Promise<PdfAssetDescriptor>;
  reusableImage(generation: string, member: string): Promise<string>;
  snapshotAssets(generation: string): Promise<string[]>;
}
export class PdfAssetAdapter implements PdfAssetPort, KnowledgeDerivedCleanupPort {
  private cleanupGuard: ((assets: string[], action: () => Promise<void>) => Promise<void>) | undefined;
  attachCleanupGuard(guard: (assets: string[], action: () => Promise<void>) => Promise<void>): void { this.cleanupGuard = guard; }
  private filesRoot: string; private cacheRoot: string; private ledger: PdfAssetLedgerPort;
  private scope: KnowledgeStorageScope; private fault: string = '';
  private async encodeNode(node: PdfContentNode, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    try {
      const result: PdfWorkerResult = await pdfWorkerAwait(taskpool.execute<[PdfContentNode,number],PdfWorkerResult>(pdfEncodeNodeWorker,node,cancel.deadline),'encode-node',cancel);
      const parts: Uint8Array[] = pdfWorkerPayload(result,'encode-node',cancel);
      const restored: PdfContentNode = pdfWorkerReadNode(parts,cancel,'encode-node');
      if (JSON.stringify(restored) !== JSON.stringify(node)) { throw new KnowledgeFailure('WorkerResultInvalid','pdf-encode-node'); } return parts[0];
    } catch (error) { const system: BusinessError = error; throw error instanceof KnowledgeFailure ? error : pdfWorkerRejected('encode-node',cancel,system?.code); }
  }
  private async hydrateNode(bytes: Uint8Array, cancel: KnowledgeCancellation): Promise<PdfContentNode> {
    try {
      const result: PdfWorkerResult = await pdfWorkerAwait(taskpool.execute<[Uint8Array,number],PdfWorkerResult>(pdfHydrateNodeWorker,bytes,cancel.deadline),'hydrate-node',cancel);
      return pdfWorkerReadNode(pdfWorkerPayload(result,'hydrate-node',cancel),cancel,'hydrate-node');
    } catch (error) { const system: BusinessError = error; throw error instanceof KnowledgeFailure ? error : pdfWorkerRejected('hydrate-node',cancel,system?.code); }
  }
  private async hydrateHeader(bytes: Uint8Array, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument> {
    try {
      const result: PdfWorkerResult = await pdfWorkerAwait(taskpool.execute<[Uint8Array,number],PdfWorkerResult>(pdfHydrateHeaderWorker,bytes,cancel.deadline),'hydrate-header',cancel);
      return pdfWorkerReadSnapshot(pdfWorkerPayload(result,'hydrate-header',cancel),cancel,'hydrate-header');
    } catch (error) { const system: BusinessError = error; throw error instanceof KnowledgeFailure ? error : pdfWorkerRejected('hydrate-header',cancel,system?.code); }
  }
  constructor(filesDir: string, cacheDir: string, ledger: PdfAssetLedgerPort, scope: KnowledgeStorageScope = KnowledgeStorageScope.production()) { this.filesRoot = `${filesDir}/${scope.derivedDirectory}`; this.cacheRoot = `${cacheDir}/${scope.derivedDirectory}`; this.ledger = ledger; this.scope = scope; }
  injectFault(owner: string, stage: string): void { this.scope.requireTestOwner(owner); if (['Reserved','Part','Manifest','Renamed','Committed'].indexOf(stage) < 0) { throw new KnowledgeFailure('FaultStageInvalid','test'); } this.fault = stage; }
  private boundary(stage: string): void { if (this.fault === stage) { this.fault = ''; throw new KnowledgeFailure(`Injected${stage}`,'test'); } }
  private safeId(id: string): void { if (!new RegExp('^kb-[a-f0-9]{32}$').test(id)) { throw new KnowledgeFailure('DerivedIdInvalid','pdf-assets'); } }
  async legacyImageFixture(owner: string, id: string, generation: string, bytes: Uint8Array, cancel: KnowledgeCancellation): Promise<string> {
    this.scope.requireTestOwner(owner); this.safeId(id); if (bytes.length > PdfBudget.memberBytes) { throw new KnowledgeFailure('ImageBytesBudget','test'); }
    await this.reconcile(); await this.ledger.reserveAsset(id,generation,bytes.length); await this.ledger.describeAsset(id,'legacy-fixture','PDF-DERIVED-JPEG-1','');
    const directory: string = `${this.filesRoot}/${id}`; await fileIo.mkdir(directory); const hash: string = await this.writeFile(directory,'part-0-0',bytes,cancel); await this.ledger.commitAsset(id,hash,bytes.length,'PDF-DERIVED-JPEG-1'); return hash;
  }
  async usageBytes(): Promise<number> { return this.ledger.derivedBytes(); }
  async recoverSnapshot(generation: string, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument | undefined> {
    await this.reconcile(); const ids: string[] = await this.ledger.snapshotAssets(generation); if (ids.length > 1) { throw new KnowledgeFailure('MultipleCompleteSnapshots','recovery'); }
    return ids.length === 0 ? undefined : this.read(ids[0],cancel);
  }
  async saveImages(snapshot: PdfNormalizedDocument, archive: PdfArchivePort, cancel: KnowledgeCancellation): Promise<void> {
    await this.reconcile(); const referenced: Set<string> = new Set<string>();
    for (const node of snapshot.nodes) { for (const id of node.assetIds) { referenced.add(id); } }
    for (const memberId of referenced) {
      cancel.check(); const member: PdfZipMember | undefined = snapshot.manifest.members.find((item: PdfZipMember): boolean => item.id === memberId);
      if (member === undefined || !member.verified) { throw new KnowledgeFailure('ImageMemberMissing','pdf-assets'); }
      const reusable: string = await this.ledger.reusableImage(snapshot.generation,memberId);
      if (reusable.length > 0) {
        const existing: PdfDerivedImage | undefined = snapshot.images.find((row: PdfDerivedImage): boolean => row.id === reusable && row.memberId === memberId && row.sha256 === member.sha256);
        if (existing !== undefined) { await this.readImage(existing,snapshot.generation,cancel); continue; }
        const bytes: Uint8Array = await this.readImageBytes(reusable,snapshot.generation,member.sha256,member.declaredBytes,cancel);
        const source: image.ImageSource = image.createImageSource(bytes.slice().buffer);
        try {
          const info: image.ImageInfo = await source.getImageInfo(); const reused: PdfDerivedImage = new PdfDerivedImage(); reused.id = reusable; reused.memberId = memberId; reused.sha256 = member.sha256; reused.bytes = bytes.length; reused.mime = 'image/jpeg'; reused.pixelWidth = info.size.width; reused.pixelHeight = info.size.height;
          const parent: PdfContentNode | undefined = snapshot.nodes.find((node: PdfContentNode): boolean => node.assetIds.indexOf(memberId) >= 0); reused.parentNodeId = parent?.id ?? ''; reused.relationship = parent?.kind ?? 'Unverified'; snapshot.images.push(reused);
          for (const node of snapshot.nodes) { if (node.assetIds.indexOf(memberId) >= 0) { await this.ledger.relateAsset(reusable,node.id,node.kind); } }
        } finally { await source.release(); } continue;
      }
      const bytes: Uint8Array = await archive.readMember(snapshot.manifest,member,cancel);
      if (bytes.length < 4 || bytes[0] !== 255 || bytes[1] !== 216) { throw new KnowledgeFailure('ImageTypeUnsupported','pdf-assets'); }
      let width: number = 0; let height: number = 0;
      for (let at: number = 2; at+4 <= bytes.length;) {
        if (bytes[at++] !== 255) { throw new KnowledgeFailure('JpegStructure','pdf-assets'); }
        while (bytes[at] === 255 && at < bytes.length) { at++; } const marker: number = bytes[at++];
        if (marker === 0xd9 || marker === 0xda) { break; }
        const length: number = bytes[at]*256+bytes[at+1]; if (length < 2 || at+length > bytes.length) { throw new KnowledgeFailure('JpegTruncated','pdf-assets'); }
        if ([0xc0,0xc1,0xc2].indexOf(marker) >= 0) { if (length < 8) { throw new KnowledgeFailure('JpegFrame','pdf-assets'); } height = bytes[at+3]*256+bytes[at+4]; width = bytes[at+5]*256+bytes[at+6]; break; } at += length;
      }
      if (width < 1 || height < 1 || width*height > PdfBudget.pixels) { throw new KnowledgeFailure('ImagePixelBudget','pdf-assets'); }
      if (bytes[bytes.length-2] !== 255 || bytes[bytes.length-1] !== 217) { throw new KnowledgeFailure('JpegEndMissing','pdf-assets'); }
      const buffer: ArrayBuffer = new ArrayBuffer(bytes.length); new Uint8Array(buffer).set(bytes);
      const source: image.ImageSource = image.createImageSource(buffer); let pixels: image.PixelMap | undefined = undefined;
      try {
        const info: image.ImageInfo = await source.getImageInfo(0); cancel.check();
        if (info.size.width !== width || info.size.height !== height || info.mimeType !== 'image/jpeg') { throw new KnowledgeFailure('ImageDecodedIdentity','pdf-assets'); }
        const options: image.DecodingOptions = { desiredPixelFormat: image.PixelMapFormat.RGBA_8888, editable: false };
        pixels = await source.createPixelMap(options); cancel.check();
        const decoded: image.ImageInfo = await pixels.getImageInfo(); const memory: number = pixels.getPixelBytesNumber();
        if (decoded.size.width !== width || decoded.size.height !== height || memory < width*height || memory > PdfBudget.pixels*4) { throw new KnowledgeFailure('ImageDecodedBudget','pdf-assets'); }
        await pixels.readAllPixelsToBuffer(new ArrayBuffer(memory)); cancel.check();
      } finally { try { await pixels?.release(); } finally { await source.release(); } }
      const id: string = 'kb-'+documentDigestHex(cryptoFramework.createRandom().generateRandomSync(16).data);
      const manifestReserve: number = 256+Math.ceil(bytes.length/65536)*100;
      await this.ledger.reserveAsset(id,snapshot.generation,bytes.length+manifestReserve); await this.ledger.describeAsset(id,memberId,'PDF-DERIVED-JPEG-2',member.sha256);
      const directory: string = `${this.cacheRoot}/${id}`; await fileIo.mkdir(directory); const hashes: string[] = [];
      for (let at: number = 0; at < bytes.length; at += 65536) { hashes.push(await this.writeFile(directory,`part-0-${hashes.length}`,bytes.slice(at,at+65536),cancel)); }
      const imageManifest: Uint8Array = pdfCodecUtf8(['PDF-DERIVED-JPEG-2',id,member.sha256,`${bytes.length}`,hashes.join(',')].join('\n'));
      const hash: string = await this.writeFile(directory,'manifest',imageManifest,cancel);
      await this.ledger.assetPhase(id,'ManifestVerified',hash,bytes.length+imageManifest.length); cancel.check();
      await fileIo.rename(directory,`${this.filesRoot}/${id}`); await this.ledger.assetPhase(id,'Renamed',hash,bytes.length+imageManifest.length);
      await this.ledger.commitAsset(id,hash,bytes.length+imageManifest.length,'PDF-DERIVED-JPEG-2');
      const derivedImage: PdfDerivedImage = new PdfDerivedImage(); derivedImage.id = id; derivedImage.memberId = memberId; derivedImage.sha256 = member.sha256; derivedImage.bytes = bytes.length; derivedImage.pixelWidth = width; derivedImage.pixelHeight = height; derivedImage.mime = 'image/jpeg';
      const parent: PdfContentNode | undefined = snapshot.nodes.find((node: PdfContentNode): boolean => node.assetIds.indexOf(memberId) >= 0); derivedImage.parentNodeId = parent?.id ?? ''; derivedImage.relationship = parent?.kind ?? 'Unverified'; snapshot.images.push(derivedImage);
      for (const node of snapshot.nodes) { if (node.assetIds.indexOf(memberId) >= 0) { await this.ledger.relateAsset(id,node.id,node.kind); } }
    }
  }
  async reconcile(): Promise<void> {
    await documentEnsureDirectory(this.filesRoot); await documentEnsureDirectory(this.cacheRoot);
    // Unregistered files are not deleted. Reconciliation requires a durable owner
    // and cleanup intent, supplied by lifecycle; unknown bytes block new writes.
    const names: string[] = await fileIo.listFile(this.filesRoot);
    if (names.length > 10000) { throw new KnowledgeFailure('DerivedDirectoryBudget','pdf-assets'); }
    const registered: string[] = await this.ledger.assetIds();
    for (const record of await this.ledger.assetWrites()) {
      if (record.phase === 'ManifestVerified' || record.phase === 'Renamed') {
        this.safeId(record.id); const final: string = `${this.filesRoot}/${record.id}`; const pending: string = `${this.cacheRoot}/${record.id}`;
        const hasFinal: boolean = await fileIo.access(final); const hasPending: boolean = await fileIo.access(pending);
        if (hasFinal && hasPending) { throw new KnowledgeFailure('RecoveryDoubleLocation','pdf-assets'); }
        if (!hasFinal && !hasPending) { throw new KnowledgeFailure('RecoveryAssetMissing','pdf-assets'); }
        await this.verifyWrittenManifest(hasFinal ? final : pending,record,new KnowledgeCancellation());
        if (!hasFinal) { await fileIo.rename(pending,final); }
        await this.ledger.commitAsset(record.id,record.hash,record.actual,record.type);
      }
    }
    const cache: string[] = await fileIo.listFile(this.cacheRoot);
    if (names.concat(cache).some((name: string): boolean => registered.indexOf(name) < 0)) { throw new KnowledgeFailure('UnregisteredDerivedBytes','pdf-assets'); }
    let actual: number = 0;
    for (const root of [this.filesRoot,this.cacheRoot]) {
      for (const id of await fileIo.listFile(root)) {
        this.safeId(id); const directory: string = `${root}/${id}`; const stat: fileIo.Stat = await fileIo.lstat(directory);
        if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new KnowledgeFailure('DerivedDirectoryUnsafe','pdf-assets'); }
        const parts: string[] = await fileIo.listFile(directory); if (parts.length > 20001) { throw new KnowledgeFailure('DerivedPartsBudget','pdf-assets'); }
        for (const name of parts) {
          if (!new RegExp('^(manifest|part-[0-9]+-[0-9]+|part)$').test(name)) { throw new KnowledgeFailure('DerivedPartUnknown','pdf-assets'); }
          const part: fileIo.Stat = await fileIo.lstat(`${directory}/${name}`);
          let maximum: number = PdfBudget.rowBytes*4;
          if (name === 'part-0-0' && part.size > maximum) { const descriptor: PdfAssetDescriptor = await this.ledger.assetDescriptor(id); if (descriptor.format === 'PDF-DERIVED-JPEG-1') { maximum = Math.min(PdfBudget.memberBytes,descriptor.bytes); } }
          if (!part.isFile() || part.isSymbolicLink() || part.size > maximum) { throw new KnowledgeFailure('DerivedPartUnsafe','pdf-assets'); }
          actual += part.size; if (actual > PdfBudget.derivedBytes) { throw new KnowledgeFailure('DerivedBudget','pdf-assets'); }
        }
      }
    }
    if (actual > await this.ledger.derivedBytes()) { throw new KnowledgeFailure('DerivedAccountingMismatch','pdf-assets'); }
  }
  private async verifyWrittenManifest(directory: string, record: PdfAssetWriteRecord, cancel: KnowledgeCancellation): Promise<void> {
    const bytes: Uint8Array = await this.readFile(directory,'manifest',1048576,cancel); const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: bytes }; await digest.update(blob);
    if (documentDigestHex((await digest.digest()).data) !== record.hash) { throw new KnowledgeFailure('RecoveryManifestMismatch','pdf-assets'); }
    const fields: string[] = util.TextDecoder.create('utf-8',{ fatal: true }).decodeToString(bytes).split('\n');
    if (fields.length !== 5 || fields[0] !== record.type || fields[1] !== record.id) { throw new KnowledgeFailure('RecoveryManifestIdentity','pdf-assets'); }
    let names: string[] = []; let hashes: string[] = []; let total: number = bytes.length;
    if (record.type === 'PDF-NORMALIZED-1') { names = fields[3].split(';').join(',').split(','); hashes = fields[4].split(','); }
    else if (record.type === 'PDF-DERIVED-JPEG-2') { hashes = fields[4].split(','); for (let at: number = 0; at < hashes.length; at++) { names.push(`part-0-${at}`); } }
    else { throw new KnowledgeFailure('RecoveryTypeUnknown','pdf-assets'); }
    if (names.length !== hashes.length || names.length > 20000) { throw new KnowledgeFailure('RecoveryPartsBudget','pdf-assets'); }
    for (let at: number = 0; at < names.length; at++) {
      const block: Uint8Array = await this.readFile(directory,names[at],65536,cancel); total += block.length;
      const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const value: cryptoFramework.DataBlob = { data: block }; await md.update(value);
      if (documentDigestHex((await md.digest()).data) !== hashes[at]) { throw new KnowledgeFailure('RecoveryPartHashMismatch','pdf-assets'); }
    }
    if (total !== record.actual || total > record.bytes) { throw new KnowledgeFailure('RecoveryActualMismatch','pdf-assets'); }
  }
  async save(snapshot: PdfNormalizedDocument, cancel: KnowledgeCancellation): Promise<void> {
    this.safeId(snapshot.id); cancel.check(); await this.reconcile();
    if (!snapshot.coverage.hardPassed || snapshot.nodes.length > PdfBudget.nodes) { throw new KnowledgeFailure('SnapshotUnverified','pdf-assets'); }
    const parts: string[] = []; const hashes: string[] = [];
    const header: PdfNormalizedDocument = new PdfNormalizedDocument(); header.id = snapshot.id; header.hash = snapshot.hash; header.documentId = snapshot.documentId;
    header.generation = snapshot.generation;
    header.binding = snapshot.binding; header.manifest = snapshot.manifest; header.images = snapshot.images; header.coverage = snapshot.coverage;
    header.profile = snapshot.profile; header.adapterVersion = snapshot.adapterVersion; header.normalizationVersion = snapshot.normalizationVersion; header.filterVersion = snapshot.filterVersion;
    const headerBytes: Uint8Array = pdfCodecUtf8(JSON.stringify(header));
    let bytesTotal: number = headerBytes.length; let partCount: number = Math.ceil(bytesTotal/65536);
    if (bytesTotal > PdfBudget.jsonBytes) { throw new KnowledgeFailure('SnapshotHeaderBudget','pdf-assets'); }
    for (const node of snapshot.nodes) {
      cancel.check(); const raw: Uint8Array = await this.encodeNode(node,cancel); cancel.check(); const length: number = raw.length;
      if (length > PdfBudget.jsonBytes || length > PdfBudget.expandedBytes-bytesTotal) { throw new KnowledgeFailure('SnapshotNodeBudget','pdf-assets'); }
      bytesTotal += length; partCount += Math.ceil(length/65536);
    }
    const manifestReservation: number = 128+partCount*100;
    if (manifestReservation > 1048576) { throw new KnowledgeFailure('ManifestBudget','pdf-assets'); }
    await this.ledger.reserveAsset(snapshot.id,snapshot.generation,bytesTotal+manifestReservation);
    await this.ledger.describeAsset(snapshot.id,'','PDF-NORMALIZED-1','');
    this.boundary('Reserved');
    const directory: string = `${this.cacheRoot}/${snapshot.id}`; await fileIo.mkdir(directory);
    for (let i: number = 0; i <= snapshot.nodes.length; i++) {
      cancel.check(); const bytes: Uint8Array = i === 0 ? headerBytes : await this.encodeNode(snapshot.nodes[i-1],cancel); const names: string[] = [];
      for (let offset: number = 0; offset < bytes.length; offset += 65536) {
        const name: string = `part-${i}-${names.length}`; const block: Uint8Array = bytes.slice(offset,offset+65536);
        hashes.push(await this.writeFile(directory,name,block,cancel)); names.push(name);
        this.boundary('Part');
      }
      parts.push(names.join(','));
    }
    const manifest: string = ['PDF-NORMALIZED-1',snapshot.id,`${snapshot.nodes.length}`,parts.join(';'),hashes.join(',')].join('\n');
    const manifestHash: string = await this.writeFile(directory,'manifest',pdfCodecUtf8(manifest),cancel); cancel.check();
    await this.ledger.assetPhase(snapshot.id,'ManifestVerified',manifestHash,bytesTotal+pdfCodecUtf8(manifest).length);
    this.boundary('Manifest');
    if (await fileIo.access(`${this.filesRoot}/${snapshot.id}`)) { throw new KnowledgeFailure('SnapshotAlreadyExists','pdf-assets'); }
    await fileIo.rename(directory,`${this.filesRoot}/${snapshot.id}`);
    await this.ledger.assetPhase(snapshot.id,'Renamed',manifestHash,bytesTotal+pdfCodecUtf8(manifest).length);
    this.boundary('Renamed');
    await this.ledger.commitAsset(snapshot.id,manifestHash,bytesTotal+pdfCodecUtf8(manifest).length,'PDF-NORMALIZED-1');
    this.boundary('Committed');
  }
  private async writeFile(directory: string, name: string, bytes: Uint8Array, cancel: KnowledgeCancellation): Promise<string> {
    const file: fileIo.File = await fileIo.open(`${directory}/${name}`,fileIo.OpenMode.CREATE|fileIo.OpenMode.READ_WRITE|fileIo.OpenMode.NOFOLLOW);
    try {
      let offset: number = 0;
      while (offset < bytes.length) { cancel.check(); const block: Uint8Array = bytes.slice(offset,offset+65536); const options: WriteOptions = { offset: offset,length: block.length }; const count: number = await fileIo.write(file.fd,block.buffer,options); if (count < 1 || count > block.length) { throw new KnowledgeFailure('AssetWriteIncomplete','pdf-assets'); } offset += count; }
      await fileIo.fsync(file.fd);
      const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: bytes }; await digest.update(blob); const expected: string = documentDigestHex((await digest.digest()).data);
      const actual: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      for (let at: number = 0; at < bytes.length;) {
        cancel.check(); const block: ArrayBuffer = new ArrayBuffer(Math.min(65536,bytes.length-at)); const options: ReadOptions = { offset: at,length: block.byteLength };
        const count: number = await fileIo.read(file.fd,block,options); if (count < 1 || count > block.byteLength) { throw new KnowledgeFailure('PartReadbackIncomplete','pdf-assets'); }
        const readBlob: cryptoFramework.DataBlob = { data: new Uint8Array(block,0,count) }; await actual.update(readBlob); at += count;
      }
      if (documentDigestHex((await actual.digest()).data) !== expected) { throw new KnowledgeFailure('PartReadbackHashMismatch','pdf-assets'); } return expected;
    } finally { await fileIo.close(file); }
  }
  private async readFile(directory: string, name: string, maximum: number, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    if (!new RegExp('^(manifest|part-[0-9]+-[0-9]+)$').test(name)) { throw new KnowledgeFailure('PartName','pdf-assets'); }
    const directoryStat: fileIo.Stat = await fileIo.lstat(directory); if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) { throw new KnowledgeFailure('SnapshotDirectory','pdf-assets'); }
    const file: fileIo.File = await fileIo.open(`${directory}/${name}`,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
    try {
      const stat: fileIo.Stat = await fileIo.stat(file.fd); if (!stat.isFile() || stat.size > maximum || stat.size < 1) { throw new KnowledgeFailure('PartSize','pdf-assets'); }
      const bytes: Uint8Array = new Uint8Array(stat.size); let offset: number = 0;
      while (offset < bytes.length) { cancel.check(); const block: ArrayBuffer = new ArrayBuffer(Math.min(65536,bytes.length-offset)); const options: ReadOptions = { offset: offset,length: block.byteLength }; const count: number = await fileIo.read(file.fd,block,options); if (count < 1 || count > block.byteLength) { throw new KnowledgeFailure('PartReadIncomplete','pdf-assets'); } bytes.set(new Uint8Array(block,0,count),offset); offset += count; } return bytes;
    } finally { await fileIo.close(file); }
  }
  async read(snapshotId: string, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument> {
    this.safeId(snapshotId); const directory: string = `${this.filesRoot}/${snapshotId}`;
    const wire: string = util.TextDecoder.create('utf-8',{ fatal: true }).decodeToString(await this.readFile(directory,'manifest',1048576,cancel));
    const manifestDigest: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const manifestBlob: cryptoFramework.DataBlob = { data: pdfCodecUtf8(wire) }; await manifestDigest.update(manifestBlob);
    if (documentDigestHex((await manifestDigest.digest()).data) !== await this.ledger.assetHash(snapshotId)) { throw new KnowledgeFailure('ManifestHashMismatch','pdf-assets'); }
    const fields: string[] = wire.split('\n'); if (fields.length !== 5 || fields[0] !== 'PDF-NORMALIZED-1' || fields[1] !== snapshotId) { throw new KnowledgeFailure('SnapshotManifest','pdf-assets'); }
    const count: number = Number(fields[2]); const groups: string[] = fields[3].split(';'); const hashes: string[] = fields[4].split(',');
    if (!Number.isSafeInteger(count) || count < 0 || count > PdfBudget.nodes || groups.length !== count+1 || hashes.length > 20000) { throw new KnowledgeFailure('SnapshotPartBudget','pdf-assets'); }
    let hashAt: number = 0; let snapshot: PdfNormalizedDocument | undefined = undefined;
    let aggregateBytes: number = 0;
    for (let group: number = 0; group < groups.length; group++) {
      const blocks: Uint8Array[] = []; let total: number = 0; const names: string[] = groups[group].split(',');
      if (names.length > 128) { throw new KnowledgeFailure('SnapshotNodeBudget','pdf-assets'); }
      for (let ordinal: number = 0; ordinal < names.length; ordinal++) {
        if (names[ordinal] !== `part-${group}-${ordinal}`) { throw new KnowledgeFailure('PartOrder','pdf-assets'); }
        const block: Uint8Array = await this.readFile(directory,names[ordinal],65536,cancel); total += block.length; aggregateBytes += block.length;
        if (aggregateBytes > PdfBudget.expandedBytes || total > PdfBudget.jsonBytes) { throw new KnowledgeFailure('SnapshotAggregateBudget','pdf-assets'); }
        const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: block }; await digest.update(blob);
        if (hashes[hashAt++] !== documentDigestHex((await digest.digest()).data)) { throw new KnowledgeFailure('SnapshotPartHash','pdf-assets'); } blocks.push(block);
      }
      if (total > PdfBudget.jsonBytes) { throw new KnowledgeFailure('SnapshotNodeBudget','pdf-assets'); }
      const bytes: Uint8Array = new Uint8Array(total); let offset: number = 0; for (const block of blocks) { bytes.set(block,offset); offset += block.length; }
      if (group === 0) { snapshot = await this.hydrateHeader(bytes,cancel); }
      else { if (snapshot === undefined) { throw new KnowledgeFailure('SnapshotHeaderMissing','pdf-assets'); } snapshot.nodes.push(await this.hydrateNode(bytes,cancel)); } cancel.check();
    }
    if (snapshot === undefined || snapshot.id !== snapshotId || snapshot.nodes.length !== count || hashAt !== hashes.length) { throw new KnowledgeFailure('SnapshotCoverage','pdf-assets'); }
    for (const derived of snapshot.images) {
      await this.readImage(derived,snapshot.generation,cancel);
      if (!snapshot.nodes.some((node: PdfContentNode): boolean => node.assetIds.indexOf(derived.memberId) >= 0)) { throw new KnowledgeFailure('ImageNodeRelationship','pdf-assets'); }
    } return snapshot;
  }
  async readImage(derived: PdfDerivedImage, generation: string, cancel: KnowledgeCancellation): Promise<Uint8Array> { return this.readImageBytes(derived.id,generation,derived.sha256,derived.bytes,cancel); }
  async exportImage(derived: PdfDerivedImage, oldGeneration: string, document: string, generation: string, id: string, target: ParsedAssetPort, identity: KnowledgeIdentityPort, cancel: KnowledgeCancellation): Promise<ParsedImageAsset> {
    return new PdfImagePayloadExporter(this.filesRoot,this.ledger,identity).export(derived,oldGeneration,document,generation,id,target,cancel);
  }
  private async readImageBytes(id: string, generation: string, hash: string, expectedBytes: number, cancel: KnowledgeCancellation): Promise<Uint8Array> {
      this.safeId(id); const imageRoot: string = `${this.filesRoot}/${id}`; const descriptor: PdfAssetDescriptor = await this.ledger.assetDescriptor(id);
      if (descriptor.generation !== generation || expectedBytes < 1 || expectedBytes > PdfBudget.memberBytes) { throw new KnowledgeFailure('ImageOwnerMismatch','pdf-assets'); }
      if (descriptor.format === 'PDF-DERIVED-JPEG-1') {
        const legacy: Uint8Array = await this.readFile(imageRoot,'part-0-0',PdfBudget.memberBytes,cancel);
        const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: legacy }; await digest.update(blob);
        const actual: string = documentDigestHex((await digest.digest()).data);
        if (legacy.length !== expectedBytes || actual !== hash || actual !== descriptor.hash || descriptor.bytes !== expectedBytes) { throw new KnowledgeFailure('LegacyImageHashMismatch','pdf-assets'); } return legacy;
      }
      if (descriptor.format !== 'PDF-DERIVED-JPEG-2') { throw new KnowledgeFailure('ImageFormatUnknown','pdf-assets'); }
      const imageManifest: Uint8Array = await this.readFile(imageRoot,'manifest',1048576,cancel);
      const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: imageManifest }; await md.update(blob);
      if (documentDigestHex((await md.digest()).data) !== descriptor.hash) { throw new KnowledgeFailure('ImageManifestHash','pdf-assets'); }
      const fields: string[] = util.TextDecoder.create('utf-8',{ fatal: true }).decodeToString(imageManifest).split('\n');
      if (fields.length !== 5 || fields[0] !== 'PDF-DERIVED-JPEG-2' || fields[1] !== id || fields[2] !== hash || Number(fields[3]) !== expectedBytes) { throw new KnowledgeFailure('ImageManifestIdentity','pdf-assets'); }
      const hashes: string[] = fields[4].split(','); const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); let total: number = 0;
      if (hashes.length !== Math.ceil(expectedBytes/65536)) { throw new KnowledgeFailure('ImagePartCount','pdf-assets'); }
      const output: Uint8Array = new Uint8Array(expectedBytes);
      for (let at: number = 0; at < hashes.length; at++) {
        const bytes: Uint8Array = await this.readFile(imageRoot,`part-0-${at}`,65536,cancel); if (bytes.length > expectedBytes-total) { throw new KnowledgeFailure('ImageReadbackLength','pdf-assets'); } output.set(bytes,total); total += bytes.length;
        const part: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const value: cryptoFramework.DataBlob = { data: bytes }; await part.update(value);
        if (documentDigestHex((await part.digest()).data) !== hashes[at]) { throw new KnowledgeFailure('ImagePartHash','pdf-assets'); } await digest.update(value);
      }
      if (total !== expectedBytes || documentDigestHex((await digest.digest()).data) !== hash) { throw new KnowledgeFailure('ImageReadbackHash','pdf-assets'); } return output;
  }
  async remove(claim: KnowledgeCleanupIntent): Promise<void> {
    const guard = this.cleanupGuard;
    if (guard !== undefined) { await guard(claim.assets,async (): Promise<void> => { await this.removeOwned(claim); }); }
    else { await this.removeOwned(claim); }
  }
  private async removeOwned(claim: KnowledgeCleanupIntent): Promise<void> {
    if (claim.claim.length === 0) { throw new KnowledgeFailure('CleanupClaimMissing','pdf-assets'); }
    for (const id of claim.assets) {
      this.safeId(id);
      for (const root of [this.filesRoot,this.cacheRoot]) {
        const directory: string = `${root}/${id}`; if (!(await fileIo.access(directory))) { continue; }
        const stat: fileIo.Stat = await fileIo.lstat(directory); if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new KnowledgeFailure('CleanupDirectoryUnsafe','pdf-assets'); }
        const names: string[] = await fileIo.listFile(directory); if (names.length > 20001) { throw new KnowledgeFailure('CleanupPartBudget','pdf-assets'); }
        for (const name of names) {
          if (!new RegExp('^(manifest|part-[0-9]+-[0-9]+|part)$').test(name)) { throw new KnowledgeFailure('UnregisteredCleanupPart','pdf-assets'); }
          const path: string = `${directory}/${name}`; const part: fileIo.Stat = await fileIo.lstat(path); if (!part.isFile() || part.isSymbolicLink()) { throw new KnowledgeFailure('CleanupPartUnsafe','pdf-assets'); } await fileIo.unlink(path);
        }
        await fileIo.rmdir(directory);
      }
    }
  }
  // Exclusive directory ownership makes CREATE inside it non-overwriting. No
  // arbitrary member name is ever accepted as a destination.
  async writeOwnedPart(id: string, generation: string, bytes: Uint8Array, cancel: KnowledgeCancellation): Promise<string> {
    this.safeId(id); if (bytes.length > PdfBudget.rowBytes) { throw new KnowledgeFailure('PartBudget','pdf-assets'); }
    await this.ledger.reserveAsset(id,generation,bytes.length); cancel.check();
    await documentEnsureDirectory(this.cacheRoot); const directory: string = `${this.cacheRoot}/${id}`;
    await fileIo.mkdir(directory); const stat: fileIo.Stat = await fileIo.lstat(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new KnowledgeFailure('ExclusiveDirectoryInvalid','pdf-assets'); }
    const file: fileIo.File = await fileIo.open(`${directory}/part`,fileIo.OpenMode.CREATE|fileIo.OpenMode.READ_WRITE|fileIo.OpenMode.NOFOLLOW);
    try {
      let offset: number = 0;
      while (offset < bytes.length) {
        cancel.check(); const block: Uint8Array = bytes.slice(offset,Math.min(bytes.length,offset+65536));
        const options: WriteOptions = { offset: offset, length: block.length }; const written: number = await fileIo.write(file.fd,block.buffer,options);
        if (written < 1 || written > block.length) { throw new KnowledgeFailure('PartWriteIncomplete','pdf-assets'); } offset += written;
      }
      await fileIo.fsync(file.fd); const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      for (let at: number = 0; at < bytes.length; at += 65536) {
        cancel.check(); const buffer: ArrayBuffer = new ArrayBuffer(Math.min(65536,bytes.length-at)); const options: ReadOptions = { offset: at, length: buffer.byteLength };
        if (await fileIo.read(file.fd,buffer,options) !== buffer.byteLength) { throw new KnowledgeFailure('PartReadbackIncomplete','pdf-assets'); }
        const blob: cryptoFramework.DataBlob = { data: new Uint8Array(buffer) }; await digest.update(blob);
      }
      const hash: string = documentDigestHex((await digest.digest()).data); await this.ledger.commitAsset(id,hash,bytes.length,'PDF-NORMALIZED-1:PartStaged'); return hash;
    } finally { await fileIo.close(file); }
  }
}
