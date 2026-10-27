import { RuntimeKnowledgeView } from './RuntimeKnowledgeSession';
import { ShuviRuntimeState } from './ShuviRuntimeController';

const CHIP_PREVIEW: number = 12;

/** "[2] 消费满 10 杯可兑换任…": excerpts from one file share a title, so the chip previews the excerpt itself. */
export function knowledgeCitationChip(citationId: number, excerpt: string): string {
  const text: string = excerpt.replace(new RegExp('^[#>\\s]+'), '').replace(new RegExp('\\s+', 'g'), ' ').trim();
  const chars: string[] = Array.from(text);
  const preview: string = chars.length > CHIP_PREVIEW ? chars.slice(0, CHIP_PREVIEW).join('') + '…' : text;
  return '[' + citationId.toString() + '] ' + preview;
}

/** Page-facing wording for the two RAG phases; pure functions so the host suite can check every stage. */
function excerptCount(view: RuntimeKnowledgeView): string {
  return '已完成 · ' + view.citations.length.toString() + ' 条本机片段';
}

/** Phase 1: local body/tag match, question embedding and local KNN. */
export function knowledgeRetrievalStage(view: RuntimeKnowledgeView): string {
  switch (view.stage) {
    case 'retrieving': return '检索中';
    case 'answering':
    case 'complete':
    case 'answerFailed':
    case 'insufficient': return excerptCount(view);
    case 'empty': return '没有可引用的片段';
    case 'retrievalFailed': return '未完成';
    case 'stopped': return view.citations.length > 0 ? excerptCount(view) : '已停止';
    default: return '未开始';
  }
}

/** Phase 2: the PERSONAL DeepSeek answer over the frozen excerpts. */
export function knowledgeAnswerStage(view: RuntimeKnowledgeView): string {
  switch (view.stage) {
    case 'retrieving': return '等待本机检索完成';
    case 'answering': return 'DeepSeek 整理中';
    case 'complete': return view.answerSource === 'deepseek' ? '已完成' : '未调用 DeepSeek';
    case 'answerFailed': return '未完成，可仅重试回答';
    case 'insufficient': return '资料中没有足够依据';
    case 'empty':
    case 'retrievalFailed': return '未调用 DeepSeek';
    case 'stopped': return view.answerSource === 'deepseek' ? '已完成' : '已停止';
    default: return '未开始';
  }
}

/** Mirrors the guards of RuntimeKnowledgeSession.retryAnswer so the button never appears when retry would be a no-op. */
export function knowledgeRetryAvailable(view: RuntimeKnowledgeView): boolean {
  return !view.busy && view.lifecycle === ShuviRuntimeState.READY && view.stage === 'answerFailed' &&
    view.consent && view.citations.length > 0 && view.requestCount < view.maxRequests;
}

/** Session-level DeepSeek usage, retries included. */
export function knowledgeRequestUsage(view: RuntimeKnowledgeView): string {
  return '本次会话 DeepSeek 回答 ' + view.requestCount.toString() + '/' + view.maxRequests.toString() + ' 次（含重试）';
}

/** Only a DeepSeek-written answer carries the "not original material" label. */
export function knowledgeAnswerIsModel(view: RuntimeKnowledgeView): boolean {
  return view.answer.length > 0 && view.answerSource === 'deepseek';
}
