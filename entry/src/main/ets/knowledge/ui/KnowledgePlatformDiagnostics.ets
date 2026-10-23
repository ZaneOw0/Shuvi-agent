import { hilog } from '@kit.PerformanceAnalysisKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { pdfRunNativeSuite, PdfNativeSuiteResult, PdfNativeCaseResult } from '../platformtests/PdfNativeSuite';
import { knowledgeRunLocalSuite } from '../platformtests/KnowledgeLocalSuite';
import { knowledgePublicAudit, KnowledgePublicAuditResult } from '../infra/KnowledgePublicAudit';
import { KnowledgeCapabilityService } from '../infra/KnowledgeCapabilityService';
import { pdfAuditPublishedSnapshot } from '../infra/PdfLocalAudit';
import { PdfLocalMetadata } from '../domain/PdfLocalModels';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { knowledgeCleanupOwnedFailures } from '../platformtests/KnowledgeOwnedCleanup';
import { knowledgeRunVectorSuite } from '../platformtests/VectorPlatformSuite';
import { knowledgeRunEmbeddingSuite } from '../platformtests/EmbeddingIntegrationSuite';
import { vectorCleanupOwnedFailures } from '../platformtests/VectorOwnedCleanup';
import { KnowledgeAssembly } from '../infra/KnowledgeAssembly';
import { knowledgeVectorRestartCase } from '../platformtests/VectorRestartSuite';
import { embeddingRunBasisSuite } from '../platformtests/EmbeddingBasisSuite';
import { EmbeddingDryReview } from '../domain/EmbeddingBasisModels';
import { EmbeddingSafetySmoke } from './EmbeddingSafetySmoke';
import { semanticQualityContract, semanticQualityRun, semanticQualityReadback, SemanticQualitySession } from '../platformtests/SemanticQualitySuite';
import { embeddingFullAudit } from '../infra/EmbeddingFullAudit';
import { embeddingPublicAudit } from '../infra/EmbeddingPublicAudit';
import { EmbeddingJob } from '../domain/EmbeddingModels';
import { knowledgeRunCloseoutSuite } from '../platformtests/CloseoutSuite';
import { CloseoutSourceFixture } from '../platformtests/CloseoutSourceFixture';
import { PdfSourceView } from './PdfSourceView';
import { CloseoutQueryFixture } from '../platformtests/CloseoutQueryFixture';
import { CloseoutQueryView } from './CloseoutQueryView';
import { ResidualIngestionFixture } from '../platformtests/ResidualIngestionFixture';
import { ResidualIngestionView } from './ResidualIngestionView';
import { ResidualHistorySession, ResidualHistoryView } from './ResidualHistoryView';
import { ImageIntegrationSuite } from '../platformtests/ImageIntegrationSuite';
import { ImageIntegrationView } from './ImageIntegrationView';

