import { DocxIngestionService } from '../application/DocxIngestionService';
import { DocxDocument, DocxNativeNode, DocxCoverageIssue, DocxChunk, DocxJob, DocxStage, DocxSnapshot } from '../domain/DocxKnowledgeModels';
import { KnowledgeCallbackListener } from '../domain/KnowledgePorts';
import { EmbeddingService } from '../application/EmbeddingService';
import { EmbeddingJob, EmbeddingJobStage, EmbeddingCredentialStatus, EmbeddingDetectionStatus, EmbeddingProvider } from '../domain/EmbeddingModels';
import { EmbeddingBaselineAcceptance, EmbeddingDryReview, EmbeddingInputReview, EmbeddingPinnedBasis } from '../domain/EmbeddingBasisModels';
import { embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { embeddingBaselineMatches } from '../pipeline/EmbeddingBasisPolicy';

@Component
export struct DocxIngestionView {
  service: DocxIngestionService | undefined = undefined;
  embedding: EmbeddingService | undefined = undefined;
  onBack: () => void = (): void => {};
  onParseSettings: () => void = (): void => {};
  onEmbeddingSettings: () => void = (): void => {};
  onSearch: () => void = (): void => {};
  onSource: (documentId: string) => void = (_documentId: string): void => {};
  @State private documents: DocxDocument[] = [];
  @State private selectedId: string = '';
  @State private message: string = '';
  @State private progress: string = '';
  @State private selectedIdentity: string = '';
  @State private busy: boolean = false;
  @State private localPending: boolean = false;
  @State private fullFile: boolean = false;
  @State private free: boolean = false;
  @State private coverageConsent: boolean = false;
  @State private report: string = '';
  @State private reportHash: string = '';
  @State private coverageReady: boolean = false;
  @State private bodyPage: number = 0;
  @State private bodyCount: number = 0;
  @State private bodyText: string = '';
  @State private vectorInputs: DocxChunk[] = []; @State private vectorPage: number = 0;
  @State private vectorCount: number = 0; @State private vectorJobs: EmbeddingJob[] = [];
  @State private vectorConsent: boolean = false; @State private vectorFree: boolean = false;
  @State private vectorFull: boolean = false; @State private resendUnknown: boolean = false;
  @State private vectorProgress: string = ''; @State private vectorEligible: boolean = false;
  @State private vectorReview: EmbeddingDryReview = new EmbeddingDryReview();
  @State private basisSummary: string = '';
  @State private basisViewed: boolean = false;
  @State private documentPage: number = 0;
  @State private candidateJobs: DocxJob[] = [];
  private reviewId: string = ''; private configBinding: string = ''; private selectionEpoch: number = 0;
  private allVectorInputs: DocxChunk[] = [];
  private revision: string = '';
  private basisBinding: string = '';
  private listener: KnowledgeCallbackListener = new KnowledgeCallbackListener((): void => { this.update(); });
  private clear(): void { this.fullFile = false; this.free = false; this.coverageConsent = false; this.vectorConsent = false; this.vectorFree = false; this.vectorFull = false; this.resendUnknown = false; this.reviewId = ''; this.vectorEligible = false; this.vectorInputs = []; this.allVectorInputs = []; this.vectorJobs = []; this.vectorCount = 0; this.vectorPage = 0; this.vectorReview = new EmbeddingDryReview(); this.selectionEpoch++; }
  private embeddingBinding(): string {
    const embedding: EmbeddingService | undefined = this.embedding; if (embedding === undefined) { return ''; }
    const state = embedding.state; const detection = state.detection;
    return `${embeddingFingerprint(state.config)}|${state.config.mutationPending}|${state.credential}|${detection.status}|${detection.configFingerprint}|${detection.credentialRevision}|${detection.requestedModel}|${detection.returnedModel}|${detection.dimension}|${detection.probeHash}`;
  }
  private update(): void {
    const service: DocxIngestionService | undefined = this.service; if (service === undefined) { this.message = 'DOCX服务不可用'; return; }
    const revision: string = service.authorizationRevision(this.selectedId); const config: string = this.embeddingBinding();
    if (revision !== this.revision || config !== this.configBinding) {
      if (config !== this.configBinding) { this.basisViewed = false; this.basisSummary = ''; this.basisBinding = ''; }
      this.revision = revision; this.configBinding = config; this.clear();
    }
    this.documents = service.documents.slice(); this.message = service.message; this.busy = this.localPending || service.busy || (this.embedding?.state.busy ?? false); this.progress = service.progress(this.selectedId);
    this.selectedIdentity = service.selectedIdentity(this.selectedId);
    this.candidateJobs = service.jobs.filter((job: DocxJob): boolean => job.documentId === this.selectedId && [DocxStage.Review,DocxStage.Processing,DocxStage.Paused].indexOf(job.stage) >= 0 && job.failure !== 'CandidateAbandoned');
    const snapshot: DocxSnapshot | undefined = service.snapshot?.documentId === this.selectedId ? service.snapshot : undefined;
    const hash: string = snapshot?.coverage.hash ?? ''; if (hash !== this.reportHash) { this.coverageConsent = false; this.reportHash = hash; this.bodyPage = 0; }
    this.bodyCount = snapshot?.nodes.length ?? 0;
    this.bodyText = snapshot?.nodes.slice(this.bodyPage*8,this.bodyPage*8+8).map((node: DocxNativeNode): string => `${node.kind} ${node.locator.paragraph+1} · ${node.locator.part}\n${node.text}`).join('\n\n') ?? '';
    const issueCodes: string[] = [];
    if (snapshot !== undefined) {
      for (const issue of snapshot.coverage.issues) { if (issueCodes.indexOf(issue.code) < 0) { issueCodes.push(issue.code); } }
    }
    this.report = snapshot === undefined ? '' : `原生支持 ${snapshot.coverage.supported} / 已核 ${snapshot.coverage.matched} / 策略排除 ${snapshot.coverage.excluded} / 局部不支持 ${snapshot.coverage.unsupported} / 歧义 ${snapshot.coverage.ambiguous} / 未对应 ${snapshot.coverage.unmatched}\n`+
      issueCodes.map((code: string): string => `${code} × ${snapshot.coverage.issues.filter((issue: DocxCoverageIssue): boolean => issue.code === code).length}`).join('、')+
      (snapshot.coverage.partial ? '\n部分可用：确认后仅发布已核内容，未对应内容不进入关键词或向量。' : '\n正文结构已准备，请核对后确认发布。');
    this.coverageReady = snapshot !== undefined && service.currentJob?.documentId === this.selectedId && service.currentJob?.stage === DocxStage.Review && service.currentJob?.reportHash === this.reportHash;
    this.vectorProgress = this.embedding?.progress() ?? '';
  }
  aboutToAppear(): void { this.service?.subscribe(this.listener); this.embedding?.subscribe(this.listener); this.service?.refresh().catch((): void => { this.message = 'DOCX资料读取失败，未当作空库'; }); this.update(); }
  aboutToDisappear(): void { this.service?.unsubscribe(this.listener); this.embedding?.unsubscribe(this.listener); this.leave(); }
  private leave(): void { this.clear(); this.service?.pause(); this.embedding?.pause(); }
  private selectDocument(id: string): void { if (this.busy) { return; } this.leave(); this.selectedId = id; this.update(); }
  private async action(resume: boolean): Promise<void> {
    const service: DocxIngestionService | undefined = this.service; if (service === undefined || this.busy) { return; }
    const full: boolean = this.fullFile; const free: boolean = this.free; const revision: string = this.revision; const id: string = this.selectedId; this.clear(); const epoch: number = this.selectionEpoch; this.localPending = true; this.update();
    let failure: string = '';
    try { if (resume) { await service.resume(id,full,free,revision); } else { await service.requestParse(id,full,free,revision); } }
    catch (error) { failure = error instanceof Error ? error.message : 'DOCX动作失败'; }
    finally { this.localPending = false; this.update(); if (epoch === this.selectionEpoch && failure.length > 0) { this.message = failure; } }
  }
  private async prepare(): Promise<void> { if (this.busy) { return; } this.clear(); try { await this.service?.prepareResult(this.selectedId); this.update(); } catch (error) { this.update(); this.message = error instanceof Error ? error.message : '本机准备失败'; } }
  private async publish(): Promise<void> { if (this.busy || !this.coverageConsent || !this.coverageReady) { return; } const report: string = this.reportHash; this.clear(); try { await this.service?.confirmCoverage(report); this.update(); } catch (error) { this.update(); this.message = error instanceof Error ? error.message : '发布失败'; } }
  private canAcceptBasis(): boolean { return !this.busy && this.basisViewed && this.basisBinding === this.embeddingBinding() && this.embedding !== undefined && !this.embedding.state.config.mutationPending && this.embedding.state.config.provider === EmbeddingProvider.SiliconFlow && this.embedding.state.config.modelId === EmbeddingPinnedBasis.model; }
  private async baseline(accept: boolean = false): Promise<void> {
    this.update(); const embedding: EmbeddingService | undefined = this.embedding;
    if (embedding === undefined || this.busy || accept && !this.canAcceptBasis()) { return; }
    const binding: string = this.embeddingBinding(); this.clear(); this.localPending = true; this.update();
    let failure: string = '';
    try {
      if (accept) { await embedding.acceptBaseline(); }
      const basis: EmbeddingBaselineAcceptance = await embedding.baseline();
      if (binding !== this.embeddingBinding()) { throw new Error('BaselineConfigurationChanged'); }
      this.basisBinding = binding; this.basisViewed = true;
      this.basisSummary = `${basis.state}\n当前模型 ${embedding.state.config.modelId} · 配置修订 ${embedding.state.config.revision}\n工程模型 ${basis.model}\nProfile ${basis.profile}\nRevision ${basis.revision}\nTokenizer SHA256 ${basis.tokenizer}\nWeights SHA256 ${basis.weights}\nMetadata SHA256 ${basis.metadata}\n${basis.parameters}\nPolicy ${basis.policy}\n${basis.providerRevision} / ${basis.providerConsistency}\n仅本机工程基线，不证明服务商内部处理一致或免费余额；未授权外发`;
    } catch (error) { failure = error instanceof Error ? error.message : '基线读取或接受失败，未外发'; }
    finally { this.localPending = false; this.update(); if (failure.length > 0) { this.message = failure; } }
  }
  private currentVectorReview(): boolean {
    const service: DocxIngestionService | undefined = this.service; const embedding: EmbeddingService | undefined = this.embedding;
    const document: DocxDocument | undefined = this.documents.find((d: DocxDocument): boolean => d.id === this.selectedId);
    if (service === undefined || embedding === undefined || document === undefined || document.tombstone || document.archived || embedding.state.config.mutationPending || this.revision !== service.authorizationRevision(this.selectedId) || this.configBinding !== this.embeddingBinding()) { return false; }
    const review: EmbeddingDryReview = this.vectorReview; const detection = embedding.state.detection;
    return this.reviewId.length > 0 && this.reviewId === review.setHash && review.documentId === document.id && review.generation === document.activeGeneration && review.configFingerprint === embeddingFingerprint(embedding.state.config) && review.snapshotHash.length > 0 && this.vectorCount > 0 && document.chunkCount === this.vectorCount && review.rows.length === this.vectorCount && review.eligible === this.vectorCount && review.rows.every((row: EmbeddingInputReview): boolean => row.eligible) && embeddingBaselineMatches(review.baseline,embedding.state.config) && embedding.state.credential === EmbeddingCredentialStatus.Configured && detection.status === EmbeddingDetectionStatus.Passed && detection.configFingerprint === review.configFingerprint && detection.credentialRevision === embedding.state.config.credentialRevision && detection.requestedModel === review.model && detection.returnedModel === review.model && detection.dimension > 0;
  }
  private matchingVectorJobs(jobs: EmbeddingJob[], review: EmbeddingDryReview): EmbeddingJob[] {
    const document: DocxDocument | undefined = this.documents.find((d: DocxDocument): boolean => d.id === review.documentId);
    return jobs.filter((job: EmbeddingJob): boolean => document !== undefined && job.documentId === review.documentId && job.contentGeneration === review.generation && job.configFingerprint === review.configFingerprint && job.epoch === document.epoch && job.snapshotHash === review.snapshotHash && [EmbeddingJobStage.Retained,EmbeddingJobStage.Retiring,EmbeddingJobStage.Claimed].indexOf(job.stage) < 0);
  }
  private canVectorize(jobId: string = ''): boolean {
    if (this.busy || this.service?.busy || this.embedding?.state.busy || !this.vectorConsent || !this.vectorFree || !this.vectorEligible || !this.currentVectorReview()) { return false; }
    if (jobId.length === 0) { return this.vectorJobs.length === 0 && !this.vectorFull && !this.resendUnknown; }
    const job: EmbeddingJob | undefined = this.matchingVectorJobs(this.vectorJobs,this.vectorReview).find((j: EmbeddingJob): boolean => j.id === jobId);
    return job !== undefined && (!this.vectorFull || job.completedHashes.length >= Math.min(3,this.vectorCount) && job.completedHashes.length < job.expectedHashes.length);
  }
  private async reviewVector(): Promise<void> {
    this.update();
    const service: DocxIngestionService | undefined = this.service; const embedding: EmbeddingService | undefined = this.embedding;
    if (service === undefined || embedding === undefined || this.busy || this.selectedId.length === 0 || embedding.state.config.mutationPending) { return; } this.clear(); const epoch: number = this.selectionEpoch; const id: string = this.selectedId; const binding: string = this.embeddingBinding(); this.localPending = true; this.update();
    let notice: string = '';
    try {
      const inputs: DocxChunk[] = await service.reviewInputs(id); const review: EmbeddingDryReview = await embedding.dryReview(id); const jobs: EmbeddingJob[] = await embedding.vectorJobs(); await service.refresh();
      if (epoch !== this.selectionEpoch || id !== this.selectedId || binding !== this.embeddingBinding() || review.documentId !== id || review.configFingerprint !== embeddingFingerprint(embedding.state.config) || inputs.length !== review.rows.length || inputs.some((c: DocxChunk,at: number): boolean => c.id !== review.rows[at].chunkId || c.inputHash !== review.rows[at].hash || c.generation !== review.generation)) { throw new Error('DocxReviewChanged'); }
      this.vectorReview = review; this.reviewId = review.setHash; this.allVectorInputs = inputs; this.vectorCount = inputs.length; this.vectorPage = 0; this.vectorInputs = inputs.slice(0,6); this.vectorEligible = this.currentVectorReview();
      this.vectorJobs = this.matchingVectorJobs(jobs,review);
      notice = `已本机审查 ${review.rows.length} 块，合格 ${review.eligible}，未授权外发`;
    } catch (error) { if (epoch === this.selectionEpoch) { this.clear(); } notice = error instanceof Error ? error.message : '文本向量审查失败'; }
    finally { this.localPending = false; this.update(); if (id === this.selectedId) { this.message = notice; } }
  }
  private async vectorize(job: string = ''): Promise<void> {
    this.update(); const embedding: EmbeddingService | undefined = this.embedding; const service: DocxIngestionService | undefined = this.service;
    if (embedding === undefined || service === undefined || !this.canVectorize(job)) { return; }
    const id: string = this.selectedId; const full: boolean = this.vectorFull; const resend: boolean = this.resendUnknown; const epoch: number = this.selectionEpoch; const review: EmbeddingDryReview = this.vectorReview;
    this.localPending = true; this.update(); let notice: string = '';
    try {
      const inputs: DocxChunk[] = await service.reviewInputs(id); await service.refresh(); const jobs: EmbeddingJob[] = await embedding.vectorJobs();
      if (epoch !== this.selectionEpoch || !this.currentVectorReview() || inputs.length !== review.rows.length || inputs.some((c: DocxChunk,at: number): boolean => c.id !== review.rows[at].chunkId || c.inputHash !== review.rows[at].hash || c.generation !== review.generation)) { throw new Error('DocxReviewChanged'); }
      if (!this.vectorConsent || !this.vectorFree || full !== this.vectorFull || resend !== this.resendUnknown) { throw new Error('DocxVectorConfirmationChanged'); }
      this.vectorJobs = this.matchingVectorJobs(jobs,review);
      if (job.length === 0 && this.vectorJobs.length > 0) { throw new Error('ExistingVectorJobRequiresResume'); }
      const resumed: EmbeddingJob | undefined = this.vectorJobs.find((j: EmbeddingJob): boolean => j.id === job);
      if (job.length > 0 && (resumed === undefined || full && (resumed.completedHashes.length < Math.min(3,inputs.length) || resumed.completedHashes.length >= resumed.expectedHashes.length))) { throw new Error('CurrentSameVectorJobRequired'); }
      if (service.busy || embedding.state.busy) { throw new Error('DocxVectorBusy'); }
      this.clear(); await embedding.vectorizePdf(id,true,true,job,resend,full); notice = embedding.state.message;
    } catch (error) { this.clear(); notice = error instanceof Error ? error.message : '向量动作失败，检查点保留'; }
    finally { this.localPending = false; this.update(); if (id === this.selectedId) { this.message = notice; } }
  }
  private manage(action: string): void {
    const service: DocxIngestionService | undefined = this.service; if (service === undefined || this.selectedId.length === 0) { return; }
    const id: string = this.selectedId; this.clear();
    if (action === 'delete') { AlertDialog.show({ title: '删除DOCX本机资料', message: '先撤索引资格，再等待读持有与owner分阶段清理。不会删除云端资料；历史保留为失效快照。', primaryButton: { value: '取消', action: (): void => {} }, secondaryButton: { value: '确认删除', action: (): void => { service.deleteDocument(id,true).catch((error: Error): void => { this.message = error.message; }); } } }); }
    else if (action === 'replace') { service.replace(id).catch((error: Error): void => { this.message = error.message; }); }
    else if (action === 'archive') { const d: DocxDocument | undefined = this.documents.find((doc: DocxDocument): boolean => doc.id === id); if (d !== undefined) { service.archive(id,!d.archived).catch((error: Error): void => { this.message = error.message; }); } }
  }
  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Button('返回').id('docx-back').onClick((): void => { this.leave(); this.onBack(); })
        Text('DOCX解析与入库').fontSize(20).layoutWeight(1)
        Button('解析设置').id('docx-parse-settings').onClick((): void => { this.leave(); this.onParseSettings(); })
      }.width('100%')
      Text(this.message).id('docx-status').width('100%')
      Column({ space: 12 }) {
      Button('选择DOCX').id('docx-select').enabled(!this.busy).onClick((): void => { this.clear(); this.service?.importFiles(); })
      ForEach(this.documents.slice(this.documentPage*12,this.documentPage*12+12), (document: DocxDocument) => {
        Button(document.title+' · '+document.stage).id('docx-document-'+document.id).enabled(!this.busy).onClick((): void => { this.selectDocument(document.id); })
      }, (document: DocxDocument): string => document.id)
      Row({ space: 8 }) {
        Button('上一组文件').enabled(this.documentPage > 0).onClick((): void => { this.documentPage--; })
        Text(`${this.documentPage+1}/${Math.max(1,Math.ceil(this.documents.length/12))}`)
        Button('下一组文件').enabled((this.documentPage+1)*12 < this.documents.length).onClick((): void => { this.documentPage++; })
      }
      }.id('docx-workflow-documents').width('100%').alignItems(HorizontalAlign.Start)
      Column({ space: 12 }) {
       Text(this.progress).id('docx-parse-progress').width('100%')
      Text(this.selectedIdentity).width('100%').wordBreak(WordBreak.BREAK_ALL)
      Row() {
        Checkbox().select(this.fullFile).id('docx-fullfile').onChange((selected: boolean): void => { this.fullFile = selected; })
        Text('同意发送当前完整原件，含隐藏内容、修订、批注及辅助部件').layoutWeight(1)
      }
      Row() {
        Checkbox().select(this.free).id('docx-parse-free').onChange((selected: boolean): void => { this.free = selected; })
        Text('已确认本次免费资格').layoutWeight(1)
      }
      Row({ space: 8 }) {
        Button('开始解析').id('docx-parse-start').enabled(!this.busy && this.selectedId.length > 0 && this.fullFile && this.free).onClick((): void => { this.action(false); })
        Button('恢复原任务').id('docx-parse-resume').enabled(!this.busy && this.selectedId.length > 0 && this.fullFile && this.free).onClick((): void => { this.action(true); })
      }
      Button('读取已收ZIP并准备原生结构').id('docx-prepare-result').enabled(!this.busy && this.selectedId.length > 0).onClick((): void => { this.prepare(); })
      }.id('docx-workflow-parse').width('100%').alignItems(HorizontalAlign.Start)
      Column({ space: 12 }) {
      Text(this.report).id('docx-report').width('100%')
      Text(this.bodyText).id('docx-body').width('100%').copyOption(CopyOptions.InApp)
      Row({ space: 8 }) {
        Button('上一组正文').enabled(this.bodyPage > 0).onClick((): void => { this.bodyPage--; this.update(); })
        Text(`${this.bodyPage+1} / ${Math.max(1,Math.ceil(this.bodyCount/8))}`)
        Button('下一组正文').enabled((this.bodyPage+1)*8 < this.bodyCount).onClick((): void => { this.bodyPage++; this.update(); })
      }
       Row() {
         Checkbox().select(this.coverageConsent).id('docx-coverage-consent').onChange((selected: boolean): void => { this.coverageConsent = selected; })
         Text('确认当前正文和覆盖报告，仅发布已核原生块').layoutWeight(1)
       }
       if (this.coverageReady) {
         Text('正文结构报告已就绪，勾选上方确认后可发布已核内容。').id('docx-publish-ready').width('100%')
       } else {
         Text('尚无待发布的当前报告；请先读取已收 ZIP，或当前版本已经发布。').id('docx-publish-waiting').width('100%')
       }
       Button('发布关键词').id('docx-publish-keyword').enabled(!this.busy && this.coverageReady && this.reportHash.length > 0 && this.coverageConsent).onClick((): void => { this.publish(); })
      Button('查看原生来源').id('docx-open-source').enabled(!this.busy && this.selectedId.length > 0).onClick((): void => { this.leave(); this.onSource(this.selectedId); })
      Button('检索已入库内容').id('docx-open-search').enabled(!this.busy).onClick((): void => { this.leave(); this.onSearch(); })
      }.id('docx-workflow-coverage').width('100%').alignItems(HorizontalAlign.Start)
      Column({ space: 12 }) {
      Button('嵌入设置').id('docx-embedding-settings').onClick((): void => { this.leave(); this.onEmbeddingSettings(); })
      Button('本机查看当前工程基线').id('docx-baseline-read').enabled(!this.busy).onClick((): void => { this.baseline(); })
      Text(this.basisSummary).id('docx-baseline-summary').width('100%').wordBreak(WordBreak.BREAK_ALL)
      Button('显式接受当前工程基线').id('docx-baseline-accept').enabled(this.canAcceptBasis()).onClick((): void => { this.baseline(true); })
      Button('本机审查实际向量输入').id('docx-vector-review').enabled(!this.busy && this.selectedId.length > 0).onClick((): void => { this.reviewVector(); })
      if (this.vectorCount > 0) {
        Text(`${this.vectorReview.recipient}\nModel ${this.vectorReview.model} · ${this.vectorReview.baseline.state}\n审查 ${this.vectorCount} 块 / eligible ${this.vectorReview.eligible} / safe ${this.vectorReview.safe} / unproven ${this.vectorReview.unproven} / invalid ${this.vectorReview.invalid}\n累计上界 ${this.vectorReview.totalBound} / 单块最大 ${this.vectorReview.maxBound}\n集合 ${this.vectorReview.setHash}`).id('docx-vector-review-summary').width('100%').wordBreak(WordBreak.BREAK_ALL)
      }
      Text(this.vectorProgress).width('100%')
      ForEach(this.vectorInputs,(chunk: DocxChunk) => { Text(`${chunk.ordinal+1}/${this.vectorCount}\n${chunk.embeddingText}`).width('100%') },(chunk: DocxChunk): string => chunk.id)
      Row({ space: 8 }) {
        Button('上一组输入').enabled(this.vectorPage > 0).onClick((): void => { this.vectorConsent = false; this.vectorFree = false; this.vectorPage--; this.vectorInputs = this.allVectorInputs.slice(this.vectorPage*6,this.vectorPage*6+6); })
        Button('下一组输入').enabled((this.vectorPage+1)*6 < this.vectorCount).onClick((): void => { this.vectorConsent = false; this.vectorFree = false; this.vectorPage++; this.vectorInputs = this.allVectorInputs.slice(this.vectorPage*6,this.vectorPage*6+6); })
      }
      Row() {
        Checkbox().select(this.vectorConsent).id('docx-vector-consent').onChange((selected: boolean): void => { this.vectorConsent = selected; })
        Text('仅同意本次已审查文本外发，不发送DOCX或图片').layoutWeight(1)
      }
      Row() {
        Checkbox().select(this.vectorFree).id('docx-vector-free').onChange((selected: boolean): void => { this.vectorFree = selected; })
        Text('确认本次文本向量免费资格').layoutWeight(1)
      }
      Row() {
        Checkbox().select(this.vectorFull).id('docx-vector-full').onChange((selected: boolean): void => { this.vectorFull = selected; this.vectorConsent = false; this.vectorFree = false; })
        Text('首三块已核后，另行授权同任务全部剩余输入').layoutWeight(1)
      }
      Row() {
        Checkbox().select(this.resendUnknown).id('docx-vector-resend').onChange((selected: boolean): void => { this.resendUnknown = selected; this.vectorConsent = false; })
        Text('读回优先；仅同意Unknown缺失输入再次可能计费').layoutWeight(1)
      }
       Button('向量化首三块').id('docx-vector-start').enabled(this.canVectorize()).onClick((): void => { this.vectorize(); })
       ForEach(this.vectorJobs,(job: EmbeddingJob) => { Button(`同任务续跑 ${job.stage} ${job.completedHashes.length}/${job.expectedHashes.length}`).id('docx-vector-resume-'+job.id).enabled(this.canVectorize(job.id)).onClick((): void => { this.vectorize(job.id); }) },(job: EmbeddingJob): string => job.id)
      }.id('docx-workflow-vectors').width('100%').alignItems(HorizontalAlign.Start)
      Column({ space: 12 }) {
      Row({ space: 8 }) {
        Button('选择新版本').id('docx-replace').enabled(!this.busy).onClick((): void => { this.manage('replace'); })
        Button('归档 / 恢复').id('docx-archive').enabled(!this.busy).onClick((): void => { this.manage('archive'); })
        Button('删除').id('docx-delete').enabled(!this.busy).onClick((): void => { this.manage('delete'); })
      }
      Button('重试待清理').id('docx-cleanup-retry').onClick((): void => { this.service?.retryCleanup().catch((error: Error): void => { this.message = error.message; }); })
      ForEach(this.candidateJobs,(job: DocxJob) => {
        Text(`${job.stage} · ${job.failure}`).width('100%')
        Button('放弃此本机候选').id('docx-abandon-'+job.id).enabled(!this.busy).onClick((): void => { this.clear(); this.service?.abandon(job.id).catch((error: Error): void => { this.message = error.message; }); })
      },(job: DocxJob): string => job.id)
      }.id('docx-workflow-manage').width('100%').alignItems(HorizontalAlign.Start)
    }.padding(16).width('100%').alignItems(HorizontalAlign.Start)
  }
}
