import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { KnowledgeStoreHost } from '../infra/KnowledgeStoreHost';
import { TextRdbRepository } from '../infra/TextRdbRepository';
import { PdfKnowledgeRepository } from '../infra/PdfKnowledgeRepository';
import { PdfAssetAdapter } from '../infra/PdfAssetAdapter';
import { KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';
import { PdfProcessingAdapter } from '../infra/PdfProcessingAdapter';
import { PdfArchivePort } from '../domain/KnowledgePorts';
import { PdfNativeCaseResult, PdfNativeSuiteResult } from './PdfNativeSuite';
import { PdfSourceBinding, PdfZipManifest, PdfZipMember, KnowledgeCancellation, KnowledgeFailure, PdfKnowledgeDocument, PdfIngestionJob, KnowledgePin, PdfStage, PdfContentNode, PdfNodeKind, PdfNormalizedDocument, PdfChunk, PdfPartialApproval, KnowledgeReadLease, KnowledgeCleanupIntent } from '../domain/PdfKnowledgeModels';
import { BoundedDocumentJson } from '../pipeline/BoundedDocumentJson';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { pdfWorkerCancellationCase } from './PdfWorkerCases';
import { pdfMappingFixtureCase } from './PdfMappingCases';
import { PdfEvidenceContext } from '../domain/PdfLocalModels';
import { KnowledgeSearchService } from '../application/KnowledgeSearchService';
import { KnowledgeHistoryCursor } from '../domain/KnowledgeSearchModels';
import { PdfIngestionService } from '../application/PdfIngestionService';
import { KnowledgeLifecycleService } from '../application/KnowledgeLifecycleService';
import { PdfDerivedImage } from '../domain/PdfKnowledgeModels';
import { prepareTextQuery } from '../pipeline/QueryPreparation';

class KnowledgeFixtureArchive implements PdfArchivePort {
  payloads: Uint8Array[] = []; manifest: PdfZipManifest = new PdfZipManifest();
  failOnce: boolean = false; inspections: number = 0;
  capability(): string { return 'TestFixture'; }
  async inspect(_binding: PdfSourceBinding, _cancel: KnowledgeCancellation): Promise<PdfZipManifest> { this.inspections++; if (this.failOnce) { this.failOnce = false; throw new KnowledgeFailure('InjectedArchiveReadFailure','test'); } return this.manifest; }
  async readMember(_manifest: PdfZipManifest, member: PdfZipMember, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    cancel.check(); const at: number = this.manifest.members.indexOf(member); if (at < 0) { throw new KnowledgeFailure('FixtureMissing','suite'); } return this.payloads[at];
  }
  async release(): Promise<void> {}
}
function knowledgeFixture(binding: PdfSourceBinding): KnowledgeFixtureArchive {
  const archive: KnowledgeFixtureArchive = new KnowledgeFixtureArchive(); archive.manifest.hardPassed = true; archive.manifest.zipHash = binding.zipHash;
  const jsons: string[] = ['[{"bbox":[1,2,90,30],"page_idx":0}]','{"_version_name":"3.4.4","_backend":"hybrid","_effort":"medium","_ocr_enable":true,"pdf_info":[{"page_idx":0}]}','[[{"bbox":[1,2,90,30],"type":"paragraph","content":{"paragraph_content":[{"type":"text","content":"fixture evidence"}]}}]]'];
  const names: string[] = ['fixture_content_list.json','layout.json','fixture_content_list_v2.json'];
  for (let at: number = 0; at < 3; at++) { const member: PdfZipMember = new PdfZipMember(); member.id = `fixture-${at}`; member.logicalName = names[at]; member.verified = true; member.actualCrc32 = 0; member.crc32 = 0; member.sha256 = 'c'.repeat(64); archive.manifest.members.push(member); archive.payloads.push(pdfCodecUtf8(jsons[at])); }
  return archive;
}
async function knowledgeLocalScalar(store: relationalStore.RdbStore, sql: string): Promise<string> {
  const rows: relationalStore.ResultSet = await store.querySql(sql); try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('TestRowMissing','suite'); } return rows.getString(0); } finally { rows.close(); }
}
function knowledgeAssert(condition: boolean, reason: string): void { if (!condition) { throw new KnowledgeFailure(reason,'suite'); } }
export async function knowledgeRunLocalSuite(context: common.Context, scope: KnowledgeStorageScope): Promise<PdfNativeSuiteResult> {
  scope.requireTestOwner(scope.key);
  const result: PdfNativeSuiteResult = new PdfNativeSuiteResult(); result.run = scope.key; result.version = 'R2-LOCAL-1';
  const host: KnowledgeStoreHost = KnowledgeStoreHost.forContext(context,scope); const text: TextRdbRepository = new TextRdbRepository(context,host);
  let pdf: PdfKnowledgeRepository = new PdfKnowledgeRepository(host); const identity: KnowledgePlatformIdentity = new KnowledgePlatformIdentity();
  const document: PdfKnowledgeDocument = new PdfKnowledgeDocument(); const job: PdfIngestionJob = new PdfIngestionJob();
  document.id = identity.id(); document.sourceKey = `fixture-${scope.key}`; document.binding.originalId = 'fixture-source'; document.binding.originalAssetId = 'original-fixture';
  document.binding.originalHash = 'a'.repeat(64); document.binding.originalVersion = 1; document.binding.originalBytes = 128; document.binding.originalPages = 1;
  document.binding.resultAssetId = 'result-fixture'; document.binding.zipHash = 'b'.repeat(64); document.binding.zipBytes = 128;
  job.id = identity.id(); job.generation = identity.id(); job.documentId = document.id; job.sourceId = document.binding.originalId; job.binding = document.binding; job.processingKey = `fixture-${scope.key}|${document.binding.zipHash}`; job.ownerSession = scope.key;
  const pins: KnowledgePin[] = [];
  for (let at: number = 0; at < 2; at++) { const pin: KnowledgePin = new KnowledgePin(); pin.id = identity.id(); pin.sourceId = job.sourceId; pin.assetId = at === 0 ? document.binding.originalAssetId : document.binding.resultAssetId; pin.assetHash = at === 0 ? document.binding.originalHash : document.binding.zipHash; pin.ownerId = job.id; pin.documentId = document.id; pin.generation = job.generation; pins.push(pin); }
  let assets: PdfAssetAdapter = new PdfAssetAdapter(context.filesDir,context.cacheDir,pdf,scope);
  let snapshot: PdfNormalizedDocument = new PdfNormalizedDocument();
  try {
    for (const name of ['scope-reject','register-rollback','ext2-empty','migration-rollback','migration-reopen','utf8-boundary','worker-cancel-budget','taskpool-normalize','large-image-snapshot','legacy-image-read','image-reuse','fault-reserved','fault-part','fault-manifest','fault-renamed','fault-committed','checkpoint-rollback','mapping-crop-rotation','prepared-rollback','prepared-replay','active-protect','archive-restore','history-failure-retry','candidate-switch','abandon-claim-matrix','service-retry-resume','session-lease-reject','cleanup-owned']) {
      const row: PdfNativeCaseResult = new PdfNativeCaseResult(); row.id = name;
      try {
        if (name === 'scope-reject') {
          let rejected: boolean = false; try { KnowledgeStorageScope.production().requireTestOwner(scope.key); } catch { rejected = true; }
          knowledgeAssert(rejected,'ProductionScopeAccepted'); rejected = false;
          try { KnowledgeStorageScope.isolated('../production'); } catch { rejected = true; } knowledgeAssert(rejected,'UnsafeScopeAccepted');
        } else if (name === 'register-rollback') {
          await text.open(); await pdf.open(); pdf.injectLocalFault(scope.key,'Register'); let rejected: boolean = false;
          try { await pdf.register(document,job,pins); } catch { rejected = true; } knowledgeAssert(rejected && (await pdf.jobs()).length === 0 && (await pdf.pins(job.sourceId,[])).length === 0,'RegisterRollback');
        } else if (name === 'ext2-empty') {
          await text.open(); await pdf.open(); await pdf.register(document,job,pins);
          knowledgeAssert(await knowledgeLocalScalar(host.requireStore(),"SELECT value FROM kb_meta WHERE key='layout'") === 'KB-PDF-EXT-2','NewLayout');
          knowledgeAssert((await pdf.jobs())[0].binding?.zipHash === document.binding.zipHash,'CandidateReadback');
        } else if (name === 'migration-rollback') {
          await pdf.legacyFixture(scope.key); await pdf.close(); pdf = new PdfKnowledgeRepository(host); pdf.injectMigrationFault(scope.key);
          let rejected: boolean = false; try { await pdf.open(); } catch { rejected = true; }
          knowledgeAssert(rejected && host.m1Ready,'MigrationDidNotIsolate');
          knowledgeAssert(await knowledgeLocalScalar(host.requireStore(),"SELECT value FROM kb_meta WHERE key='layout'") === 'KB-PDF-EXT-1','MigrationNotRolledBack');
          knowledgeAssert(await knowledgeLocalScalar(host.requireStore(),"SELECT count(*) FROM sqlite_master WHERE name='kb_candidate'") === '0','MigrationTablesNotRolledBack');
          knowledgeAssert((await text.list()).length === 0,'M1Changed');
        } else if (name === 'migration-reopen') {
          await pdf.open(); await pdf.close(); pdf = new PdfKnowledgeRepository(host); await pdf.open();
          assets = new PdfAssetAdapter(context.filesDir,context.cacheDir,pdf,scope);
          knowledgeAssert((await pdf.jobs()).length === 1 && host.m1Ready,'ReopenLostJob');
        } else if (name === 'utf8-boundary') {
          const raw: string = '{"x":"'+'a'.repeat(16376)+'😀中\\uD83D\\uDE00"}';
          knowledgeAssert(new BoundedDocumentJson(pdfCodecUtf8(raw),new KnowledgeCancellation()).read().required('x').string() === 'a'.repeat(16376)+'😀中😀','Utf8Boundary');
          let rejected: boolean = false; try { new BoundedDocumentJson(pdfCodecUtf8('{"a":1,"\\u0061":2}'),new KnowledgeCancellation()).read(); } catch { rejected = true; } knowledgeAssert(rejected,'DuplicateKeyAccepted');
          const cancel: KnowledgeCancellation = new KnowledgeCancellation(); cancel.invalid = true; rejected = false;
          try { new BoundedDocumentJson(pdfCodecUtf8(' '.repeat(100000)+'{}'),cancel).read(); } catch { rejected = true; } knowledgeAssert(rejected,'WhitespaceCancellation');
        } else if (name === 'worker-cancel-budget') { await pdfWorkerCancellationCase();
        } else if (name === 'taskpool-normalize') {
          const archive: KnowledgeFixtureArchive = new KnowledgeFixtureArchive(); archive.manifest.hardPassed = true; archive.manifest.zipHash = document.binding.zipHash;
          const jsons: string[] = ['[{"bbox":[1,2,90,30],"page_idx":0}]','{"_version_name":"3.4.4","_backend":"hybrid","_effort":"medium","_ocr_enable":true,"pdf_info":[{"page_idx":0}]}','[[{"bbox":[1,2,90,30],"type":"paragraph","content":{"paragraph_content":[{"type":"text","content":"fixture evidence"}]}}]]'];
          const names: string[] = ['fixture_content_list.json','layout.json','fixture_content_list_v2.json'];
          for (let at: number = 0; at < 3; at++) { const member: PdfZipMember = new PdfZipMember(); member.id = `fixture-${at}`; member.logicalName = names[at]; member.verified = true; member.actualCrc32 = 0; member.crc32 = 0; member.sha256 = 'c'.repeat(64); archive.manifest.members.push(member); archive.payloads.push(pdfCodecUtf8(jsons[at])); }
          snapshot = await new PdfProcessingAdapter().normalize(document.binding,archive.manifest,archive,new KnowledgeCancellation());
          snapshot.id = identity.id(); snapshot.documentId = document.id; snapshot.generation = job.generation;
          knowledgeAssert(snapshot.nodes.length === 1 && snapshot.nodes[0].text === 'fixture evidence','WorkerNormalization');
          const chunks: PdfChunk[] = await new PdfProcessingAdapter().chunks(snapshot,job.generation,new KnowledgeCancellation()); knowledgeAssert(chunks.length === 1,'WorkerChunk');
        } else if (name === 'large-image-snapshot') {
          const pixels: ArrayBuffer = new ArrayBuffer(1024*1024*4); const data: Uint8Array = new Uint8Array(pixels); let seed: number = 17;
          for (let at: number = 0; at < data.length; at++) { seed = (Math.imul(seed,1664525)+1013904223)>>>0; data[at] = at%4 === 3 ? 255 : seed>>>24; }
          const size: image.Size = { width: 1024,height: 1024 }; const init: image.InitializationOptions = { size: size,pixelFormat: image.PixelMapFormat.RGBA_8888,editable: false };
          const pixel: image.PixelMap = await image.createPixelMapFromPixels(pixels,init); const packer: image.ImagePacker = image.createImagePacker(); let bytes: Uint8Array;
          try { const options: image.PackingOption = { format: 'image/jpeg',quality: 100 }; bytes = new Uint8Array(await packer.packToData(pixel,options)); } finally { try { await packer.release(); } finally { await pixel.release(); } }
          knowledgeAssert(bytes.length > 1048576,'LargeImageFixtureTooSmall'); row.input = bytes.length;
          const archive: KnowledgeFixtureArchive = new KnowledgeFixtureArchive(); archive.manifest = snapshot.manifest;
          const member: PdfZipMember = new PdfZipMember(); member.id = 'fixture-image'; member.logicalName = 'fixture.jpg'; member.verified = true; member.sha256 = await identity.hash(bytes); member.actualBytes = bytes.length; member.declaredBytes = bytes.length; member.crc32 = 0; member.actualCrc32 = 0;
          archive.manifest.members = [member]; archive.payloads = [bytes]; snapshot.manifest = archive.manifest; snapshot.nodes[0].assetIds = [member.id];
          await assets.saveImages(snapshot,archive,new KnowledgeCancellation()); knowledgeAssert(snapshot.images.length === 1,'ImageNotDecoded');
          snapshot.hash = 'd'.repeat(64); snapshot.coverage.snapshotHash = snapshot.hash; snapshot.coverage.hash = 'e'.repeat(64);
          await assets.save(snapshot,new KnowledgeCancellation()); const read: PdfNormalizedDocument = await assets.read(snapshot.id,new KnowledgeCancellation());
          knowledgeAssert(read.nodes[0].text === snapshot.nodes[0].text && read.images[0].sha256 === member.sha256,'SnapshotImageReadback'); row.output = read.images[0].bytes;
          job.snapshotId = snapshot.id; job.snapshotHash = snapshot.hash; job.reportHash = snapshot.coverage.hash; job.stage = PdfStage.Review; job.checkpoint = PdfStage.Review; await pdf.checkpoint(job);
        } else if (name === 'image-reuse') {
          const archive: KnowledgeFixtureArchive = new KnowledgeFixtureArchive(); archive.manifest = snapshot.manifest;
          const before: number = (await pdf.assetIds()).length; await assets.saveImages(snapshot,archive,new KnowledgeCancellation()); knowledgeAssert((await pdf.assetIds()).length === before && snapshot.images.length === 1,'ImageReuseDuplicated');
        } else if (name === 'legacy-image-read') {
          const bytes: Uint8Array = await assets.readImage(snapshot.images[0],job.generation,new KnowledgeCancellation()); const id: string = identity.id(); const hash: string = await assets.legacyImageFixture(scope.key,id,job.generation,bytes,new KnowledgeCancellation());
          const legacy: PdfDerivedImage = new PdfDerivedImage(); legacy.id = id; legacy.sha256 = hash; legacy.bytes = bytes.length;
          knowledgeAssert((await assets.readImage(legacy,job.generation,new KnowledgeCancellation())).length === bytes.length,'LegacyImageReadback'); await assets.reconcile();
        } else if (name.startsWith('fault-')) {
          const old: string = snapshot.id; snapshot.id = identity.id(); const stage: string = name === 'fault-manifest' ? 'Manifest' : name === 'fault-renamed' ? 'Renamed' : name === 'fault-committed' ? 'Committed' : name === 'fault-reserved' ? 'Reserved' : 'Part'; assets.injectFault(scope.key,stage);
          let rejected: boolean = false; try { await assets.save(snapshot,new KnowledgeCancellation()); } catch (error) { rejected = error instanceof KnowledgeFailure && error.category.startsWith('Injected'); }
          knowledgeAssert(rejected,'FaultNotObserved'); assets = new PdfAssetAdapter(context.filesDir,context.cacheDir,pdf,scope); await assets.reconcile();
          if (stage === 'Reserved' || stage === 'Part') { let rejected: boolean = false; try { await assets.read(snapshot.id,new KnowledgeCancellation()); } catch { rejected = true; } knowledgeAssert(rejected,'IncompleteSnapshotAccepted'); }
          else { const read: PdfNormalizedDocument = await assets.read(snapshot.id,new KnowledgeCancellation()); knowledgeAssert(read.nodes.length === snapshot.nodes.length,'RecoveredSnapshot'); } snapshot.id = old;
        } else if (name === 'checkpoint-rollback') {
          pdf.injectLocalFault(scope.key,'Checkpoint'); let rejected: boolean = false; try { await pdf.checkpoint(job); } catch { rejected = true; } knowledgeAssert(rejected,'CheckpointFaultMissing');
          knowledgeAssert((await pdf.generationJob(job.generation)).snapshotId === snapshot.id,'CheckpointRollback');
        } else if (name === 'mapping-crop-rotation') {
          const proof: PdfEvidenceContext = new PdfEvidenceContext(); proof.originalHash = document.binding.originalHash; proof.originalVersion = 1; proof.zipHash = document.binding.zipHash; proof.snapshotHash = snapshot.hash; proof.snapshotId = snapshot.id; proof.generation = job.generation; proof.nodeId = snapshot.nodes[0].id; proof.protocol = snapshot.profile;
          await pdfMappingFixtureCase(context,scope,pdf,proof);
        } else if (name === 'prepared-rollback') {
          const chunks: PdfChunk[] = await new PdfProcessingAdapter().chunks(snapshot,job.generation,new KnowledgeCancellation()); const approval: PdfPartialApproval = new PdfPartialApproval(); approval.reportHash = job.reportHash; approval.snapshotHash = job.snapshotHash; approval.confirmedAt = Date.now();
          pdf.injectLocalFault(scope.key,'Prepare'); let rejected: boolean = false; try { await pdf.prepare(document,job,chunks,approval); } catch { rejected = true; } knowledgeAssert(rejected && (await pdf.localCounts(job.generation))[0] === 0,'PrepareRollback');
        } else if (name === 'prepared-replay') {
          const chunks: PdfChunk[] = await new PdfProcessingAdapter().chunks(snapshot,job.generation,new KnowledgeCancellation());
          const approval: PdfPartialApproval = new PdfPartialApproval(); approval.reportHash = job.reportHash; approval.snapshotHash = job.snapshotHash; approval.confirmedAt = Date.now();
          await pdf.prepare(document,job,chunks,approval); await pdf.prepare(document,job,chunks,approval);
          await pdf.resumeJob(job.id);
          pdf.injectLocalFault(scope.key,'Publish'); let rejected: boolean = false; try { await pdf.publish(document,job,approval); } catch { rejected = true; }
          knowledgeAssert(rejected && (await pdf.get(document.id))?.activeContentGeneration === '','PublishRollback');
          pdf.injectLocalFault(scope.key,'PublishAck'); rejected = false; try { await pdf.publish(document,job,approval); } catch { rejected = true; }
          knowledgeAssert(rejected && (await pdf.get(document.id))?.activeContentGeneration === job.generation,'PublishAckUncertain');
          knowledgeAssert(await pdf.publish(document,job,approval),'PublishReplayFailed');
        } else if (name === 'active-protect') {
          let rejected: boolean = false; try { await pdf.checkpoint(job); } catch { rejected = true; } knowledgeAssert(rejected,'ActiveCheckpointAllowed');
          knowledgeAssert((await pdf.resumeJob(job.id)).stage === PdfStage.Published,'ActiveReplay');
        } else if (name === 'archive-restore') {
          await pdf.archive(document.id,true); knowledgeAssert((await pdf.candidates(prepareTextQuery('fixture'),false,false,new KnowledgeCancellation())).length === 0,'ArchivedVisibleByDefault');
          knowledgeAssert((await pdf.candidates(prepareTextQuery('fixture'),true,false,new KnowledgeCancellation())).length === 1,'IncludeArchivedMissing');
          await pdf.archive(document.id,false); document.epoch = (await pdf.get(document.id))?.epoch ?? 0; job.epoch = document.epoch;
          knowledgeAssert((await pdf.candidates(prepareTextQuery('fixture'),false,false,new KnowledgeCancellation())).length === 1,'RestoredKeywordMissing');
        } else if (name === 'history-failure-retry') {
          const search: KnowledgeSearchService = new KnowledgeSearchService(text,pdf,identity); search.state.question = 'fixture'; pdf.injectLocalFault(scope.key,'History'); await search.search();
          knowledgeAssert(search.state.result.hits.length === 1 && search.state.historyPending,'HistoryFailureLostResults'); await search.retryHistory(); await search.retryHistory();
          knowledgeAssert(!search.state.historyPending && (await pdf.history(new KnowledgeHistoryCursor(),20)).records.length === 1,'HistoryRetryDuplicated');
        } else if (name === 'candidate-switch' || name === 'abandon-claim-matrix') {
          const next: PdfIngestionJob = new PdfIngestionJob(); next.id = identity.id(); next.generation = identity.id(); next.sourceId = job.sourceId; next.documentId = document.id; next.epoch = document.epoch; next.processingKey = `${scope.key}|${next.id}`; next.ownerSession = scope.key; next.attempt = 2; next.expectedOldGeneration = (await pdf.get(document.id))?.activeContentGeneration ?? '';
          const binding: PdfSourceBinding = new PdfSourceBinding(); binding.originalId = document.binding.originalId; binding.originalHash = document.binding.originalHash; binding.originalAssetId = document.binding.originalAssetId; binding.originalVersion = 1; binding.originalPages = 1; binding.originalBytes = 128; binding.resultAssetId = 'result-fixture-next'; binding.zipHash = '9'.repeat(64); binding.zipBytes = 129; next.binding = binding;
          const nextPins: KnowledgePin[] = [];
          for (let at: number = 0; at < 2; at++) { const pin: KnowledgePin = new KnowledgePin(); pin.id = identity.id(); pin.sourceId = next.sourceId; pin.assetId = at === 0 ? binding.originalAssetId : binding.resultAssetId; pin.assetHash = at === 0 ? binding.originalHash : binding.zipHash; pin.ownerId = next.id; pin.documentId = document.id; pin.generation = next.generation; nextPins.push(pin); }
          await pdf.register(document,next,nextPins);
          if (name === 'abandon-claim-matrix') {
            await pdf.abandon(next.id); const intent: KnowledgeCleanupIntent | undefined = (await pdf.cleanups()).find((item: KnowledgeCleanupIntent): boolean => item.generation === next.generation); knowledgeAssert(intent !== undefined,'AbandonIntentMissing');
            if (intent !== undefined) { const claim: KnowledgeCleanupIntent | undefined = await pdf.claimCleanup(intent.id); knowledgeAssert(claim !== undefined,'ClaimMissing'); if (claim !== undefined) {
              let rejected: boolean = false; const lease: KnowledgeReadLease = new KnowledgeReadLease(); lease.id = identity.id(); lease.sourceId = next.sourceId; lease.generation = next.generation; lease.sessionId = scope.key;
              try { await pdf.acquireRead(lease); } catch { rejected = true; } knowledgeAssert(rejected,'ClaimDidNotBlockReader');
              rejected = false; try { await pdf.resumeJob(next.id); } catch { rejected = true; } knowledgeAssert(rejected,'AbandonedJobResumed');
              await pdf.finishCleanup(claim,'InjectedCleanupFailure'); const reopened: PdfKnowledgeRepository = new PdfKnowledgeRepository(host); await reopened.open(); const retry: KnowledgeCleanupIntent | undefined = await reopened.claimCleanup(intent.id); knowledgeAssert(retry?.claim === claim.claim,'CleanupClaimLostOnReopen'); await reopened.close(); await assets.remove(claim); await pdf.finishCleanup(claim,'');
            } }
          } else {
            next.snapshotId = identity.id(); next.snapshotHash = '8'.repeat(64); next.reportHash = '7'.repeat(64); next.stage = PdfStage.Review; next.checkpoint = PdfStage.Review; await pdf.checkpoint(next);
            const chunk: PdfChunk = new PdfChunk(); chunk.id = `${next.generation}-c0`; chunk.documentId = document.id; chunk.generation = next.generation; chunk.snapshotId = next.snapshotId; chunk.snapshotHash = next.snapshotHash; chunk.originalHash = binding.originalHash; chunk.originalVersion = 1; chunk.text = 'fixture replacement'; chunk.retrievalText = chunk.text;
            const approval: PdfPartialApproval = new PdfPartialApproval(); approval.reportHash = next.reportHash; approval.snapshotHash = next.snapshotHash; approval.confirmedAt = Date.now(); await pdf.prepare(document,next,[chunk],approval); await pdf.publish(document,next,approval);
            knowledgeAssert((await pdf.get(document.id))?.binding.zipHash === binding.zipHash && (await pdf.generationJob(job.generation)).binding?.zipHash === document.binding.zipHash,'CandidateBindingSwitch');
          }
        } else if (name === 'service-retry-resume') {
          const next: PdfIngestionJob = new PdfIngestionJob(); next.id = identity.id(); next.generation = identity.id(); next.documentId = document.id; next.epoch = document.epoch; next.sourceId = job.sourceId; next.binding = document.binding; next.processingKey = `${scope.key}|retry`; next.expectedOldGeneration = (await pdf.get(document.id))?.activeContentGeneration ?? ''; next.ownerSession = scope.key;
          const nextPins: KnowledgePin[] = [];
          for (let at: number = 0; at < 2; at++) { const pin: KnowledgePin = new KnowledgePin(); pin.id = identity.id(); pin.sourceId = next.sourceId; pin.assetId = at === 0 ? document.binding.originalAssetId : document.binding.resultAssetId; pin.assetHash = at === 0 ? document.binding.originalHash : document.binding.zipHash; pin.ownerId = next.id; pin.documentId = document.id; pin.generation = next.generation; nextPins.push(pin); }
          await pdf.register(document,next,nextPins); const archive: KnowledgeFixtureArchive = knowledgeFixture(document.binding); archive.failOnce = true;
          const service: PdfIngestionService = new PdfIngestionService(pdf,new KnowledgeLifecycleService(pdf),archive,new PdfProcessingAdapter(),assets,identity); service.attachSession(scope.key);
          await service.resume(next.id); knowledgeAssert(service.state.stage === PdfStage.Failed && (await pdf.generationJob(next.generation)).snapshotId === '','NoSnapshotFailure');
          assets.injectFault(scope.key,'Committed'); await service.resume(next.id); knowledgeAssert(service.state.stage === PdfStage.Failed && (await pdf.generationJob(next.generation)).snapshotId === '' && archive.inspections === 2,'CommitBeforeCheckpointFault');
          await service.resume(next.id); knowledgeAssert(service.state.stage === PdfStage.Review && service.state.report?.hash.length === 64 && archive.inspections === 2,'OriginalZipRetry');
          const saved: string = service.state.report?.hash ?? ''; await service.resume(next.id); knowledgeAssert(service.state.report?.hash === saved && archive.inspections === 2,'SnapshotResumeReparsed');
          await pdf.abandon(next.id);
        } else if (name === 'session-lease-reject') {
          await pdf.reconcile(scope.key); const lease: KnowledgeReadLease = new KnowledgeReadLease(); lease.id = identity.id(); lease.generation = job.generation; lease.sourceId = job.sourceId; lease.sessionId = 'foreign-session';
          let rejected: boolean = false; try { await pdf.acquireRead(lease); } catch { rejected = true; } knowledgeAssert(rejected,'ForeignSessionAccepted');
        } else if (name === 'cleanup-owned') {
          const lease: KnowledgeReadLease = new KnowledgeReadLease(); lease.id = identity.id(); lease.sourceId = job.sourceId; lease.generation = job.generation; lease.sessionId = scope.key;
          await pdf.acquireRead(lease); await pdf.deleteDocument(document.id); const intent: KnowledgeCleanupIntent | undefined = (await pdf.cleanups()).find((item: KnowledgeCleanupIntent): boolean => item.generation === job.generation);
          if (intent === undefined) { throw new KnowledgeFailure('CleanupIntentMissing','suite'); }
          knowledgeAssert(await pdf.claimCleanup(intent.id) === undefined,'CleanupBeatLease'); await pdf.releaseRead(lease.id);
          const claim: KnowledgeCleanupIntent | undefined = await pdf.claimCleanup(intent.id); knowledgeAssert(claim !== undefined,'CleanupClaimMissing');
          if (claim !== undefined) { await assets.remove(claim); await pdf.finishCleanup(claim,''); }
          for (const intent of await pdf.cleanups()) { const claim: KnowledgeCleanupIntent | undefined = await pdf.claimCleanup(intent.id); if (claim !== undefined) { await assets.remove(claim); await pdf.finishCleanup(claim,''); } } knowledgeAssert((await pdf.assetIds()).length === 0,'CleanupNotFinished');
        }
        row.passed = true; row.reason = 'ok';
      } catch (error) { const native: BusinessError = error; row.code = typeof native.code === 'number' ? native.code : 0; row.reason = error instanceof KnowledgeFailure ? error.category : 'PlatformApiRejected'; }
      result.cases.push(row);
    }
  } finally {
    await pdf.close(); await text.close();
    scope.requireTestOwner(scope.key);
    if (result.cases.every((row: PdfNativeCaseResult): boolean => row.passed)) { const config: relationalStore.StoreConfig = { name: scope.databaseName,securityLevel: relationalStore.SecurityLevel.S3,vector: false }; await relationalStore.deleteRdbStore(context,config); }
  }
  return result;
}
