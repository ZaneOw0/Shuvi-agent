import { ImageIngestionService } from '../application/ImageIngestionService';
import { ImageDocument, ImageJob, ImageChunk, ImageIngestionStage, ImageOcrBlock } from '../domain/ImageKnowledgeModels';
import { KnowledgeCallbackListener } from '../domain/KnowledgePorts';
import { EmbeddingService } from '../application/EmbeddingService';
import { EmbeddingJob, EmbeddingJobStage } from '../domain/EmbeddingModels';
import { EmbeddingDryReview, EmbeddingInputReview } from '../domain/EmbeddingBasisModels';
import { embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { Theme } from '../../components/Theme';

@Component
export struct ImageIngestionView {
  service: ImageIngestionService | undefined = undefined;
  embedding: EmbeddingService | undefined = undefined;
  onBack: () => void = (): void => {};
  onOriginal: (document: ImageDocument) => void = (_document: ImageDocument): void => {};
  onParseSettings: () => void = (): void => {};
  onEmbeddingSettings: () => void = (): void => {};
  @State private rows: ImageDocument[] = [];
  @State private jobRows: ImageJob[] = [];
  @State private pageNumber: number = 0;
  @State private totalRows: number = 0;
  @State private selectedId: string = '';
  @State private currentDocument: ImageDocument = new ImageDocument();
  @State private selectedTitle: string = '';
  @State private selectedSummary: string = '';
  @State private selectedBinding: string = '';
  @State private message: string = '';
  @State private busy: boolean = false;
  @State private reportHash: string = '';
  @State private report: string = '';
  @State private canPublish: boolean = false;
  @State private coverageConsent: boolean = false;
  @State private parseFullFile: boolean = false;
  @State private parseFree: boolean = false;
  @State private parseProgress: string = '';
  @State private bodyText: string = '';
  @State private bodyPage: number = 0;
  @State private bodyLength: number = 0;
  @State private vectorReady: boolean = false;
  @State private vectorReview: EmbeddingDryReview = new EmbeddingDryReview();
  @State private vectorRows: EmbeddingInputReview[] = [];
  @State private vectorPage: number = 0;
  @State private vectorJobs: EmbeddingJob[] = [];
  @State private vectorStatus: string = '';
  @State private vectorProgress: string = '';
  @State private vectorConsent: boolean = false;
  @State private vectorFree: boolean = false;
  @State private fullScope: boolean = false;
  @State private resendUnknown: boolean = false;
  private vectorTexts: ImageChunk[] = [];
  private configBinding: string = '';
  private documentBinding: string = '';
  private selectionEpoch: number = 0;
  private alive: boolean = false;
  private reviewIdentity: string = '';
  private localBusy: boolean = false;
  private listener: KnowledgeCallbackListener = new KnowledgeCallbackListener((): void => { this.update(); });

  private clearVector(): void {
    this.vectorConsent = false; this.vectorFree = false; this.fullScope = false; this.resendUnknown = false;
    this.vectorReview = new EmbeddingDryReview(); this.vectorRows = []; this.vectorTexts = []; this.vectorJobs = [];
  }
  private clearApproval(): void {
    this.selectionEpoch++; this.parseFullFile = false; this.parseFree = false; this.coverageConsent = false;
    this.clearVector();
  }
  private selectDocument(document: ImageDocument): void {
    if (this.busy) { return; }
    this.clearApproval(); this.service?.pause(); this.embedding?.pause(); this.selectedId = document.id;
    this.selectedBinding = document.parseBinding; this.bodyPage = 0; this.update();
  }
  private async importImages(): Promise<void> {
    if (this.busy) { return; } this.clearApproval(); this.localBusy = true; this.update();
    try { await this.service?.importFiles(); } finally { this.localBusy = false; this.update(); }
  }
  private async parseCurrent(): Promise<void> {
    if (this.busy || this.selectedId.length === 0) { return; }
    const id: string = this.selectedId; const binding: string = this.selectedBinding;
    const revision: string = this.service?.authorizationRevision() ?? '';
    const full: boolean = this.parseFullFile; const free: boolean = this.parseFree;
    this.clearApproval(); this.bodyPage = 0; this.localBusy = true; this.update();
    try { await this.service?.requestOcr(id,full,free,binding,revision); } finally { this.localBusy = false; this.update(); }
  }
  private async publish(): Promise<void> {
    if (!this.coverageConsent || !this.canPublish || this.busy) { return; }
    const hash: string = this.reportHash; this.clearApproval(); await this.service?.confirmCoverage(hash); this.update();
  }
  private async countVector(): Promise<void> {
    if (this.busy || !this.vectorReady || this.embedding === undefined || this.service === undefined) { return; }
    this.clearVector(); const epoch: number = ++this.selectionEpoch; const id: string = this.selectedId;
    this.localBusy = true; this.update();
    try {
      const texts: ImageChunk[] = await this.service.reviewInputs(id);
      const review: EmbeddingDryReview = await this.embedding.dryReview(id);
      const jobs: EmbeddingJob[] = await this.embedding.vectorJobs();
      if (!this.alive || epoch !== this.selectionEpoch || id !== this.selectedId) { return; }
      if (texts.length !== review.rows.length || texts.some((chunk: ImageChunk): boolean => !review.rows.some((row: EmbeddingInputReview): boolean => row.chunkId === chunk.id && row.hash === chunk.inputHash))) { throw new Error('ImageReviewChanged'); }
      this.vectorTexts = texts; this.vectorReview = review; this.vectorPage = 0; this.vectorRows = review.rows.slice(0,6);
      this.vectorJobs = jobs.filter((job: EmbeddingJob): boolean => job.documentId === id && job.contentGeneration === review.generation && job.configFingerprint === review.configFingerprint && [EmbeddingJobStage.Retained,EmbeddingJobStage.Retiring,EmbeddingJobStage.Claimed].indexOf(job.stage) < 0);
      this.vectorStatus = '本机审查完成，尚未授权外发';
    } catch { this.clearVector(); this.vectorStatus = '本机输入审查未完成，未授权外发；请核对已发布正文与嵌入设置'; }
    finally { this.localBusy = false; this.update(); }
  }
  private async vectorize(resumeId: string = ''): Promise<void> {
    if (this.busy || !this.vectorReady || this.vectorReview.documentId !== this.selectedId || !this.vectorConsent || !this.vectorFree) { return; }
    const id: string = this.selectedId; const consent: boolean = this.vectorConsent; const free: boolean = this.vectorFree;
    const resend: boolean = this.resendUnknown; const full: boolean = this.fullScope;
    this.clearVector(); this.localBusy = true; this.update();
    try { await this.embedding?.vectorizePdf(id,consent,free,resumeId,resend,full); this.vectorStatus = this.embedding?.state.message ?? '向量服务不可用'; }
    finally { this.localBusy = false; this.update(); }
    await this.refreshJobs();
  }
  private async refreshJobs(): Promise<void> {
    const epoch: number = this.selectionEpoch; const id: string = this.selectedId;
    try { const jobs: EmbeddingJob[] = await this.embedding?.vectorJobs() ?? []; if (this.alive && epoch === this.selectionEpoch) { this.vectorJobs = jobs.filter((job: EmbeddingJob): boolean => job.documentId === id); } }
    catch { this.vectorStatus = '向量任务读回未确认，未冒称完成'; }
  }
  private canFullScope(): boolean {
    return this.vectorJobs.some((job: EmbeddingJob): boolean => job.documentId === this.vectorReview.documentId && job.contentGeneration === this.vectorReview.generation && job.completedHashes.length >= Math.min(3,this.vectorReview.rows.length) && job.completedHashes.length < job.expectedHashes.length);
  }
  private inputText(chunkId: string): string { return this.vectorTexts.find((chunk: ImageChunk): boolean => chunk.id === chunkId)?.text ?? ''; }
  private pageVector(delta: number): void { this.vectorPage = Math.max(0,this.vectorPage+delta); this.vectorRows = this.vectorReview.rows.slice(this.vectorPage*6,this.vectorPage*6+6); }
  private async retryReleases(): Promise<void> { try { await this.embedding?.retryReleases(); this.vectorStatus = '读租约释放已确认'; } catch { this.vectorStatus = '读租约释放仍未确认，保持暂停'; } }
  private confirmDelete(document: ImageDocument): void {
    this.clearApproval();
    AlertDialog.show({ title: '删除图片资料', message: '本机索引立即隐藏，历史保留失效文本；原件等待安全释放后清理，不表示云端删除。',
      primaryButton: { value: '取消', action: (): void => {} }, secondaryButton: { value: '确认删除', action: (): void => { this.service?.deleteDocument(document.id,true); } } });
  }
  private update(): void {
    const documents: ImageDocument[] = this.service?.documents ?? [];
    const incoming: string = this.service?.review?.contentHash ?? '';
    if (incoming.length > 0 && incoming !== this.reviewIdentity) { this.selectedId = this.service?.review?.documentId ?? ''; }
    this.reviewIdentity = incoming;
    this.totalRows = documents.length; this.rows = documents.slice(this.pageNumber*12,this.pageNumber*12+12);
    const selected = documents.find((document: ImageDocument): boolean => document.id === this.selectedId);
    const config: string = (this.service?.authorizationRevision() ?? '')+'|'+(this.embedding === undefined ? '' : embeddingFingerprint(this.embedding.state.config)+`|${this.embedding.state.inputEpoch}|${this.embedding.state.detection.status}|${this.embedding.state.detection.observedAt}`);
    const binding: string = selected === undefined ? '' : `${selected.parseBinding}|${selected.activeGeneration}|${selected.epoch}|${selected.archived}|${selected.tombstone}`;
    if (config !== this.configBinding || binding !== this.documentBinding) { this.clearApproval(); this.configBinding = config; this.documentBinding = binding; }
    if (this.vectorReview.generation.length > 0 && this.vectorReview.generation !== selected?.activeGeneration) { this.clearVector(); }
    this.selectedBinding = selected?.parseBinding ?? ''; this.selectedTitle = selected?.title ?? ''; this.selectedSummary = selected?.originalSummary ?? '';
    this.currentDocument = selected ?? new ImageDocument();
    this.busy = this.localBusy || (this.service?.actionBusy() ?? false) || (this.embedding?.state.busy ?? false);
    this.message = this.service?.message ?? '图片服务不可用，未执行外发';
    this.parseProgress = this.selectedId.length > 0 ? this.service?.parseSummary(this.selectedId) ?? '' : '';
    this.jobRows = this.service?.jobRows.filter((job: ImageJob): boolean => job.documentId === this.selectedId && job.originalAssetId.length > 0 && binding.includes('|'+job.originalAssetId+'|')).slice(0,12) ?? [];
    const review = this.service?.review; const current: boolean = review !== undefined && review.documentId === this.selectedId && this.selectedBinding.includes('|'+review.original.assetId+'|');
    const hash: string = current ? review?.coverage.hash ?? '' : ''; if (hash !== this.reportHash) { this.clearApproval(); this.bodyPage = 0; } this.reportHash = hash;
    this.report = !current || review === undefined ? '' : `${review.projection.member.length > 0 ? '包摘要、ZIP 目录基本保护及正文成员 CRC / SHA256 已核' : '隔离受控报告，不是实云 ZIP 校验证据'}\n正文成员 ${review.projection.member || '隔离受控报告'} · 段落 ${review.coverage.identified} / 明确无字 ${review.coverage.empty}\n仅正文文本投影；未核所有成员 CRC，不含原生表格、像素框或视觉理解`;
    const text: string = current ? review?.projection.text || review?.blocks.map((block: ImageOcrBlock): string => block.text).join('\n\n') || '' : '';
    this.bodyLength = text.length; this.bodyText = text.slice(this.bodyPage*4000,(this.bodyPage+1)*4000);
    this.canPublish = current && selected !== undefined && !selected.archived && !selected.tombstone && selected.activeGeneration !== review?.generation;
    this.vectorReady = selected !== undefined && !selected.archived && !selected.tombstone && selected.stage === ImageIngestionStage.Published && selected.chunkCount > 0 && this.selectedBinding.includes('|'+selected.activeOriginal+'|');
    this.vectorProgress = this.embedding?.progress() ?? '向量服务不可用';
  }
  aboutToAppear(): void { this.alive = true; this.service?.subscribe(this.listener); this.embedding?.subscribe(this.listener); this.selectedId = this.service?.review?.documentId ?? ''; this.update(); }
  aboutToDisappear(): void { this.alive = false; this.clearApproval(); this.service?.unsubscribe(this.listener); this.embedding?.unsubscribe(this.listener); this.embedding?.pause(); this.service?.pause(); }
  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) { Button('返回').id('m3-image-back').onClick(this.onBack); Text('图片解析与入库').fontSize(20).layoutWeight(1) }.width('100%')
      Text(this.message).id('m3-image-status').fontSize(13).width('100%')
      Text('1. 选择图片').fontWeight(FontWeight.Medium).width('100%')
      Button('选择图片').id('m3-image-select').enabled(!this.busy && this.service !== undefined).onClick((): void => { this.importImages(); })
      Text('JPG / JPEG / PNG / 静态 WebP · 每次最多 3 张 · 单张 20 MiB / 2000 万像素').fontSize(12).fontColor(Theme.muted).width('100%')
      ForEach(this.rows, (document: ImageDocument) => {
        Column({ space: 6 }) {
          Button((this.selectedId === document.id ? '当前：' : '选择：')+document.title).id('image-select-'+document.id).width('100%').enabled(!this.busy && !document.tombstone).onClick((): void => { this.selectDocument(document); })
          Text(`${document.stage} · 关键词 ${document.chunkCount} 块${document.archived ? ' · 已归档' : ''}`).fontSize(12).width('100%')
        }.width('100%').padding({ top: 8, bottom: 8 }).border({ width: { bottom: 1 }, color: Theme.line })
      }, (document: ImageDocument): string => `${document.id}:${document.epoch}:${document.stage}:${document.activeGeneration}:${document.parseBinding}:${document.archived}:${document.tombstone}`)
      Row({ space: 8 }) { Button('上一页').enabled(!this.busy && this.pageNumber > 0).onClick((): void => { this.clearApproval(); this.pageNumber--; this.update(); }); Text(`${this.pageNumber+1}`); Button('下一页').enabled(!this.busy && (this.pageNumber+1)*12 < this.totalRows).onClick((): void => { this.clearApproval(); this.pageNumber++; this.update(); }) }
      if (this.selectedId.length > 0) {
        Text(this.selectedTitle).fontSize(16).width('100%')
        Text(this.selectedSummary).fontSize(12).width('100%')
        Row({ space: 8 }) {
          Button('原图').id('m3-image-source-'+this.selectedId).enabled(!this.busy && !this.currentDocument.tombstone).onClick((): void => { this.onOriginal(this.currentDocument); })
          Button(this.currentDocument.archived ? '恢复' : '归档').id('m3-image-archive-'+this.selectedId).enabled(!this.busy && !this.currentDocument.tombstone).onClick((): void => { this.clearApproval(); this.service?.archive(this.selectedId,!this.currentDocument.archived); })
          Button('删除').id('m3-image-delete-'+this.selectedId).enabled(!this.busy && !this.currentDocument.tombstone).onClick((): void => { this.confirmDelete(this.currentDocument); })
        }.width('100%')
        Button('选择替换原件').id('m3-image-replace-'+this.selectedId).enabled(!this.busy && !this.currentDocument.tombstone && !this.currentDocument.archived).onClick((): void => { this.clearApproval(); this.service?.replaceOriginal(this.selectedId); })
        Text('2. 解析与 ZIP').fontWeight(FontWeight.Medium).width('100%')
        Row({ space: 8 }) { Checkbox().id('image-happy-full-file').select(this.parseFullFile).enabled(!this.busy).onChange((checked: boolean): void => { this.parseFullFile = checked; }); Text('同意当前所选图片的完整文件和元数据发送给 MinerU；留存、删除及转处理条件未知').fontSize(13).layoutWeight(1) }.width('100%')
        Row({ space: 8 }) { Checkbox().id('image-happy-free').select(this.parseFree).enabled(!this.busy).onChange((checked: boolean): void => { this.parseFree = checked; }); Text('确认当前同账号本次免费资格，不授权收费').fontSize(13).layoutWeight(1) }.width('100%')
        Text('vlm · is_ocr=false · table/formula=true · ch · 单图 POST1 / PUT1 / 查询90 / ZIP1；恢复只用原任务，已收包仅本机读取').fontSize(12).fontColor(Theme.muted).width('100%')
        Button('解析 / 查询 / 读取正文').id('image-parse-current').width('100%').fontSize(14).enabled(!this.busy && !this.currentDocument.archived && !this.currentDocument.tombstone).onClick((): void => { this.parseCurrent(); })
        Button('MinerU 设置与任务').id('image-parse-settings').enabled(!this.busy).onClick(this.onParseSettings)
        Text(this.parseProgress).id('image-happy-ledger').fontSize(12).width('100%').wordBreak(WordBreak.BREAK_ALL)
        Text('3. 正文审查与关键词').fontWeight(FontWeight.Medium).width('100%')
        Text(this.report).id('m3-image-coverage').fontSize(12).width('100%')
        if (this.bodyLength > 0) {
          Text(this.bodyText).id('image-happy-body').fontSize(14).width('100%')
          Row({ space: 8 }) { Button('正文上页').id('image-happy-body-prev').enabled(this.bodyPage > 0).onClick((): void => { this.bodyPage--; this.update(); }); Text(`${this.bodyPage+1}/${Math.ceil(this.bodyLength/4000)}`); Button('正文下页').id('image-happy-body-next').enabled((this.bodyPage+1)*4000 < this.bodyLength).onClick((): void => { this.bodyPage++; this.update(); }) }
        }
        ForEach(this.jobRows, (job: ImageJob) => { Button('恢复本机报告 '+job.stage).id('m3-image-resume-'+job.id).enabled(!this.busy && job.stage !== ImageIngestionStage.Published && job.stage !== ImageIngestionStage.Empty).onClick((): void => { this.clearApproval(); this.service?.resumeReview(job.id); }) }, (job: ImageJob): string => `${job.id}:${job.stage}`)
        if (this.canPublish) {
          Row({ space: 8 }) { Checkbox().id('image-coverage-consent').select(this.coverageConsent).enabled(!this.busy).onChange((checked: boolean): void => { this.coverageConsent = checked; }); Text('已核对当前正文和覆盖限制，仅确认关键词发布，不授权向量化').fontSize(13).layoutWeight(1) }.width('100%')
          Button('确认正文，发布关键词').id('m3-image-confirm-coverage').enabled(!this.busy && this.coverageConsent).onClick((): void => { this.publish(); })
        }
        Text('4. 独立授权 OCR 文本向量入库').fontWeight(FontWeight.Medium).width('100%')
        Button('仅本机审查全部 OCR 输入').id('image-vector-review').enabled(!this.busy && this.vectorReady).onClick((): void => { this.countVector(); })
        Button('嵌入模型设置').id('image-vector-settings').enabled(!this.busy).onClick(this.onEmbeddingSettings)
        Text(this.vectorStatus).id('image-vector-status').fontSize(13).width('100%')
        Text(this.vectorProgress).id('image-vector-progress').fontSize(13).width('100%')
        if (this.vectorReview.rows.length > 0) {
          Text(`${this.vectorReview.recipient}\n${this.vectorReview.model} · ${this.vectorReview.baseline.state}\n审查 ${this.vectorReview.rows.length} 块 / 合格 ${this.vectorReview.eligible} / 未证上界 ${this.vectorReview.unproven} / 无效 ${this.vectorReview.invalid}\n累计上界 ${this.vectorReview.totalBound} / 单块最大 ${this.vectorReview.maxBound}`).id('image-vector-review-summary').fontSize(12).width('100%')
          ForEach(this.vectorRows, (row: EmbeddingInputReview) => { Column({ space: 4 }) { Text(`#${row.ordinal+1} · ${row.state} · 上界 ${row.bound} · ${row.attemptState}`).fontSize(12).width('100%'); Text(this.inputText(row.chunkId)).fontSize(13).width('100%') }.width('100%') }, (row: EmbeddingInputReview): string => row.chunkId+row.attemptState)
          Row({ space: 8 }) { Button('上组输入').enabled(this.vectorPage > 0).onClick((): void => { this.pageVector(-1); }); Text(`${this.vectorPage+1}/${Math.ceil(this.vectorReview.rows.length/6)}`); Button('下组输入').enabled((this.vectorPage+1)*6 < this.vectorReview.rows.length).onClick((): void => { this.pageVector(1); }) }
          Row({ space: 8 }) { Checkbox().id('image-vector-full-scope').select(this.fullScope).enabled(!this.busy && this.canFullScope()).onChange((checked: boolean): void => { this.fullScope = checked; this.vectorConsent = false; this.vectorFree = false; }); Text('前三块核验后，独立授权同一任务的全部剩余已审查文本；不选则最多 3 个未核输入').fontSize(13).layoutWeight(1) }.width('100%')
          Row({ space: 8 }) { Checkbox().id('image-vector-consent').select(this.vectorConsent).enabled(!this.busy && this.vectorReview.eligible === this.vectorReview.rows.length).onChange((checked: boolean): void => { this.vectorConsent = checked; }); Text(this.fullScope ? '同意本次全部剩余已审查 OCR 文本外发用于向量入库，不发原图，不授权问题' : '仅同意本次最多 3 个已审查未核 OCR 文本外发用于向量入库，不发原图，不授权问题').fontSize(13).layoutWeight(1) }.width('100%')
          Row({ space: 8 }) { Checkbox().id('image-vector-free').select(this.vectorFree).enabled(!this.busy).onChange((checked: boolean): void => { this.vectorFree = checked; }); Text('独立确认本次向量请求免费资格，窗口 15 分钟；不从解析许可继承').fontSize(13).layoutWeight(1) }.width('100%')
          Row({ space: 8 }) { Checkbox().id('image-vector-resend-unknown').select(this.resendUnknown).enabled(!this.busy).onChange((checked: boolean): void => { this.resendUnknown = checked; this.vectorConsent = false; this.vectorFree = false; }); Text('仅显式续跑：接受 Unknown 可能已计费，允许再次发送本次范围内未核输入；已核不重发').fontSize(13).layoutWeight(1) }.width('100%')
          Button('开始 OCR 文本向量化').id('image-vector-start').enabled(!this.busy && this.vectorConsent && this.vectorFree && this.vectorJobs.length === 0).onClick((): void => { this.vectorize(); })
        }
        ForEach(this.vectorJobs, (job: EmbeddingJob) => {
          Column({ space: 4 }) {
            Text(`${job.stage} · 已核 ${job.completedHashes.length}/${job.expectedHashes.length}${job.completedHashes.length < job.expectedHashes.length ? ' · 尚未完整入库' : ' · 以完整读回发布状态为准'}\n${job.failure}`).fontSize(13).width('100%')
            Button('显式续跑同一任务').id('image-vector-resume-'+job.id).enabled(!this.busy && this.vectorConsent && this.vectorFree && this.vectorReview.documentId === job.documentId && this.vectorReview.generation === job.contentGeneration && job.stage !== EmbeddingJobStage.Retained && job.stage !== EmbeddingJobStage.Retiring).onClick((): void => { this.vectorize(job.id); })
          }.width('100%')
        }, (job: EmbeddingJob): string => `${job.id}:${job.stage}:${job.completedHashes.length}`)
      }
      Button('暂停本机动作').id('image-entry-pause').onClick((): void => { this.clearApproval(); this.embedding?.pause(); this.service?.pause(); })
      Button('重试读租约释放').id('image-vector-release-retry').enabled(!this.busy).onClick((): void => { this.retryReleases(); })
      Button('重试待清理').id('m3-image-cleanup-retry').enabled(!this.busy).onClick((): void => { this.service?.retryCleanup(); })
      Button('重试解码资源释放').id('m3-image-release-retry').enabled(!this.busy).onClick((): void => { this.service?.retryRelease(); })
    }.padding({ top: 12, bottom: 24 }).width('100%').alignItems(HorizontalAlign.Start)
  }
}
