import { KnowledgeCancellation, KnowledgeFailure, PdfContentNode, PdfBudget, PdfNormalizedDocument, PdfCoverageReport } from '../domain/PdfKnowledgeModels';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { PdfWorkerCancellation } from './PdfWorkerSupport';
import { pdfCodecUtf8, pdfDecodeSnapshotHeader, pdfDecodeSnapshotNode } from '../pipeline/PdfSnapshotCodec';
import { BoundedDocumentJson } from '../pipeline/BoundedDocumentJson';
import { BusinessError } from '@kit.BasicServicesKit';
import { PdfWorkerResult } from '../domain/PdfWorkerModels';
import { pdfWorkerSuccess, pdfWorkerCaught, pdfWorkerSnapshotParts } from '../pipeline/PdfWorkerPolicy';

@Concurrent
export function pdfEncodeNodeWorker(node: PdfContentNode, deadline: number): PdfWorkerResult {
  try {
  const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline; cancel.check();
  const bytes: Uint8Array = pdfCodecUtf8(JSON.stringify(node)); cancel.check();
  if (bytes.length > PdfBudget.jsonBytes) { throw new KnowledgeFailure('SnapshotNodeBudget','worker'); } return pdfWorkerSuccess('encode-node',[bytes]);
  } catch (error) { const system: BusinessError = error; return pdfWorkerCaught('encode-node',error,system?.code); }
}
@Concurrent
export function pdfHydrateNodeWorker(bytes: Uint8Array, deadline: number): PdfWorkerResult {
  try {
  const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline;
  const node: PdfContentNode = pdfDecodeSnapshotNode(new BoundedDocumentJson(bytes,cancel).read()); cancel.check();
  return pdfWorkerSuccess('hydrate-node',[pdfCodecUtf8(JSON.stringify(node))]);
  } catch (error) { const system: BusinessError = error; return pdfWorkerCaught('hydrate-node',error,system?.code); }
}
@Concurrent
export function pdfHydrateHeaderWorker(bytes: Uint8Array, deadline: number): PdfWorkerResult {
  try {
  const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline;
  return pdfWorkerSuccess('hydrate-header',pdfWorkerSnapshotParts(pdfDecodeSnapshotHeader(bytes,cancel),cancel));
  } catch (error) { const system: BusinessError = error; return pdfWorkerCaught('hydrate-header',error,system?.code); }
}
@Concurrent
export async function pdfVerifySnapshotWorker(snapshot: PdfNormalizedDocument, deadline: number): Promise<PdfWorkerResult> {
  try {
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
  if (reportHash !== snapshot.coverage.hash) { throw new KnowledgeFailure('CoverageContentHashMismatch','readback'); } cancel.check(); return pdfWorkerSuccess('verify',[new Uint8Array([1])]);
  } catch (error) { const system: BusinessError = error; return pdfWorkerCaught('verify',error,system?.code); }
}
@Concurrent
export async function pdfSealSnapshotWorker(snapshot: PdfNormalizedDocument, deadline: number): Promise<PdfWorkerResult> {
  try {
  const cancel: PdfWorkerCancellation = new PdfWorkerCancellation(); cancel.deadline = deadline; const hashes: string[] = [];
  for (const node of snapshot.nodes) {
    cancel.check(); const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: pdfCodecUtf8(JSON.stringify(node)) }; await md.update(blob);
    let hex: string = ''; for (const byte of (await md.digest()).data) { hex += byte.toString(16).padStart(2,'0'); } hashes.push(hex);
  }
  const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: pdfCodecUtf8([snapshot.binding.originalHash,snapshot.binding.zipHash,snapshot.profile,snapshot.normalizationVersion,snapshot.filterVersion,hashes.join('|')].join('\n')) }; await digest.update(blob);
  let hash: string = ''; for (const byte of (await digest.digest()).data) { hash += byte.toString(16).padStart(2,'0'); } snapshot.hash = hash; snapshot.coverage.snapshotHash = hash; snapshot.coverage.hash = '';
  const report: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const reportBytes: cryptoFramework.DataBlob = { data: pdfCodecUtf8(JSON.stringify(snapshot.coverage)) }; await report.update(reportBytes);
  let reportHash: string = ''; for (const byte of (await report.digest()).data) { reportHash += byte.toString(16).padStart(2,'0'); } snapshot.coverage.hash = reportHash; cancel.check(); return pdfWorkerSuccess('seal',pdfWorkerSnapshotParts(snapshot,cancel));
  } catch (error) { const system: BusinessError = error; return pdfWorkerCaught('seal',error,system?.code); }
}
