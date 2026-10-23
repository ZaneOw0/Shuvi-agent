import { Theme } from '../../components/Theme';
import { PdfIngestionService } from '../application/PdfIngestionService';
import { KnowledgeCallbackListener } from '../domain/KnowledgePorts';
import { PdfCoverageIssue, PdfIngestionJob } from '../domain/PdfKnowledgeModels';
import { KnowledgeDerivedLifecycle } from '../application/KnowledgeLifecycleService';

@Component
export struct PdfIngestionView {
  service: PdfIngestionService | undefined = undefined;
  lifecycle: KnowledgeDerivedLifecycle | undefined = undefined;
  onBack: () => void = (): void => {};
  @State stageLabel: string = 'ReceivedUnvalidated';
  @State message: string = '';
  @State busy: boolean = false;
  @State issues: PdfCoverageIssue[] = [];
  @State partialConfirmed: boolean = false;
  @State reportHash: string = '';
  @State jobs: PdfIngestionJob[] = [];
  @State evidence: string = '';
  @State jobOffset: number = 0; @State issueOffset: number = 0;
  private listener: KnowledgeCallbackListener = new KnowledgeCallbackListener((): void => { this.changed(); });
  private async abandon(): Promise<void> { const id: string = this.service?.state.job?.id ?? ''; if (id.length === 0) { return; } try { await this.lifecycle?.abandon(id); await this.service?.refreshJobs(); this.message = '未发布检查点已放弃；原件与旧活动保留'; } catch { this.message = '放弃或清理未完成，可重试派生清理'; } }
  aboutToAppear(): void { this.service?.subscribe(this.listener); this.changed(); this.service?.refreshJobs(); }
  aboutToDisappear(): void { this.service?.unsubscribe(this.listener); this.partialConfirmed = false; }
  changed(): void {
    if (this.service === undefined) { this.message = 'PDF 入库能力不可用，原件和 ZIP 保留'; return; }
    this.stageLabel = this.service.state.stage; this.message = this.service.state.message; this.busy = this.service.state.busy || this.service.state.releasing;
    const hash: string = this.service.state.report?.hash ?? ''; if (hash !== this.reportHash) { this.partialConfirmed = false; } this.reportHash = hash;
    this.issues = this.service.state.report?.issues.slice(this.issueOffset,this.issueOffset+12) ?? [];
    this.jobs = this.service.pendingJobs.slice(this.jobOffset,this.jobOffset+8);
    this.evidence = `native ${this.service.state.nativeMembers} CRC · ${this.service.state.nativeExpanded} B · images ${this.service.state.decodedImages} · snapshot ${this.service.state.snapshotId} · report ${hash}`;
  }
  build() {
    Column({ space: 14 }) {
      Row() { Button('‹ 返回').constraintSize({ minHeight: 44 }).onClick(this.onBack); Text('PDF 覆盖审查').fontSize(20).fontWeight(FontWeight.Bold) }.width('100%')
       Text(`入库：${this.stageLabel}`).id('r2-ingestion-stage').fontSize(15).width('100%')
       Text(this.message).id('r2-ingestion-message').fontSize(14).fontColor(Theme.amber).width('100%')
      Text(this.evidence).id('r2-pdf-evidence').fontSize(12).width('100%')
      Text('定位：ProviderUnverified · 向量以知识库当前活动世代与读回状态为准').fontSize(13).width('100%')
      ForEach(this.jobs,(job: PdfIngestionJob): void => {
        Button(`${job.stage} · ${job.id} · ${job.snapshotId.length > 0 ? '恢复审查' : '原 ZIP 重试'}`).id(`r2-job-${job.id}`).enabled(!this.busy && !job.terminated)
          .onClick((): void => { this.service?.resume(job.id); })
         Button(`新 attempt 重建 · ${job.id}`).id(`r2-rebuild-${job.id}`).enabled(!this.busy && job.binding !== undefined && !job.terminated).onClick((): void => { this.service?.rebuild(job.id); })
      },(job: PdfIngestionJob): string => job.id)
      Row() { Button('上组任务').enabled(this.jobOffset > 0).onClick((): void => { this.jobOffset = Math.max(0,this.jobOffset-8); this.changed(); }); Button('下组任务').enabled(this.jobOffset+8 < (this.service?.pendingJobs.length ?? 0)).onClick((): void => { this.jobOffset += 8; this.changed(); }) }
      Button('刷新任务').id('r2-jobs-refresh').enabled(!this.busy).onClick((): void => { this.service?.refreshJobs(); })
       Button('重试派生清理').id('r2-ingestion-cleanup').enabled(!this.busy).onClick((): void => { this.lifecycle?.cleanup(); })
      ForEach(this.issues, (issue: PdfCoverageIssue) => {
        Text(`${issue.hard ? '硬失败' : '限制'}：${issue.code} · 服务候选页 ${issue.pageIndex0 >= 0 ? issue.pageIndex0+1 : '未指定'} · ${issue.nodeId}`)
          .fontSize(13).width('100%').fontColor(Theme.muted)
      }, (issue: PdfCoverageIssue): string => `${issue.code}:${issue.nodeId}:${issue.pageIndex0}`)
      Row() { Button('上组限制').enabled(this.issueOffset > 0).onClick((): void => { this.issueOffset = Math.max(0,this.issueOffset-12); this.changed(); }); Button('下组限制').enabled(this.issueOffset+12 < (this.service?.state.report?.issues.length ?? 0)).onClick((): void => { this.issueOffset += 12; this.changed(); }) }
      if (this.reportHash.length > 0 && this.stageLabel === 'AwaitingCoverageReview') {
        Row({ space: 10 }) {
           Checkbox().id('r2-ingestion-confirm').select(this.partialConfirmed).enabled(!this.busy).onChange((checked: boolean): void => { this.partialConfirmed = checked; })
          Text('确认当前报告限制，仅发布已验证内容；不确认原页映射或语义就绪').fontSize(13).layoutWeight(1)
        }.width('100%')
         Button('发布关键词（部分可用）').id('r2-ingestion-publish').constraintSize({ minHeight: 44 }).enabled(!this.busy && this.partialConfirmed)
          .onClick((): void => { const hash: string = this.reportHash; this.partialConfirmed = false; this.service?.publishPartial(hash); })
      }
      Button('暂停本机处理').constraintSize({ minHeight: 44 }).enabled(this.busy).onClick((): void => { this.service?.pause(); })
       Button('恢复本机检查点').id('r2-ingestion-resume').constraintSize({ minHeight: 44 }).enabled(!this.busy && this.service?.state.job !== undefined)
        .onClick((): void => { const id: string = this.service?.state.job?.id ?? ''; if (id.length > 0) { this.service?.resume(id); } })
       Button('放弃未发布检查点').id('r2-ingestion-abandon').constraintSize({ minHeight: 44 }).enabled(!this.busy && this.service?.state.job !== undefined && this.stageLabel !== 'KeywordPublished')
        .onClick((): void => {
          AlertDialog.show({ title: '放弃未发布检查点', message: '终止本机准备并清理未发布派生产物；原件、ZIP 和旧已发布索引保留。正在读取的引用释放后才解除保护。',
             primaryButton: { value: '取消', action: (): void => {} }, secondaryButton: { value: '确认放弃', action: (): void => { this.abandon(); } } });
        })
      Text('外发按知识库中当前输入审查、用途与免费资格分别授权；覆盖报告不代替向量就绪或定位质量').fontSize(13).fontColor(Theme.muted).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 24 })
  }
}
