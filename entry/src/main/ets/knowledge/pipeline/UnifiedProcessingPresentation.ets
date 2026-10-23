import { ParsedDocumentRecord } from '../domain/ParsedDocumentModels';
import { UnifiedProcessingJob, UnifiedJobState } from '../domain/UnifiedKnowledgeModels';

export function processingStageName(stage: string): string {
  return stage==='BodyEmbedding'?'正文可检索化':stage==='ImageEmbedding'?'图片可检索化':stage==='Vision'?'图片描述与标签':'自动处理';
}
export function processingStateName(state: UnifiedJobState): string {
  return state===UnifiedJobState.Complete?'已完成':state===UnifiedJobState.Running?'处理中':state===UnifiedJobState.Unknown?'结果待核对':state===UnifiedJobState.Failed?'失败':state===UnifiedJobState.Paused?'已暂停':state===UnifiedJobState.Canceled?'已停止':state===UnifiedJobState.Pending?'已排队':'等待设置或处理';
}
export function processingJobStateName(job: UnifiedProcessingJob): string {
  if ((job.state===UnifiedJobState.Unknown || job.state===UnifiedJobState.Failed) && job.failure==='Http:401') { return '鉴权失败'; }
  if ((job.state===UnifiedJobState.Unknown || job.state===UnifiedJobState.Failed) && job.failure==='Http:403') { return '服务拒绝访问'; }
  return processingStateName(job.state);
}
export function processingCanRetry(job: UnifiedProcessingJob): boolean {
  return [UnifiedJobState.Unknown,UnifiedJobState.Failed,UnifiedJobState.Paused].indexOf(job.state)>=0;
}
export function processingCurrentJobs(jobs: UnifiedProcessingJob[], document: ParsedDocumentRecord): UnifiedProcessingJob[] {
  return jobs.filter((j: UnifiedProcessingJob): boolean=>j.documentKey===document.id && j.version===document.activeGeneration && j.epoch===document.epoch && !(j.state===UnifiedJobState.Canceled && j.failure==='ConfigChangedRetained')).sort((a: UnifiedProcessingJob,b: UnifiedProcessingJob): number=>(a.stage==='BodyEmbedding'?0:a.stage==='Vision'?1:2)-(b.stage==='BodyEmbedding'?0:b.stage==='Vision'?1:2) || a.id.localeCompare(b.id));
}
export function processingDocumentStatus(jobs: UnifiedProcessingJob[], document: ParsedDocumentRecord): string {
  if (document.archived) { return '已归档'; }
  if (document.activeGeneration.length===0) { return '等待本机入库'; }
  const current=processingCurrentJobs(jobs,document);
  const incomplete=current.find((j: UnifiedProcessingJob): boolean=>j.state!==UnifiedJobState.Complete);
  if (incomplete!==undefined) { return `部分入库 · ${processingStageName(incomplete.stage)} ${incomplete.completed}/${incomplete.expected} · ${processingJobStateName(incomplete)}`; }
  return current.length>0?'已入库':document.namespace==='Image'?'原图已保存':'正文已入库';
}
export function processingFailureText(job: UnifiedProcessingJob): string {
  if (job.state===UnifiedJobState.Pending || job.state===UnifiedJobState.Running || job.state===UnifiedJobState.Complete || job.failure==='ExplicitRetryAcceptsPossibleDuplicateCost') { return ''; }
  if (job.failure==='DispatchPaused' || job.failure==='Canceled' || job.failure==='PreviousProcessCheckpoint') { return '处理被暂停或应用中断，已完成内容保留。'; }
  if (job.failure==='Http:401') { return '图片理解服务鉴权失败，请到图片理解设置更新 Key。'; }
  if (job.failure==='Http:403') { return '图片理解服务拒绝访问，请核对账号与模型权限。'; }
  if (job.state===UnifiedJobState.Unknown) { return '服务结果尚未确认，已保留成功进度；重试可能重复计费。'; }
  return job.failure.length>0?'此环节未完成，已保留此前成功内容。原因：'+job.failure:'';
}
