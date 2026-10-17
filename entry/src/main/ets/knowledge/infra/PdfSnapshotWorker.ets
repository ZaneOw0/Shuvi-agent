import { KnowledgeCancellation, KnowledgeFailure, PdfContentNode, PdfBudget, PdfNormalizedDocument, PdfCoverageReport } from '../domain/PdfKnowledgeModels';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { PdfWorkerCancellation } from './PdfWorkerSupport';
import { pdfCodecUtf8, pdfDecodeSnapshotHeader, pdfDecodeSnapshotNode } from '../pipeline/PdfSnapshotCodec';
import { BoundedDocumentJson } from '../pipeline/BoundedDocumentJson';

@Concurrent
export function pdfEncodeNodeWorker(node: PdfContentNode, deadline: number): Uint8Array {
  const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline; cancel.check();
  const bytes: Uint8Array = pdfCodecUtf8(JSON.stringify(node)); cancel.check();
  if (bytes.length > PdfBudget.jsonBytes) { throw new KnowledgeFailure('SnapshotNodeBudget','worker'); } return bytes;
}
@Concurrent
export function pdfHydrateNodeWorker(bytes: Uint8Array, deadline: number): PdfContentNode {
  const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline;
  return pdfDecodeSnapshotNode(new BoundedDocumentJson(bytes,cancel).read());
}
@Concurrent
export function pdfHydrateHeaderWorker(bytes: Uint8Array, deadline: number): PdfNormalizedDocument {
  const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline;
  return pdfDecodeSnapshotHeader(bytes,cancel);
}
@Concurrent
export async function pdfVerifySnapshotWorker(snapshot: PdfNormalizedDocument, deadline: number): Promise<boolean> {
  const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline; const hashes: string[] = [];
  for (const node of snapshot.nodes) {
    cancel.check(); const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: pdfCodecUtf8(JSON.stringify(node)) }; await md.update(blob);
    let hex: string = ''; for (const byte of (await md.digest()).data) { hex += byte.toString(16).padStart(2,'0'); } hashes.push(hex);
  }
  const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const content: cryptoFramework.DataBlob = { data: pdfCodecUtf8([snapshot.binding.originalHash,snapshot.binding.zipHash,snapshot.profile,snapshot.normalizationVersion,snapshot.filterVersion,hashes.join('|')].join('\n')) }; await digest.update(content);
  let hash: string = ''; for (const byte of (await digest.digest()).data) { hash += byte.toString(16).padStart(2,'0'); }
  if (hash !== snapshot.hash || snapshot.coverage.snapshotHash !== snapshot.hash) { throw new KnowledgeFailure('SnapshotContentHashMismatch','readback'); }
  const coverage: PdfCoverageReport = new PdfCoverageReport(); coverage.id = snapshot.coverage.id; coverage.snapshotHash = snapshot.coverage.snapshotHash; coverage.hardPassed = snapshot.coverage.hardPassed;
  coverage.validatedNodes = snapshot.coverage.validatedNodes; coverage.excludedNodes = snapshot.coverage.excludedNodes; coverage.unresolvedNodes = snapshot.coverage.unresolvedNodes; coverage.issues = snapshot.coverage.issues; coverage.unknownPages = snapshot.coverage.unknownPages; coverage.filterVersion = snapshot.coverage.filterVersion;
  const report: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const reportBytes: cryptoFramework.DataBlob = { data: pdfCodecUtf8(JSON.stringify(coverage)) }; await report.update(reportBytes);
  let reportHash: string = ''; for (const byte of (await report.digest()).data) { reportHash += byte.toString(16).padStart(2,'0'); }
  if (reportHash !== snapshot.coverage.hash) { throw new KnowledgeFailure('CoverageContentHashMismatch','readback'); } cancel.check(); return true;
}
@Concurrent
export async function pdfSealSnapshotWorker(snapshot: PdfNormalizedDocument, deadline: number): Promise<PdfNormalizedDocument> {
  const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline; const hashes: string[] = [];
  for (const node of snapshot.nodes) {
    cancel.check(); const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: pdfCodecUtf8(JSON.stringify(node)) }; await md.update(blob);
    let hex: string = ''; for (const byte of (await md.digest()).data) { hex += byte.toString(16).padStart(2,'0'); } hashes.push(hex);
  }
  const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: pdfCodecUtf8([snapshot.binding.originalHash,snapshot.binding.zipHash,snapshot.profile,snapshot.normalizationVersion,snapshot.filterVersion,hashes.join('|')].join('\n')) }; await digest.update(blob);
  let hash: string = ''; for (const byte of (await digest.digest()).data) { hash += byte.toString(16).padStart(2,'0'); } snapshot.hash = hash; snapshot.coverage.snapshotHash = hash; snapshot.coverage.hash = '';
  const report: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const reportBytes: cryptoFramework.DataBlob = { data: pdfCodecUtf8(JSON.stringify(snapshot.coverage)) }; await report.update(reportBytes);
  let reportHash: string = ''; for (const byte of (await report.digest()).data) { reportHash += byte.toString(16).padStart(2,'0'); } snapshot.coverage.hash = reportHash; cancel.check(); return snapshot;
}
