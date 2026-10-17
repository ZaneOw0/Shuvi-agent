import { KnowledgeSearchService } from '../application/KnowledgeSearchService';
import { TextKnowledgeService } from '../application/TextKnowledgeService';
import { TextViewState, TextScreen } from '../domain/TextKnowledgeModels';
import { KnowledgeHit, KnowledgeHistory, KnowledgeHistoryCursor, KnowledgeHistoryPage } from '../domain/KnowledgeSearchModels';
import { KnowledgeCallbackListener, KnowledgeDocumentListPort } from '../domain/KnowledgePorts';
import { TextKnowledgeView } from './TextKnowledgeView';
import { Theme } from '../../components/Theme';
import { PdfKnowledgeDocument } from '../domain/PdfKnowledgeModels';
import { KnowledgeDerivedLifecycle } from '../application/KnowledgeLifecycleService';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KnowledgeSourceKind } from '../domain/KnowledgeSearchModels';
import { EmbeddingService } from '../application/EmbeddingService';
import { EmbeddingSpace, EmbeddingJob, TokenEligibilityEvidence } from '../domain/EmbeddingModels';
import { EmbeddingDryReview, EmbeddingInputReview, EmbeddingPinnedBasis } from '../domain/EmbeddingBasisModels';
import { KnowledgeSemanticSearchPort } from '../domain/VectorWorkflowModels';
import { VectorUsageSummary } from '../domain/VectorWorkflowModels';
import { prepareTextQuery } from '../pipeline/QueryPreparation';
import { embeddingPublicAudit } from '../infra/EmbeddingPublicAudit';
import { embeddingTrialAudit, embeddingLogTrialResult } from '../infra/EmbeddingTrialAudit';
import { KnowledgeAssembly } from '../infra/KnowledgeAssembly';
import { EmbeddingTrialScope, EmbeddingTrialResult } from '../domain/VectorWorkflowModels';
import { embeddingFullAudit, embeddingLogFullQuery } from '../infra/EmbeddingFullAudit';
import { QueryConsentSession } from '../application/QueryConsentSession';
import { embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { KnowledgeResultCard } from './KnowledgeResultCard';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';

@Component
export struct KnowledgeView {
  service: KnowledgeSearchService | undefined = undefined;
  textService: TextKnowledgeService | undefined = undefined;
  @Link textState: TextViewState;
  onParsePrepare: () => void = (): void => {};
  onRetryOpen: () => void = (): void => {};
  onOpenHit: (hit: KnowledgeHit) => void = (_hit: KnowledgeHit): void => {};
  documentsPort: KnowledgeDocumentListPort | undefined = undefined;
  lifecycle: KnowledgeDerivedLifecycle | undefined = undefined;
  embedding: EmbeddingService | undefined = undefined;
  semantic: KnowledgeSemanticSearchPort | undefined = undefined;
  initialTrialJob: string = ''; initialSpace: string = '';
  @State corpusConsent: boolean = false;
  @State corpusFree: boolean = false;
  @State queryConsent: boolean = false;
  @State queryFree: boolean = false;
  @State resendUnknown: boolean = false;
  @State fullScope: boolean = false;
  @State review: EmbeddingDryReview = new EmbeddingDryReview();
  @State reviewPage: number = 0;
  @State reviewRows: EmbeddingInputReview[] = [];
  @State basisLabel: string = 'NotAccepted';
  @State progressLabel: string = 'Idle';
  @State credentialLabel: string = 'Missing';
  @State detectionLabel: string = 'Untested';
  @State queryBound: string = 'NotCounted';
  @State countedQuery: string = '';
  @State queryEligible: boolean = false;
  @State trial: EmbeddingTrialScope = new EmbeddingTrialScope();
  @State trialResult: EmbeddingTrialResult = new EmbeddingTrialResult();
  @State trialConsent: boolean = false;
  @State trialFree: boolean = false;
  @State trialJobId: string = '';
  @State spaces: EmbeddingSpace[] = [];
  @State vectorJobs: EmbeddingJob[] = [];
  @State selectedSpace: string = '';
  @State usageLabel: string = '';
  @State pdfDocuments: PdfKnowledgeDocument[] = [];
  @State documentOffset: number = 0; @State taskOffset: number = 0;
  private async pageDocuments(delta: number): Promise<void> { this.documentOffset = Math.max(0,this.documentOffset+delta*12); this.invalidateQueries(); this.review = new EmbeddingDryReview(); this.reviewRows = []; this.corpusConsent = false; this.corpusFree = false; await this.refreshDocuments(); }
  private async pageTasks(delta: number): Promise<void> { this.taskOffset = Math.max(0,this.taskOffset+delta*12); this.invalidateQueries(); this.trialJobId = ''; this.corpusConsent = false; this.corpusFree = false; await this.refreshVectors(); }
  @State question: string = '';
  @State hits: KnowledgeHit[] = [];
  @State message: string = '';
  @State busy: boolean = false;
  @State legacyOpen: boolean = false;
  @State includeReferenceAside: boolean = false;
  @State historyRows: KnowledgeHistory[] = [];
  @State historyOpen: boolean = false;
  @State historyPending: boolean = false;
  @State includeArchived: boolean = false;
  private historyCursor: KnowledgeHistoryCursor = new KnowledgeHistoryCursor();
  private queryApproval: QueryConsentSession = new QueryConsentSession();
  private trialApproval: QueryConsentSession = new QueryConsentSession();
  private consentConfig: string = '';
  private registerCancel: KnowledgeCancellation | undefined;
  private invalidateQueries(): void { this.queryApproval.invalidate(); this.trialApproval.invalidate(); this.queryConsent = false; this.queryFree = false; this.trialConsent = false; this.trialFree = false; this.queryEligible = false; this.countedQuery = ''; this.queryBound = '输入或范围已变化，请重新计数'; }
  private editQuestion(text: string): void { this.question = text; this.invalidateQueries(); }
  private listener: KnowledgeCallbackListener = new KnowledgeCallbackListener((): void => { this.changed(); });
  aboutToAppear(): void { this.service?.subscribe(this.listener); this.embedding?.subscribe(this.listener); this.changed(); this.selectedSpace = this.initialSpace; if (this.initialTrialJob.length > 0) { this.prepareTrial(this.initialTrialJob); } this.refreshDocuments(); this.refreshVectors(); this.readBasis(); }
  aboutToDisappear(): void { if (this.registerCancel !== undefined) { this.registerCancel.invalid = true; } this.invalidateQueries(); this.corpusConsent = false; this.corpusFree = false; this.resendUnknown = false; this.service?.pause(); this.service?.unsubscribe(this.listener); this.embedding?.unsubscribe(this.listener); }
  private async readBasis(): Promise<void> { try { this.basisLabel = (await this.embedding?.baseline())?.state ?? 'Unavailable'; } catch { this.basisLabel = 'Unavailable'; } }
  private async acceptBasis(): Promise<void> { try { await this.embedding?.acceptBaseline(); await this.readBasis(); this.message = this.embedding?.state.message ?? ''; } catch { this.message = '当前模型或修订不匹配固定基线，未接受、未请求'; } }
  private async prepareModel(): Promise<void> { await this.embedding?.preparePinnedModel(); await this.readBasis(); this.review = new EmbeddingDryReview(); this.reviewRows = []; }
  private async dryReview(documentId: string): Promise<void> { try { if (this.embedding === undefined) { return; } this.review = await this.embedding.dryReview(documentId); this.reviewPage = 0; this.reviewRows = this.review.rows.slice(0,12); this.corpusConsent = false; this.corpusFree = false; } catch { this.message = '本机审查未完成，未创建外发授权'; } }
  private pageReview(delta: number): void { this.reviewPage = Math.max(0,Math.min(Math.ceil(this.review.rows.length/12)-1,this.reviewPage+delta)); this.reviewRows = this.review.rows.slice(this.reviewPage*12,this.reviewPage*12+12); }
  private async countQuery(trial: boolean = false): Promise<void> {
    this.invalidateQueries(); const epoch: number = this.queryApproval.epoch;
    try { if (this.embedding === undefined) { return; } const actual = prepareTextQuery(this.question).actualInput; const config = embeddingFingerprint(this.embedding.state.config); const scope = trial ? await this.embedding.prepareTrial(this.trialJobId) : undefined; const proof = await this.embedding.reviewQuery(actual);
      if (epoch !== this.queryApproval.epoch || actual !== this.queryPreview() || config !== embeddingFingerprint(this.embedding.state.config)) { return; }
      if (scope !== undefined) { this.trial = scope; this.trialApproval.review(actual,proof,this.embedding.state.config,'trial',scope.space.id,scope.id,scope.setHash); }
      else { this.queryApproval.review(actual,proof,this.embedding.state.config,'query',this.selectedSpace); }
      this.queryBound = `${proof.localState} / bound ${proof.upperBound}/8192 / hash ${proof.textHash} / ${proof.baseline.state}`; this.countedQuery = actual; this.queryEligible = true;
    } catch { this.queryBound = '计数或范围未核验，外发关闭'; }
  }
  private async refreshVectors(): Promise<void> { try { this.spaces = (await this.semantic?.spaces() ?? []).slice(0,20); this.vectorJobs = await this.embedding?.vectorJobsPage(this.taskOffset,12) ?? []; const usage: VectorUsageSummary | undefined = await this.embedding?.vectorUsage(); if (usage !== undefined) { this.usageLabel = `文档响应 ${usage.received} 次 / 已报告 Token ${usage.reportedTotal} / 未报用量 ${usage.missingUsage} / Unknown ${usage.unknown}；不等于免费余额`; } } catch { this.message = '向量任务或空间读取未确认，关键词可用'; } }
  private async vectorize(documentId: string, resumeId: string = ''): Promise<void> { const consent: boolean = this.corpusConsent; const free: boolean = this.corpusFree; const resend: boolean = this.resendUnknown; const full: boolean = this.fullScope; this.corpusConsent = false; this.corpusFree = false; this.resendUnknown = false; this.fullScope = false; await this.embedding?.vectorizePdf(documentId,consent,free,resumeId,resend,full); this.message = this.embedding?.state.message ?? '向量服务不可用'; await this.refreshVectors(); await this.refreshDocuments(); }
  private async retireVector(generation: string): Promise<void> { try { await this.lifecycle?.retireVector(generation); await this.refreshVectors(); this.message = '非活动向量退役完成；关键词和原件保留'; } catch { this.message = '向量世代仍活动、租用或待清理；未删除关键词'; } }
  private async retryReleases(): Promise<void> { try { const context = this.getUIContext().getHostContext(); if (context !== undefined) { await KnowledgeAssembly.forContext(context).retrySourceReleases(); } await this.embedding?.retryReleases(); this.message = '读租约释放已确认'; } catch { this.message = '释放仍未确认，保持保护性暂停'; } }
  private async auditEmbedding(): Promise<void> { const context = this.getUIContext().getHostContext(); if (context !== undefined) { await embeddingPublicAudit(context); } }
  private async auditTrial(): Promise<void> { const context = this.getUIContext().getHostContext(); if (context !== undefined) { await embeddingTrialAudit(KnowledgeAssembly.forContext(context)); } }
  private async auditFull(): Promise<void> { const context = this.getUIContext().getHostContext(); if (context !== undefined) { await embeddingFullAudit(KnowledgeAssembly.forContext(context),context); } }
  private async registerPages(document: PdfKnowledgeDocument): Promise<void> {
    if (this.busy) { return; } this.busy = true; const cancel = new KnowledgeCancellation(); this.registerCancel = cancel;
    try { const context = this.getUIContext().getHostContext(); if (context === undefined) { throw new Error('ContextUnavailable'); } const assembly = KnowledgeAssembly.forContext(context); const job = await assembly.repository.generationJob(document.activeContentGeneration); const hit = new KnowledgeHit(); hit.documentId = document.id; hit.generation = document.activeContentGeneration; hit.snapshotId = job.snapshotId; hit.snapshotHash = job.snapshotHash; hit.originalHash = document.binding.originalHash; hit.originalVersion = document.binding.originalVersion;
      const bytes = await context.resourceManager.getRawFileContent('pdf-page-review-v1.json'); const count = await assembly.pages.registerReview(bytes,'d99055bb5e8005a73d2c085870cc4f5a405ef8ee59768d3354e8844e72faee39',hit,cancel); this.message = `已登记 ${count} 个受审节点的原页依据；内容与向量未改，请重新本机检索`; }
    catch { this.message = '受审清单与当前原件/快照或节点不匹配，未升级未核页；已登记证据和旧索引保留'; } finally { this.registerCancel = undefined; this.busy = false; }
  }
  private async prepareTrial(jobId: string): Promise<void> { this.invalidateQueries(); try { if (this.embedding === undefined) { return; } this.trial = await this.embedding.prepareTrial(jobId); this.trialJobId = jobId; this.message = `试验范围 3/${this.trial.job.expectedHashes.length}，不是完整语义就绪`; } catch { this.message = '三块试验scope核验失败；未请求'; } }
  private async trialSearch(): Promise<void> { try { if (this.embedding === undefined) { return; } const actual = prepareTextQuery(this.question).actualInput; const scope = await this.embedding.prepareTrial(this.trialJobId); const proof = await this.embedding.reviewQuery(actual); const snapshot = this.trialApproval.consume(actual,proof,this.embedding.state.config,'trial',scope.space.id,scope.id,scope.setHash); this.invalidateQueries(); this.trialResult = await this.embedding.submitReviewedTrial(this.trialJobId,snapshot); embeddingLogTrialResult(this.trialResult); this.message = this.trialResult.notice; } catch { this.invalidateQueries(); this.message = 'NoRequest：试验授权已变化或请求失败，不自动重试'; } }
  private canFullScope(): boolean { return this.vectorJobs.some((job: EmbeddingJob): boolean => job.documentId === this.review.documentId && job.contentGeneration === this.review.generation && job.completedHashes.length >= Math.min(3,this.review.rows.length) && job.completedHashes.length < job.expectedHashes.length); }
  private queryPreview(): string { if (this.question.trim().length === 0) { return '未输入'; } try { return prepareTextQuery(this.question).actualInput; } catch { return '输入格式不合法，未检索或外发'; } }
  changed(): void { const config: string = this.embedding === undefined ? '' : embeddingFingerprint(this.embedding.state.config); if (config !== this.consentConfig) { this.consentConfig = config; this.invalidateQueries(); } if (this.service === undefined) { this.message = '统一查询不可用；M1 资料仍可管理'; return; } this.hits = this.service.state.result.hits.slice(); this.message = this.service.state.message; this.busy = this.service.state.busy || (this.embedding?.state.busy ?? false); this.historyPending = this.service.state.historyPending; this.progressLabel = this.embedding?.progress() ?? 'Idle'; this.credentialLabel = this.embedding?.state.credential ?? 'Unavailable'; this.detectionLabel = this.embedding?.state.detection.status ?? 'Untested'; }
  private async search(): Promise<void> {
    if (this.service === undefined) { return; }
    this.service.state.queryConsent = false; this.service.state.queryFree = false; this.service.state.queryApproval = undefined;
    if (this.queryConsent || this.queryFree) {
      try { if (this.embedding === undefined) { throw new Error('NoEmbedding'); } const actual = prepareTextQuery(this.question).actualInput; const proof = await this.embedding.reviewQuery(actual); const snapshot = this.queryApproval.consume(actual,proof,this.embedding.state.config,'query',this.selectedSpace); this.service.state.queryApproval = snapshot; this.service.state.queryConsent = snapshot.approved; this.service.state.queryFree = snapshot.free; }
      catch { this.invalidateQueries(); this.message = 'NoRequest：相似查询授权已变化，仅执行本机正文检索'; }
    }
    this.service.state.question = this.question; this.service.state.includeReferenceAside = this.includeReferenceAside; this.service.state.includeArchived = this.includeArchived; this.service.state.selectedSpaceId = this.selectedSpace; this.invalidateQueries(); await this.service.search();
    const line: string = `R2_QUERY history=${this.service.state.historyId} hits=${this.hits.length} pdf=${this.hits.filter((hit: KnowledgeHit): boolean => hit.sourceKind === KnowledgeSourceKind.Pdf).length} text=${this.hits.filter((hit: KnowledgeHit): boolean => hit.sourceKind === KnowledgeSourceKind.Text).length} pending=${this.service.state.historyPending ? 1 : 0} failed=${this.service.state.result.failed ? 1 : 0}`;
     hilog.info(0x0001,'SHUVI_R2','%{public}s',line);
     const context = this.getUIContext().getHostContext(); if (context !== undefined) { embeddingLogFullQuery(KnowledgeAssembly.forContext(context)); }
  }
  private async loadHistory(reset: boolean): Promise<void> {
    if (this.service === undefined) { return; }
    if (reset) { this.historyCursor = new KnowledgeHistoryCursor(); this.historyRows = []; } this.historyOpen = true;
    try {
      const page: KnowledgeHistoryPage = await this.service.historyPage(this.historyCursor,20); this.historyRows = page.records; this.historyCursor = page.next;
      hilog.info(0x0001,'SHUVI_R2','R2_HISTORY rows=%{public}d pdf=%{public}d',page.records.length,page.records.filter((record: KnowledgeHistory): boolean => record.result.hits.some((hit: KnowledgeHit): boolean => hit.sourceKind === KnowledgeSourceKind.Pdf)).length);
    }
    catch { this.message = '历史读取失败，旧记录未改写'; }
  }
  private async refreshDocuments(): Promise<void> { try { this.pdfDocuments = await this.documentsPort?.listPage(this.documentOffset,12) ?? []; } catch { this.message = 'PDF 列表不可用，旧资料未修改'; } }
  private async archivePdf(document: PdfKnowledgeDocument): Promise<void> {
    try { await this.lifecycle?.archive(document.id,!document.archived); await this.refreshDocuments(); } catch { this.message = '归档状态未确认，原件保留'; }
  }
  private confirmDeletePdf(document: PdfKnowledgeDocument): void {
    AlertDialog.show({ title: '删除 PDF 知识资料',message: '本机知识索引将立即隐藏，历史保留为失效快照。原件与 ZIP 仍归解析准备区，不自动删除或重新上传。',
      primaryButton: { value: '取消',action: (): void => {} },secondaryButton: { value: '确认删除',action: (): void => { this.deletePdf(document.id); } } });
  }
  private async deletePdf(id: string): Promise<void> { try { await this.lifecycle?.deleteDocument(id); await this.refreshDocuments(); } catch { this.message = '删除或派生清理未完成，按持久状态保留重试'; } }
  build() {
    Column({ space: 14 }) {
      if (this.legacyOpen || this.textState.screen === TextScreen.Detail) {
        Button('返回统一知识库').constraintSize({ minHeight: 44 }).onClick((): void => { this.legacyOpen = false; })
        TextKnowledgeView({ knowledgeState: this.textState, service: this.textService, onRetryOpen: this.onRetryOpen, onParsePrepare: this.onParsePrepare })
      } else {
        Text('知识库').fontSize(22).fontWeight(FontWeight.Bold)
         Text(`M1 文本 ${this.textState.documents.length} 件 · PDF 第 ${Math.floor(this.documentOffset/12)+1} 页 ${this.pdfDocuments.length} 件`).fontSize(13).fontColor(Theme.muted)
        Row({ space: 12 }) {
          Button('文本资料管理').constraintSize({ minHeight: 44 }).onClick((): void => { this.legacyOpen = true; })
          Button('解析准备 / PDF').constraintSize({ minHeight: 44 }).onClick(this.onParsePrepare)
          Button('历史').id('r2-query-history').constraintSize({ minHeight: 44 }).onClick((): void => { this.loadHistory(true); })
        }.width('100%')
         TextInput({ text: this.question, placeholder: '检索资料' }).id('r2-query-input').onChange((text: string): void => { this.editQuestion(text); })
         Button('清空查询').id('r2-query-clear').onClick((): void => { this.editQuestion(''); })
         Row({ space: 10 }) { Checkbox().select(this.includeReferenceAside).onChange((checked: boolean): void => { this.includeReferenceAside = checked; this.invalidateQueries(); }); Text('包含 PDF 参考文献与旁注').fontSize(13) }.width('100%')
         Row({ space: 10 }) { Checkbox().select(this.includeArchived).onChange((checked: boolean): void => { this.includeArchived = checked; this.invalidateQueries(); }); Text('包含已归档资料').fontSize(13) }.width('100%')
        Text(`本次实际检索输入：${this.queryPreview()}`).fontSize(13).width('100%')
        Button('仅本机计数问题').id('r2-query-count').onClick((): void => { this.countQuery(); })
        Text(this.queryBound).id('r2-query-bound').fontSize(12).width('100%')
         ForEach(this.spaces,(space: EmbeddingSpace): void => { Button(`${this.selectedSpace === space.id ? '已选' : '选择'} ${space.returnedModel} / ${space.dimension} 维`).id(`r2-space-${space.id}`).onClick((): void => { this.selectedSpace = space.id; this.invalidateQueries(); }) },(space: EmbeddingSpace): string => space.id)
         Row({ space: 10 }) { Checkbox().id('r2-query-consent').select(this.queryConsent).enabled(this.queryEligible && this.countedQuery === this.queryPreview()).onChange((checked: boolean): void => { this.queryConsent = checked; this.queryApproval.approve(checked); }); Text('仅同意本次已计数的实际检索输入外发，用于问题向量；不授权 PDF').fontSize(13).layoutWeight(1) }.width('100%')
         Row({ space: 10 }) { Checkbox().id('r2-query-free').select(this.queryFree).onChange((checked: boolean): void => { this.queryFree = checked; this.queryApproval.confirmFree(checked); }); Text('确认本次问题请求免费资格').fontSize(13).layoutWeight(1) }.width('100%')
        Button('检索').id('r2-query-search').constraintSize({ minHeight: 44 }).enabled(!this.busy && this.service !== undefined).onClick((): void => { this.search(); })
        Text(this.message).id('r2-query-status').fontSize(14).fontColor(Theme.muted).width('100%')
        if (this.historyPending) { Button('重试保存本次历史').id('r2-history-retry').onClick((): void => { this.service?.retryHistory(); }) }
        Text(`固定工程基线：${this.basisLabel}`).id('r2-basis-state').fontSize(14).width('100%')
        Button('审计嵌入公开状态').id('r2-embedding-public-audit').onClick((): void => { this.auditEmbedding(); })
        Button('仅审计三块试验状态').id('r2-trial-audit').onClick((): void => { this.auditTrial(); })
        Button('核对完整向量读回与账本').id('r2-full-audit').enabled(!this.busy).onClick((): void => { this.auditFull(); })
        Text(`模型 ${this.embedding?.state.config.modelId ?? ''} / revision ${this.embedding?.state.config.revision ?? 0} / Key ${this.credentialLabel} / 检测 ${this.detectionLabel}`).id('r2-embedding-public-state').fontSize(13).width('100%')
        Text(`${EmbeddingPinnedBasis.profile} / ${EmbeddingPinnedBasis.revision}\nproviderRevision=NotReported\nproviderConsistency=UnverifiedRevisionAndHiddenProcessing`).fontSize(12).width('100%')
        Button('保存 BAAI/bge-m3 本机测试配置').id('r2-prepare-pinned-model').enabled(!this.busy).onClick((): void => { this.prepareModel(); })
        Button('接受固定工程基线（不授权外发）').id('r2-accept-basis').enabled(!this.busy).onClick((): void => { this.acceptBasis(); })
        Text(`进度：${this.progressLabel}`).id('r2-vector-progress').fontSize(14)
        if (this.review.rows.length > 0) {
          Text(`审查 ${this.review.rows.length} 块 / 合格 ${this.review.eligible} / Safe ${this.review.safe} / BoundUnproven ${this.review.unproven} / Invalid ${this.review.invalid}\n累计上界 ${this.review.totalBound} / 最大 ${this.review.maxBound}\n${this.review.recipient} / ${this.review.model}\n集合 ${this.review.setHash}`).id('r2-dry-review-summary').fontSize(12).width('100%')
          ForEach(this.reviewRows,(row: EmbeddingInputReview): void => { Text(`#${row.ordinal+1} ${row.chunkId}\n${row.state} / bound ${row.bound}/8192 / ${row.attemptState}\ninput ${row.hash}\nbinding ${row.bindingHash}`).fontSize(11).width('100%') },(row: EmbeddingInputReview): string => row.chunkId)
          Row({ space: 10 }) { Button('上一组计数').enabled(this.reviewPage > 0).onClick((): void => { this.pageReview(-1); }); Text(`${this.reviewPage+1}/${Math.ceil(this.review.rows.length/12)}`); Button('下一组计数').id('r2-review-next').enabled((this.reviewPage+1)*12 < this.review.rows.length).onClick((): void => { this.pageReview(1); }) }
        }
        Row({ space: 10 }) { Checkbox().id('r2-full-scope').select(this.fullScope).enabled(this.canFullScope()).onChange((checked: boolean): void => { this.fullScope = checked; this.corpusConsent = false; }); Text('小范围核验后，另行选择完整 PDF 续跑范围；未选择时最多 3 个未核输入').fontSize(13).layoutWeight(1) }.width('100%')
        Row({ space: 10 }) { Checkbox().id('r2-corpus-consent').select(this.corpusConsent).onChange((checked: boolean): void => { this.corpusConsent = checked; }); Text(this.fullScope ? '同意本次完整已审查 PDF 范围外发，不授权问题' : '仅同意本次最多 3 个已审查未核输入外发，不授权全部 PDF 或问题').fontSize(13).layoutWeight(1) }.width('100%')
        Row({ space: 10 }) { Checkbox().id('r2-corpus-free').select(this.corpusFree).onChange((checked: boolean): void => { this.corpusFree = checked; }); Text('确认本次文档请求免费资格；窗口 15 分钟，Unknown 不自动重发').fontSize(13).layoutWeight(1) }.width('100%')
        Button('暂停向量任务').onClick((): void => { this.embedding?.pause(); })
        Button('重试释放本次读租约').onClick((): void => { this.retryReleases(); })
        Text(this.usageLabel).fontSize(13).width('100%')
        Row({ space: 10 }) { Checkbox().select(this.resendUnknown).onChange((checked: boolean): void => { this.resendUnknown = checked; }); Text('仅对本次显式续跑：接受 Unknown 可能已计费，并再次发送未核输入；已核输入不重发').fontSize(13).layoutWeight(1) }.width('100%')
        Button('重试派生清理').onClick((): void => { this.lifecycle?.cleanup(); })
         ForEach(this.vectorJobs,(job: EmbeddingJob): void => {
          Button('核验此任务前三块试验范围').id(`r2-trial-prepare-${job.id}`).enabled(!this.busy).onClick((): void => { this.prepareTrial(job.id); })
          Button(`显式续跑 ${job.stage} ${job.completedHashes.length}/${job.expectedHashes.length}`).id(`r2-resume-${job.id}`).enabled(this.corpusConsent && this.corpusFree && !this.busy).onClick((): void => { this.vectorize(job.documentId,job.id); })
          Button('退役此非活动向量世代').onClick((): void => { this.retireVector(job.vectorGeneration); })
         },(job: EmbeddingJob): string => job.id)
         Row() { Button('前页任务').id('r2-task-page-prev').enabled(this.taskOffset > 0).onClick((): void => { this.pageTasks(-1); }); Button('后页任务').id('r2-task-page-next').enabled(this.vectorJobs.length === 12).onClick((): void => { this.pageTasks(1); }) }
        if (this.trialJobId.length > 0) {
          Text(`试验范围 3/${this.trial.job.expectedHashes.length}，不是完整语义就绪`).id('r2-trial-scope-label').fontSize(14)
           TextInput({ text: this.question, placeholder: '本次独立授权的试验问题' }).id('r2-trial-query-input').onChange((text: string): void => { this.editQuestion(text); })
           Button('仅本机计数试验问题').id('r2-trial-query-count').onClick((): void => { this.countQuery(true); })
          Text(this.queryBound).id('r2-trial-query-bound').fontSize(12)
           Row({ space: 10 }) { Checkbox().id('r2-trial-query-consent').select(this.trialConsent).enabled(this.queryEligible && this.countedQuery === this.question).onChange((checked: boolean): void => { this.trialConsent = checked; this.trialApproval.approve(checked); }); Text('仅同意本次问题一次向量请求，候选仅以上三块').fontSize(13).layoutWeight(1) }
           Row({ space: 10 }) { Checkbox().id('r2-trial-query-free').select(this.trialFree).onChange((checked: boolean): void => { this.trialFree = checked; this.trialApproval.confirmFree(checked); }); Text('确认本次问题请求免费资格').fontSize(13).layoutWeight(1) }
          Button('执行一次三块试验检索').id('r2-trial-query-request').enabled(!this.busy && this.queryEligible && this.trialConsent && this.trialFree).onClick((): void => { this.trialSearch(); })
          Text(this.trialResult.notice).id('r2-trial-result').fontSize(14)
          ForEach(this.trialResult.hits,(hit: KnowledgeHit): void => { Text(`${hit.chunkId} / ${hit.channels.join('+')} / distance ${hit.vectorDistance}`).fontSize(12) },(hit: KnowledgeHit): string => hit.id)
        }
        ForEach(this.pdfDocuments, (document: PdfKnowledgeDocument) => {
          Column({ space: 8 }) {
            Text(`PDF · ${document.title || document.id} · ${document.archived ? '已归档' : document.stage}`).fontSize(15).width('100%')
            Text(`关键词 ${document.chunkCount} 块 · ${document.partial ? '部分可用' : '覆盖未确认'} · ${document.activeVectorGeneration.length > 0 ? '已有向量世代' : '向量未就绪'}`).fontSize(13).fontColor(Theme.muted).width('100%')
            Button('仅本机审查全部输入').id(`r2-review-${document.id}`).enabled(!this.busy).onClick((): void => { this.dryReview(document.id); })
            Button('登记已审原页').id(`r2-register-pages-${document.id}`).enabled(!this.busy).onClick((): void => { this.registerPages(document); })
            Button(`向量化 / 本次最多 ${this.fullScope ? document.chunkCount : Math.min(3,document.chunkCount)} 次请求`).id(`r2-vectorize-${document.id}`).enabled(this.review.documentId === document.id && this.review.eligible === document.chunkCount && this.corpusConsent && this.corpusFree && !this.busy).onClick((): void => { this.vectorize(document.id); })
            Row({ space: 12 }) {
              Button(document.archived ? '恢复' : '归档').constraintSize({ minHeight: 44 }).onClick((): void => { this.archivePdf(document); })
              Button('删除').constraintSize({ minHeight: 44 }).onClick((): void => { this.confirmDeletePdf(document); })
            }
          }.width('100%').padding({ top: 10,bottom: 10 }).border({ width: { bottom: 1 },color: Theme.line })
         }, (document: PdfKnowledgeDocument): string => document.id)
         Row() { Button('前页文档').id('r2-document-page-prev').enabled(this.documentOffset > 0).onClick((): void => { this.pageDocuments(-1); }); Button('后页文档').id('r2-document-page-next').enabled(this.pdfDocuments.length === 12).onClick((): void => { this.pageDocuments(1); }) }
        if (this.historyOpen) {
          ForEach(this.historyRows, (record: KnowledgeHistory) => {
            Column({ space: 8 }) {
              Text(record.result.input.fullQuestion).fontSize(15).width('100%')
              ForEach(record.result.hits, (citation: KnowledgeHit) => {
                KnowledgeResultCard({ hit: citation, onOpenHit: this.onOpenHit }).id(`r2-citation-${record.id}-${citation.chunkId}`)
              }, (citation: KnowledgeHit): string => citation.id)
            }.width('100%').padding({ top: 10,bottom: 10 }).border({ width: { bottom: 1 },color: Theme.line })
          }, (record: KnowledgeHistory): string => `${record.source}:${record.id}`)
          Button('更多历史').onClick((): void => { this.loadHistory(false); })
        }
        ForEach(this.hits, (hit: KnowledgeHit) => {
          KnowledgeResultCard({ hit: hit, onOpenHit: this.onOpenHit }).id(`r2-hit-${hit.chunkId}`)
        }, (hit: KnowledgeHit): string => hit.id)
        Text(`向量资格：${this.embedding?.corpusGate() ?? 'Unavailable'}；M1 不向量化；未输入 Key 不请求`).fontSize(13).fontColor(Theme.amber).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
