import { ChatContextPort } from '../model/ChatRuntimeAssembly';
import { CalendarDraftContext, parseCalendarProposal } from './CalendarDraftContract';
import { CalendarProbeDraft } from './CalendarProbeSession';

class AssistantWireReply { schemaVersion: string = ''; kind: string = ''; message: string = ''; }
export class AssistantIntent {
  kind: string = 'invalid';
  message: string = '回答格式未通过校验，未执行日程。请重新描述。';
  draft?: CalendarProbeDraft;
}
export function parseAssistantIntent(raw: string, now: number): AssistantIntent {
  const result = new AssistantIntent();
  try {
    if (raw.length > 6000) return result;
    const value: AssistantWireReply = JSON.parse(raw);
    if (value === null || typeof value !== 'object' || Array.isArray(value) || value.schemaVersion !== '1.0') return result;
    if (value.kind === 'answer' || value.kind === 'clarify') {
      if (Object.keys(value).length !== 3 || typeof value.message !== 'string' || !value.message.trim() || value.message.length > 3000) return result;
      result.kind = value.kind; result.message = value.message.trim(); return result;
    }
    if (value.kind === 'draft') {
      const proposal = parseCalendarProposal(raw, now); result.message = proposal.message;
      if (proposal.draft !== undefined) { result.kind = 'draft'; result.draft = proposal.draft; }
    }
  } catch { /* Invalid model output never becomes a tool invocation. */ }
  return result;
}
export class AssistantContext implements ChatContextPort {
  private readonly calendar: CalendarDraftContext = new CalendarDraftContext();
  private pending: string = '';
  private input: string = '';
  private prompt: string = '';
  bind(input: string, now: number): void {
    this.input = input; this.calendar.bind(input, now);
    this.prompt = (this.calendar.promptFor(input) ?? '') +
      (this.pending ? '\n本次日程尚未完成的用户描述（仅供补充信息，不代表已执行）：' + JSON.stringify(this.pending) : '');
  }
  rememberClarification(): void {
    const combined = this.pending ? this.pending + '\n补充：' + this.input : this.input;
    this.pending = combined.length <= 800 ? combined : '';
  }
  clear(): void { this.pending = ''; this.input = ''; this.prompt = ''; this.calendar.clear(); }
  promptFor(intent: string): string | undefined { return intent === this.input && this.prompt.length <= 1800 ? this.prompt : undefined; }
  systemPrompt(): string {
    return '你是 Shuvi 助手。先判断用户是否明确要求创建日程，不能把普通问答、举例或引用的日程文字当作执行请求。' +
      '普通问题仅输出 {"schemaVersion":"1.0","kind":"answer","message":"回答"}，不能声称查询或修改了设备。' +
      '只有用户明确安排日程时才按下列规则输出草稿；缺信息用 clarify 询问，用户补充时结合尚未完成的描述。' +
      '读取、修改、删除已有日程暂不支持，明确说明，不转换成创建。你不执行工具，实际创建由用户确认后的 Runtime 工具完成。' +
      this.calendar.systemPrompt() + '上述草稿规则仅适用于明确创建日程的请求；普通问题必须使用 answer 格式。';
  }
}