@Component
export struct KnowledgePlatformDiagnostics {
  onBack: () => void = (): void => {};
  onImageHappyPath: () => void = (): void => {};
  @State running: boolean = false;
  @State summary: string = 'NotRun';
  @State results: string[] = [];
  @State smokeOpen: boolean = false;
  @State qualityConsent: boolean = false;
  @State qualityFree: boolean = false;
  @State qualityReviewed: boolean = false;
  @State sourceFixture: CloseoutSourceFixture | undefined = undefined;
  @State queryFixture: CloseoutQueryFixture | undefined = undefined;
  @State ingestionFixture: ResidualIngestionFixture | undefined = undefined;
  @State historyFixture: ResidualHistorySession | undefined = undefined;
  @State imageFixture: ImageIntegrationSuite | undefined = undefined;
  private async openImageFixture(caseId: string): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true;
    try { const scope = KnowledgeStorageScope.isolated(Date.now().toString(16).padStart(16,'0')); const fixture = new ImageIntegrationSuite(context,scope,caseId); await fixture.prepare(); this.imageFixture = fixture; }
    catch { this.summary = 'ImageFixturePrepareFailed; no real requests'; } finally { this.running = false; }
  }
  private async closeImageFixture(): Promise<void> { const fixture = this.imageFixture; if (fixture === undefined) { return; } try { await fixture.close(); this.imageFixture = undefined; } catch { this.summary = 'ImageFixtureReleasePending'; } }
  private async residual(kind: string): Promise<void> { const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true; try { const scope = KnowledgeStorageScope.isolated(Date.now().toString(16).padStart(16,'0')); if (kind === 'history') { const fixture = new ResidualHistorySession(context,scope); await fixture.open(); this.historyFixture = fixture; } else { const fixture = new ResidualIngestionFixture(context,scope); await fixture.prepare(); this.ingestionFixture = fixture; } } catch { this.summary = 'ResidualFixtureFailed'; } finally { this.running = false; } }
  private async closeResidual(): Promise<void> { await this.ingestionFixture?.close(); await this.historyFixture?.close(); this.ingestionFixture = undefined; this.historyFixture = undefined; }
  private async openQueryFixture(): Promise<void> { const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true; try { const fixture = new CloseoutQueryFixture(context,KnowledgeStorageScope.isolated(Date.now().toString(16).padStart(16,'0'))); await fixture.prepare(); this.queryFixture = fixture; } catch { this.summary = 'QueryFixtureFailed'; } finally { this.running = false; } }
  private async closeQueryFixture(): Promise<void> { const fixture = this.queryFixture; if (fixture !== undefined) { await fixture.close(); this.queryFixture = undefined; } }
  private async closeout(source: boolean = false): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true;
    const scope = KnowledgeStorageScope.isolated(Date.now().toString(16).padStart(16,'0'));
    try { if (source) { const fixture = new CloseoutSourceFixture(context,scope); await fixture.prepare(); this.sourceFixture = fixture; }
      else { const suite = await knowledgeRunCloseoutSuite(context,scope); for (const row of suite.cases) { hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2 run=${suite.run} suite=${suite.version} case=${row.id} pass=${row.passed ? 1 : 0} reason=${row.reason} code=${row.code} in=0 out=0 calls=${row.calls} residual=0 end=0`); } this.summary = `${suite.cases.filter((row: PdfNativeCaseResult): boolean => row.passed).length}/${suite.cases.length}`; }
    } catch { this.summary = 'CloseoutFailed'; } finally { this.running = false; }
  }
  private async closeFixture(): Promise<void> { const fixture = this.sourceFixture; if (fixture !== undefined) { await fixture.close(); this.sourceFixture = undefined; } }
  aboutToDisappear(): void { SemanticQualitySession.background(); }
  private async quality(mode: string): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true; this.summary = 'QualityRunning';
    try { this.summary = mode === 'contract' ? await semanticQualityContract(context) : mode === 'readback' ? await semanticQualityReadback(context) : await semanticQualityRun(context,this.qualityConsent,this.qualityFree); if (mode === 'contract') { this.qualityReviewed = this.summary === 'QualityContractPASS'; } }
    catch (error) { this.summary = error instanceof KnowledgeFailure ? error.category : 'QualityLocalFailure'; }
    finally { this.running = false; }
  }
  private async productionVectorAudit(): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true; this.summary = 'ReadingProductionVectors'; const assembly = KnowledgeAssembly.forContext(context);
    try { await assembly.acquire(); await embeddingPublicAudit(context); await embeddingFullAudit(assembly,context); const rows = await assembly.host.requireStore().querySql('SELECT (SELECT count(*) FROM kb_read_lease),(SELECT count(*) FROM r2s_source_release),(SELECT count(*) FROM r2v_release)'); try { rows.goToNextRow(); hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_CLOSEOUT_RELEASE leases=${rows.getLong(0)} source_pending=${rows.getLong(1)} vector_pending=${rows.getLong(2)}`); if (rows.getLong(0) !== 0 || rows.getLong(1) !== 0 || rows.getLong(2) !== 0) { throw new KnowledgeFailure('ReleaseAuditUnconfirmed','audit'); } } finally { rows.close(); } this.summary = 'ProductionVectorAuditPASS'; }
    catch (error) { this.summary = error instanceof KnowledgeFailure ? error.category : 'ProductionVectorAuditFailed'; }
    finally { await assembly.release(); this.running = false; }
  }
  private async execute(local: boolean = false, vector: boolean = false, embedding: boolean = false, basis: boolean = false): Promise<void> {
    if (this.running) { return; } this.running = true; this.results = []; this.summary = 'Running';
    const scope: KnowledgeStorageScope = KnowledgeStorageScope.isolated(Date.now().toString(16).padStart(16,'0'));
    const lines: string[] = [];
    try {
      const context = this.getUIContext().getHostContext();
      if (local && context === undefined) { this.summary = 'ContextMissing'; return; }
      const suite: PdfNativeSuiteResult = basis && context !== undefined ? await embeddingRunBasisSuite(context,scope) : embedding && context !== undefined ? await knowledgeRunEmbeddingSuite(context,scope) : vector && context !== undefined ? await knowledgeRunVectorSuite(context,scope) : local && context !== undefined ? await knowledgeRunLocalSuite(context,scope) : await pdfRunNativeSuite(scope);
      for (const row of suite.cases) {
        const line: string = `R2 run=${suite.run} suite=${suite.version} case=${row.id} pass=${row.passed ? 1 : 0} reason=${row.reason} code=${row.code} in=${row.input} out=${row.output} calls=${row.calls} residual=${row.residuals} end=${row.ends}`;
        hilog.info(0x0001,'SHUVI_R2','%{public}s',line); lines.push(line);
      }
      this.results = lines;
      this.summary = `${suite.cases.filter((row: PdfNativeCaseResult): boolean => row.passed).length}/${suite.cases.length}`;
    } finally { this.results = lines; this.running = false; }
  }
  private async audit(): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true;
    try {
      const result: KnowledgePublicAuditResult = await knowledgePublicAudit(context);
      const line: string = `R2_AUDIT m1=${result.m1} parse=${result.parse} originals=${result.originals} results=${result.results} history=${result.history} original_ok=${result.originalVerified ? 1 : 0} zip_ok=${result.zipVerified ? 1 : 0}`;
      hilog.info(0x0001,'SHUVI_R2','%{public}s',line); this.results = [line]; this.summary = result.originalVerified && result.zipVerified ? 'AuditPassed' : 'AuditFailed';
    } finally { this.running = false; }
  }
  private async capability(): Promise<void> {
    if (this.running) { return; } this.running = true;
    try { const context = this.getUIContext().getHostContext(); if (context !== undefined) { KnowledgeCapabilityService.attachContext(context); } await KnowledgeCapabilityService.requireArchive(); this.summary = KnowledgeCapabilityService.archive().state; }
    catch { this.summary = `${KnowledgeCapabilityService.archive().state}:${KnowledgeCapabilityService.archive().reason}:${KnowledgeCapabilityService.archive().code}`; }
    finally { this.running = false; }
  }
  private async pdfAudit(): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true; this.summary = 'ReadingSnapshot';
    try {
      const record: PdfLocalMetadata = await pdfAuditPublishedSnapshot(context);
      const identity: string = `R2_PDF doc=${record.document} generation=${record.generation} job=${record.job} snapshot=${record.snapshot} hash=${record.snapshotHash} report=${record.reportHash} original=${record.originalHash} zip=${record.zipHash}`;
      const counts: string = `R2_COUNTS nodes=${record.nodes} primary=${record.primary} inline=${record.inline} formulas=${record.formulas} tables=${record.tables} cells=${record.cells} images=${record.images} read_images=${record.verifiedImages} excluded=${record.excluded} chunks=${record.chunks} assets=${record.assets} bytes=${record.ledgerBytes} leases=${record.readLeases} published=${record.published ? 1 : 0}`;
      hilog.info(0x0001,'SHUVI_R2','%{public}s',identity); hilog.info(0x0001,'SHUVI_R2','%{public}s',counts); this.results = [identity,counts]; this.summary = 'SnapshotReadbackPassed';
    } catch (error) { this.summary = error instanceof KnowledgeFailure ? error.message : 'SnapshotAuditFailed'; }
    finally { this.running = false; }
  }
  private async cleanupOwned(): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true;
    try { const count: number = await knowledgeCleanupOwnedFailures(context); this.summary = `OwnedCleanup:${count}`; hilog.info(0x0001,'SHUVI_R2','R2_CLEANUP scopes=%{public}d production=0',count); }
    catch (error) { this.summary = error instanceof KnowledgeFailure ? error.message : 'OwnedCleanupFailed'; }
    finally { this.running = false; }
  }
  private async cleanupVectors(): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true;
    try { const count: number = await vectorCleanupOwnedFailures(context); this.summary = `VectorOwnedCleanup:${count}`; hilog.info(0x0001,'SHUVI_R2','R2_CLEANUP scopes=%{public}d production=0',count); }
    catch (error) { this.summary = error instanceof KnowledgeFailure ? error.message : 'VectorOwnedCleanupFailed'; }
    finally { this.running = false; }
  }
  private async vectorOpen(): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true;
    const repository = KnowledgeAssembly.forContext(context).vectors;
    try { await repository.open(); this.summary = repository.capability(); hilog.info(0x0001,'SHUVI_R2','R2_VECTOR_SESSION available=1 spaces=%{public}d',repository.registeredSpaces().length); }
    catch (error) { this.summary = error instanceof KnowledgeFailure ? error.message : 'VectorOpenFailed'; }
    finally { await repository.close(); this.running = false; }
  }
  private async vectorRestart(prepare: boolean): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true;
    try { const result = await knowledgeVectorRestartCase(context,prepare); const row = result.cases[0]; const line: string = `R2 run=${result.run} suite=${result.version} case=${row.id} pass=${row.passed ? 1 : 0} reason=${row.reason} code=${row.code} in=0 out=0 calls=0 residual=0 end=0`; hilog.info(0x0001,'SHUVI_R2','%{public}s',line); this.results = [line]; this.summary = row.passed ? 'RestartCasePassed' : 'RestartCaseFailed'; }
    finally { this.running = false; }
  }
  private async productionReview(): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.running) { return; } this.running = true; const assembly = KnowledgeAssembly.forContext(context);
    try {
      await assembly.acquire();
      if (assembly.embedding.state.config.modelId !== 'BAAI/bge-m3' || (await assembly.embedding.baseline()).state !== 'AcceptedEngineeringBaseline') { throw new KnowledgeFailure('ExplicitConfigurationAndBaselineRequired','dry-review'); }
      const review: EmbeddingDryReview = await assembly.embedding.dryReview('kb-60986788281e094aff01063dfcf764f1');
      for (const row of review.rows) { const item: string = `R2_DRY_INPUT ordinal=${row.ordinal} hash=${row.hash} binding=${row.bindingHash} bound=${row.bound} state=${row.state} eligible=${row.eligible ? 1 : 0}`; hilog.info(0x0001,'SHUVI_R2','%{public}s',item); }
      const jobs = await assembly.vectorMetadata.jobs(); const vectors: number = jobs.reduce((sum: number,job: EmbeddingJob): number => sum+job.completedHashes.length,0);
      const line: string = `R2_DRY inputs=${review.rows.length} safe=${review.safe} eligible=${review.eligible} unproven=${review.unproven} invalid=${review.invalid} total=${review.totalBound} max=${review.maxBound} set=${review.setHash} revision=${assembly.embedding.state.config.revision} credential=${assembly.embedding.state.credential} requests=0 vectors=${vectors}`;
      hilog.info(0x0001,'SHUVI_R2','%{public}s',line); this.results = [line]; this.summary = 'DryReviewReadyNoNetwork';
    } catch (error) { this.summary = error instanceof KnowledgeFailure ? error.message : 'DryReviewFailed'; }
    finally { await assembly.release(); this.running = false; }
  }
  build() {
    Column({ space: 12 }) {
      if (this.imageFixture !== undefined) { ImageIntegrationView({ fixture: this.imageFixture, onBack: (): void => { this.closeImageFixture(); } }) }
      else if (this.ingestionFixture !== undefined) { ResidualIngestionView({ fixture: this.ingestionFixture,onBack: (): void => { this.closeResidual(); } }) }
      else if (this.historyFixture !== undefined) { ResidualHistoryView({ session: this.historyFixture,onBack: (): void => { this.closeResidual(); } }) }
      else if (this.queryFixture !== undefined) { CloseoutQueryView({ fixture: this.queryFixture,onBack: (): void => { this.closeQueryFixture(); } }) }
      else if (this.sourceFixture !== undefined) { PdfSourceView({ adapter: this.sourceFixture.adapter,session: this.sourceFixture.session,binding: this.sourceFixture.binding,locator: this.sourceFixture.locator,onOpened: async (): Promise<void> => { await this.sourceFixture?.addEvidence(); },onBack: (): void => { this.closeFixture(); } }) }
      else if (this.smokeOpen) { EmbeddingSafetySmoke({ onBack: (): void => { this.smokeOpen = false; } }) } else {
      Text('ROUND2 Native').fontSize(20)
       Text(this.summary).id('r2-suite-summary')
       Button('11图正式解析与本机回执').id('image-happy-path-entry').enabled(!this.running).onClick((): void => { this.onImageHappyPath(); })
      ForEach(['US1','US2','US3','US4','US5'], (caseId: string) => { Button('M3 隔离 '+caseId).id('m3-open-fixture-'+caseId).enabled(!this.running).onClick((): void => { this.openImageFixture(caseId); }) }, (caseId: string): string => caseId)
      Button('隔离 R007 入库验收').id('r2-open-residual-ingestion').enabled(!this.running).onClick((): void => { this.residual('ingestion'); })
      Button('隔离暂停历史验收').id('r2-open-residual-history').enabled(!this.running).onClick((): void => { this.residual('history'); })
      Button('运行交付修复本机测试').id('r2-run-closeout').enabled(!this.running).onClick((): void => { this.closeout(); })
      Button('打开隔离来源屏幕样例').id('r2-open-closeout-source').enabled(!this.running).onClick((): void => { this.closeout(true); })
      Button('打开隔离授权编辑样例').id('r2-open-closeout-query').enabled(!this.running).onClick((): void => { this.openQueryFixture(); })
      Button('校验冻结质量输入（不联网）').id('r2-quality-contract').enabled(!this.running).onClick((): void => { this.quality('contract'); })
      Row() { Checkbox().id('r2-quality-consent').select(this.qualityConsent).enabled(!this.running).onChange((checked: boolean): void => { this.qualityConsent = checked; }); Text('授权固定 8 条规则 + 16 个问题外发') }
      Row() { Checkbox().id('r2-quality-free').select(this.qualityFree).enabled(!this.running).onChange((checked: boolean): void => { this.qualityFree = checked; }); Text('确认本次 SiliconFlow BAAI/bge-m3 免费') }
      Button('运行真实语义24请求').id('r2-quality-run').enabled(!this.running && this.qualityReviewed && this.qualityConsent && this.qualityFree).onClick((): void => { this.quality('run'); })
      Button('核验质量缓存（不联网）').id('r2-quality-readback').enabled(!this.running).onClick((): void => { this.quality('readback'); })
      Button('只读核验生产向量').id('r2-quality-production-audit').enabled(!this.running).onClick((): void => { this.productionVectorAudit(); })
      Button('Run Native Suite').id('r2-run-native').enabled(!this.running).onClick((): void => { this.execute(); })
      Button('Run Isolated Local Suite').id('r2-run-local').enabled(!this.running).onClick((): void => { this.execute(true); })
      Button('Run Isolated Vector Suite').id('r2-run-vector').enabled(!this.running).onClick((): void => { this.execute(false,true); })
      Button('Run Isolated Embedding Flow').id('r2-run-embedding').enabled(!this.running).onClick((): void => { this.execute(false,false,true); })
      Button('Run Pinned Basis Suite').id('r2-run-basis').enabled(!this.running).onClick((): void => { this.execute(false,false,false,true); })
      Button('Review Approved PDF Locally').id('r2-dry-approved-pdf').enabled(!this.running).onClick((): void => { this.productionReview(); })
      Button('Open Isolated Safety Controls').id('r2-open-safety-smoke').enabled(!this.running).onClick((): void => { this.smokeOpen = true; })
      Button('Open Production Vector Session').id('r2-open-vector-session').enabled(!this.running).onClick((): void => { this.vectorOpen(); })
      Button('Prepare Owned Restart Case').id('r2-vector-restart-prepare').enabled(!this.running).onClick((): void => { this.vectorRestart(true); })
      Button('Verify Owned Restart Case').id('r2-vector-restart-verify').enabled(!this.running).onClick((): void => { this.vectorRestart(false); })
      Button('Read Public Identity Baseline').id('r2-public-audit').enabled(!this.running).onClick((): void => { this.audit(); })
      Button('Read Published PDF Snapshot').id('r2-pdf-audit').enabled(!this.running).onClick((): void => { this.pdfAudit(); })
      Button('Check Production Capability').id('r2-check-capability').enabled(!this.running).onClick((): void => { this.capability(); })
      Button('Clean Owned Failed Scopes').id('r2-clean-owned').enabled(!this.running).onClick((): void => { this.cleanupOwned(); })
      Button('Clean This Turn Vector Scopes').id('r2-clean-vector-owned').enabled(!this.running).onClick((): void => { this.cleanupVectors(); })
      Button('返回').enabled(!this.running).onClick(this.onBack)
      ForEach(this.results,(line: string): void => { Text(line).fontSize(11).width('100%') },(line: string): string => line)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
