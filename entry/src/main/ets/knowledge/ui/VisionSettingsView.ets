import { UnifiedSettingsService } from '../application/UnifiedSettingsService';
import { UnifiedProcessingQueue } from '../application/UnifiedProcessingQueue';
import { UnifiedProcessingJob } from '../domain/UnifiedKnowledgeModels';
import { Theme } from '../../components/Theme';

@Component
export struct VisionSettingsView {
  service: UnifiedSettingsService | undefined=undefined;
  queue: UnifiedProcessingQueue | undefined=undefined;
  onBack: () => void=(): void=>{};
  @State secretInput: string='';
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
  aboutToDisappear(): void { this.secretInput=''; this.costConsent=false; this.queue?.unsubscribe(this.listener); }
  private async refresh(): Promise<void> {
    try { const state=await this.service?.setting('Vision'); this.automaticOn=state?.enabled ?? false; const credential=await this.service?.credentialStatus(); this.credential=credential?.present?'Configured':credential?.failure || 'Missing'; const jobs=await this.queue?.jobs() ?? []; this.jobTotal=jobs.length; this.jobPage=Math.min(this.jobPage,Math.max(0,Math.ceil(this.jobTotal/10)-1)); this.jobs=jobs.slice(this.jobPage*10,this.jobPage*10+10); }
    catch { this.message='设置或队列读取失败，外发未开启'; }
  }
  private async saveKey(remove: boolean=false): Promise<void> {
    let secret: string=this.secretInput; this.secretInput=''; this.busy=true;
    try { await this.service?.saveVisionKey(secret,remove); this.costConsent=false; this.message='凭据动作已保存，自动许可需重新确认；未探测服务'; }
    catch { this.message='凭据存储失败，没有明文降级'; }
    finally { secret=''; this.secretInput=''; this.busy=false; await this.refresh(); }
  }
  private async saveEnabled(): Promise<void> {
    this.busy=true; try { await this.service?.enableVision(!this.automaticOn,this.costConsent); this.message='设置已保存'; this.costConsent=false; } catch { this.message='需要独立Key及当前输入/费用确认'; } finally { this.busy=false; await this.refresh(); }
  }
  build() {
    Column({ space:12 }) {
      Row() { Button('返回').id('upd-vision-back').onClick(this.onBack); Text('图片理解设置').fontSize(20).layoutWeight(1) }.width('100%')
      Text('DeepSeek · deepseek-flash').fontSize(17).width('100%')
      Text('输入：当前已落盘单图原字节与固定中文描述/标签任务。不发送全文、图注或聊天；复用已有OCR，不新增OCR请求。可能收费，价格与留存不作保证。').fontSize(13).fontColor(Theme.muted).width('100%')
      Text(`独立凭据：${this.credential}`).width('100%')
      TextInput({text:this.secretInput,placeholder:'输入图片理解 Key，不读取其他用途Key'}).id('upd-vision-key').type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None).selectionMenuHidden(true).enableAutoFill(false).enablePreviewText(false).maxLength(1024).onChange((v: string): void=> { this.secretInput=v; })
      Row() { Button('保存Key').id('upd-vision-save-key').enabled(!this.busy && this.secretInput.length>0).onClick((): void=> { this.saveKey(); }); Button('删除Key').enabled(!this.busy).onClick((): void=> { this.saveKey(true); }) }.width('100%')
      Row() { Checkbox().id('upd-vision-cost').select(this.costConsent).onChange((v: boolean): void=> { this.costConsent=v; }); Text('同意自动处理新导入图片、上述接收方/输入范围及可能费用').fontSize(13).layoutWeight(1) }.width('100%')
      Button(this.automaticOn?'关闭自动图片理解':'启用自动图片理解').id('upd-vision-enable').enabled(!this.busy && (this.automaticOn || this.costConsent)).onClick((): void=> { this.saveEnabled(); })
      Row() { Button('暂停队列').id('upd-queue-pause').onClick((): void=> { this.queue?.pause(); }); Button('恢复队列').id('upd-queue-resume').onClick((): void=> { this.queue?.resume(); }) }.width('100%')
      Text(this.message || this.queue?.message || '').fontSize(13).width('100%')
      Text('文件级进度与重试也可在「知识库 → 我的资料 → 资料详情」查看。').fontSize(13).width('100%')
      if (this.jobTotal>10) { Row() { Button('上一组任务').id('upd-jobs-prev').enabled(this.jobPage>0).onClick((): void=> { this.jobPage--; this.refresh(); }); Text(`${this.jobPage+1}/${Math.ceil(this.jobTotal/10)}`); Button('下一组任务').id('upd-jobs-next').enabled((this.jobPage+1)*10<this.jobTotal).onClick((): void=> { this.jobPage++; this.refresh(); }) } }
      ForEach(this.jobs,(j: UnifiedProcessingJob)=> {
        Column() {
          Text(`${j.stage} · ${j.origin} · ${j.state} · ${j.completed}/${j.expected}`).fontSize(13).width('100%')
          Text(j.failure==='Http:401'?'视觉服务鉴权失败（HTTP 401），请更新独立 DeepSeek Key 后再重试。':j.failure==='Http:403'?'视觉服务拒绝访问（HTTP 403），请核对账号与模型权限。':j.failure).fontSize(12).width('100%')
          if (j.state==='Unknown' || j.state==='Failed' || j.state==='Paused') { Button('重试').id('upd-job-retry-'+j.id).onClick((): void=> { this.retryId=j.id; }) }
        }.width('100%')
      },(j: UnifiedProcessingJob): string=>j.id+'|'+j.state+'|'+String(j.completed)+'|'+j.failure)
      if (this.retryId.length>0) {
        Text('先前请求结果可能未知。重试可能重复计费，仅对选中作业重试。').fontSize(13).width('100%')
        Button('接受可能费用并重试').id('upd-job-retry-confirm').onClick((): void=> { this.queue?.retry(this.retryId,true).catch((): void=> { this.message='重试未保存'; }); this.retryId=''; })
        Button('取消').onClick((): void=> { this.retryId=''; })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({top:12,bottom:20})
  }
}
