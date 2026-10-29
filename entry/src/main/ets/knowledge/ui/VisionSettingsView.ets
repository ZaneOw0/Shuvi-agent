import { processingStageName, processingJobStateName, processingFailureText } from '../pipeline/UnifiedProcessingPresentation';
import { UnifiedSettingsService } from '../application/UnifiedSettingsService';
import { UnifiedProcessingQueue } from '../application/UnifiedProcessingQueue';
import { UnifiedProcessingJob } from '../domain/UnifiedKnowledgeModels';
import { Theme } from '../../components/Theme';

@Component
export struct VisionSettingsView {
  service: UnifiedSettingsService | undefined=undefined;
  queue: UnifiedProcessingQueue | undefined=undefined;
  onBack: () => void=(): void=>{};
  onKeys: () => void=(): void=>{};
  @State jobsOpen: boolean = false;
  @State credential: string='Missing';
  @State automaticOn: boolean=false;
  @State costConsent: boolean=false;
  @State message: string='';
  @State jobPage: number=0;
  @State jobTotal: number=0;
  @State jobs: UnifiedProcessingJob[]=[];
  @State busy: boolean=false;
  @State retryId: string='';
  private listener: () => void=(): void=> { this.refresh(); };
  aboutToAppear(): void { this.queue?.subscribe(this.listener); this.refresh(); }
  aboutToDisappear(): void { this.costConsent=false; this.queue?.unsubscribe(this.listener); }
  private async refresh(): Promise<void> {
    try {
      const state=await this.service?.setting('Vision'); this.automaticOn=state?.enabled ?? false;
      const credential=await this.service?.credentialStatus(); this.credential=credential?.present?'Configured':credential?.failure || 'Missing';
      const jobs=await this.queue?.jobs() ?? []; this.jobTotal=jobs.length;
      this.jobPage=Math.min(this.jobPage,Math.max(0,Math.ceil(this.jobTotal/6)-1));
      this.jobs=jobs.slice(this.jobPage*6,this.jobPage*6+6);
    }
    catch { this.message='设置或任务读取失败，自动处理未开启'; }
  }
  private async saveEnabled(): Promise<void> {
    this.busy=true; try { await this.service?.enableVision(!this.automaticOn,this.costConsent); this.message=this.automaticOn?'已关闭自动图片理解':'已开启自动图片理解'; this.costConsent=false; } catch { this.message='需要先在「我的 → API Key 管理」保存 DeepSeek Key，并确认发送范围与可能费用'; } finally { this.busy=false; await this.refresh(); }
  }
  private jobPageCount(): number { return Math.max(1, Math.ceil(this.jobTotal / 6)); }
  private credentialText(): string { return this.credential === 'Configured' ? 'Key 已保存' : this.credential === 'Missing' ? '未保存 Key' : '暂不可用'; }
  build() {
    Column({ space:14 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Circle }) {
          Text('‹').fontSize(28).fontColor(Theme.accent).fontWeight(FontWeight.Medium).translate({ y: -2 })
        }.width(40).height(40).backgroundColor(Theme.soft).borderRadius(20).id('upd-vision-back').accessibilityText('返回').onClick(this.onBack)
        Column({ space: 3 }) {
          Text('图片理解').fontColor(Theme.ink).fontSize(22).fontWeight(FontWeight.Medium).width('100%')
          Text('为图片生成描述与标签，方便以后按内容找到它').fontColor(Theme.muted).fontSize(12).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      if (this.message.length > 0) { Text(this.message).fontColor(Theme.amber).fontSize(13).lineHeight(21).width('100%') }
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          Column({ space: 4 }) {
            Text('理解服务').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
            Text('DeepSeek · deepseek-flash').fontColor(Theme.muted).fontSize(12).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text(this.credentialText()).fontSize(11).fontColor(this.credential === 'Configured' ? Theme.accent : Theme.muted)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 }).backgroundColor(Theme.soft).borderRadius(10)
        }.width('100%')
        Text('每次只发送当前这一张图片，用于生成中文描述和标签；不会发送正文、聊天或整库内容。可能产生费用。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
        Text('使用「API Key 管理」中保存的 DeepSeek Key。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
        Button('管理 API Key').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-vision-open-keys').onClick((): void=> { this.onKeys(); })
      }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      Column({ space: 12 }) {
        Text('自动生成描述与标签').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
        Text('开启后，新导入的图片会自动理解；已导入的图片可在「我的资料 → 处理状态」中单独重试。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
        Row({ space: 8 }) {
          Checkbox().selectedColor(Theme.accent).id('upd-vision-cost').select(this.costConsent).onChange((v: boolean): void=> { this.costConsent=v; })
          Text('我同意自动处理新导入的图片，并接受可能产生的费用').fontColor(Theme.ink).fontSize(13).layoutWeight(1)
        }.width('100%')
        Button(this.automaticOn?'关闭自动图片理解':'开启自动图片理解').fontSize(14).fontColor(this.automaticOn ? Theme.accent : Color.White).backgroundColor(this.automaticOn ? Theme.soft : Theme.accent).borderRadius(12).constraintSize({ minHeight: 46 }).width('100%').id('upd-vision-enable').enabled(!this.busy && (this.automaticOn || this.costConsent)).onClick((): void=> { this.saveEnabled(); })
      }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Button('暂停自动处理').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).id('upd-queue-pause').onClick((): void=> { this.queue?.pause(); })
          Button('继续自动处理').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).id('upd-queue-resume').onClick((): void=> { this.queue?.resume(); })
        }.width('100%')
        Button(this.jobsOpen ? '收起后台任务' : `查看后台任务（${this.jobTotal}）`).fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-jobs-toggle').onClick((): void => { this.jobsOpen = !this.jobsOpen; })
        if (this.jobsOpen) {
          if (this.jobTotal === 0) { Text('还没有后台任务').fontColor(Theme.muted).fontSize(13).width('100%') }
          ForEach(this.jobs,(j: UnifiedProcessingJob)=> {
            Column({space: 6}) {
              Text(`${processingStageName(j.stage)} · ${processingJobStateName(j)}`).fontColor(Theme.ink).fontSize(13).width('100%')
              Text(`${j.completed}/${j.expected}`).fontColor(Theme.muted).fontSize(11).width('100%')
              if (processingFailureText(j).length > 0) { Text(processingFailureText(j)).fontColor(Theme.amber).fontSize(12).lineHeight(20).width('100%') }
              if (j.state==='Unknown' || j.state==='Failed' || j.state==='Paused') { Button('重试这项任务').fontSize(12).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(10).constraintSize({ minHeight: 44 }).id('upd-job-retry-'+j.id).onClick((): void=> { this.retryId=j.id; }) }
            }.width('100%').padding(14).backgroundColor(Theme.surface).borderRadius(14).border({ width: 1, color: Theme.line })
          },(j: UnifiedProcessingJob): string=>j.id+'|'+j.state+'|'+String(j.completed)+'|'+j.failure)
          if (this.jobTotal > 6) {
            Row({ space: 10 }) {
              Button('上一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).id('upd-jobs-prev').enabled(this.jobPage>0).onClick((): void=> { this.jobPage--; this.refresh(); })
              Text(`${this.jobPage+1} / ${this.jobPageCount()}`).fontSize(13).fontColor(Theme.ink).layoutWeight(1).textAlign(TextAlign.Center)
              Button('下一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).id('upd-jobs-next').enabled(this.jobPage+1<this.jobPageCount()).onClick((): void=> { this.jobPage++; this.refresh(); })
            }.width('100%')
          }
        }
        if (this.retryId.length>0) {
          Text('上一次请求的结果可能未知。重试可能重复计费，只会重试选中的这一项。').fontColor(Theme.ink).fontSize(12).lineHeight(20).width('100%')
          Row({ space: 10 }) {
            Button('取消').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).onClick((): void=> { this.retryId=''; })
            Button('接受可能费用并重试').fontSize(13).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).id('upd-job-retry-confirm').onClick((): void=> { this.queue?.retry(this.retryId,true).catch((): void=> { this.message='重试未保存'; }); this.retryId=''; })
          }.width('100%')
        }
        Text('文件级进度也可以在「我的资料 → 资料详情」中查看。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
      }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      Text(this.queue?.message ?? '').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({top:12,bottom:24})
  }
}
