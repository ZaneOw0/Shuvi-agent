import { fileIo, ReadOptions } from '@kit.CoreFileKit';
import { PdfNormalizedDocument, PdfCoverageReport, KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { pdfDecodeSnapshotHeader, pdfDecodeSnapshotNode, pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { BoundedDocumentJson } from '../pipeline/BoundedDocumentJson';
import { pdfStrictUtf8 } from '../pipeline/SafeZipPolicy';

export class PdfLegacySnapshotFiles {
  private root: string; private identity: KnowledgeIdentityPort;
  constructor(root: string, identity: KnowledgeIdentityPort) { this.root=root; this.identity=identity; }
  private async read(id: string, name: string, maximum: number, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    if (!/^kb-[a-f0-9]{32}$/.test(id) || !/^(manifest|part-[0-9]+-[0-9]+)$/.test(name)) { throw new KnowledgeFailure('SnapshotPath','legacy-read'); }
    const file: fileIo.File=await fileIo.open(`${this.root}/${id}/${name}`,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
    try { const stat: fileIo.Stat=await fileIo.stat(file.fd); if (!stat.isFile() || stat.size<1 || stat.size>maximum) { throw new KnowledgeFailure('SnapshotPartBudget','legacy-read'); }
      const bytes: Uint8Array=new Uint8Array(stat.size); let at: number=0;
      while (at<bytes.length) { cancel.check(); const block: ArrayBuffer=new ArrayBuffer(Math.min(65536,bytes.length-at)); const options: ReadOptions={offset:at,length:block.byteLength}; const n: number=await fileIo.read(file.fd,block,options); if (n<1 || n>block.byteLength) { throw new KnowledgeFailure('SnapshotTruncated','legacy-read'); } bytes.set(new Uint8Array(block,0,n),at); at+=n; } return bytes;
    } finally { await fileIo.close(file); }
  }
  async readBody(id: string, manifestHash: string, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument> {
    const manifest: Uint8Array=await this.read(id,'manifest',1048576,cancel); if (await this.identity.hash(manifest)!==manifestHash) { throw new KnowledgeFailure('ManifestHashMismatch','legacy-read'); }
    const fields: string[]=pdfStrictUtf8(manifest).split('\n');
    if (fields.length!==5 || fields[0]!=='PDF-NORMALIZED-1' || fields[1]!==id) { throw new KnowledgeFailure('SnapshotManifest','legacy-read'); }
    const count: number=Number(fields[2]); const groups: string[]=fields[3].split(';'); const hashes: string[]=fields[4].split(',');
    if (!Number.isSafeInteger(count) || count<0 || count>20000 || groups.length!==count+1 || hashes.length>20000) { throw new KnowledgeFailure('SnapshotManifestCount','legacy-read'); }
    let total: number=0; let hashAt: number=0; let snapshot: PdfNormalizedDocument | undefined;
    for (let g: number=0;g<groups.length;g++) {
      const names: string[]=groups[g].split(','); if (names.length>128) { throw new KnowledgeFailure('SnapshotGroupBudget','legacy-read'); }
      const blocks: Uint8Array[]=[]; let size: number=0;
      for (let p: number=0;p<names.length;p++) { if (names[p]!==`part-${g}-${p}`) { throw new KnowledgeFailure('SnapshotPartOrder','legacy-read'); }
        const bytes: Uint8Array=await this.read(id,names[p],65536,cancel); if (await this.identity.hash(bytes)!==hashes[hashAt++]) { throw new KnowledgeFailure('SnapshotPartHash','legacy-read'); } size+=bytes.length; total+=bytes.length; if (size>8388608 || total>104857600) { throw new KnowledgeFailure('SnapshotExpandedBudget','legacy-read'); } blocks.push(bytes);
      }
      const raw: Uint8Array=new Uint8Array(size); let at: number=0; for (const bytes of blocks) { raw.set(bytes,at); at+=bytes.length; }
      if (g===0) { snapshot=pdfDecodeSnapshotHeader(raw,cancel); } else { if (snapshot===undefined) { throw new KnowledgeFailure('SnapshotHeaderMissing','legacy-read'); } snapshot.nodes.push(pdfDecodeSnapshotNode(new BoundedDocumentJson(raw,cancel).read())); }
    }
    if (snapshot===undefined || snapshot.id!==id || snapshot.nodes.length!==count || hashAt!==hashes.length) { throw new KnowledgeFailure('SnapshotIdentity','legacy-read'); }
    const nodes: string[]=[]; for (const node of snapshot.nodes) { nodes.push(await this.identity.hash(pdfCodecUtf8(JSON.stringify(node)))); }
    const hash: string=await this.identity.hash(pdfCodecUtf8([snapshot.binding.originalHash,snapshot.binding.zipHash,snapshot.profile,snapshot.normalizationVersion,snapshot.filterVersion,nodes.join('|')].join('\n')));
    const report: PdfCoverageReport=new PdfCoverageReport(); report.id=snapshot.coverage.id; report.snapshotHash=snapshot.coverage.snapshotHash; report.hardPassed=snapshot.coverage.hardPassed; report.validatedNodes=snapshot.coverage.validatedNodes; report.excludedNodes=snapshot.coverage.excludedNodes; report.unresolvedNodes=snapshot.coverage.unresolvedNodes; report.issues=snapshot.coverage.issues; report.unknownPages=snapshot.coverage.unknownPages; report.filterVersion=snapshot.coverage.filterVersion;
    if (hash!==snapshot.hash || snapshot.coverage.snapshotHash!==hash || await this.identity.hash(pdfCodecUtf8(JSON.stringify(report)))!==snapshot.coverage.hash) { throw new KnowledgeFailure('SnapshotLegacyDigest','legacy-read'); }
    return snapshot;
  }
}
