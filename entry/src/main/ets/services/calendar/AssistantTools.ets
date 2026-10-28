import { ChatContextPort } from '../model/ChatRuntimeAssembly';
import { ModelProposalResult, ModelTurnPort } from '../model/DeepSeekToolTransport';
import { ASSISTANT_MAX_MESSAGE, AssistantContext } from './AssistantIntent';
import { CalendarProbeDraft, calendarProbeDraftError } from './CalendarProbeSession';

export const CALENDAR_PROPOSE_TOOL: string = 'calendar_propose';
const CALENDAR_PROPOSE_KEYS: string[] = ['title', 'startAt', 'endAt', 'timeZone', 'reminderMinutes'];

/** OpenAI-compatible declaration. The tool only proposes; the confirmed native calendar task does the write. */
export function calendarProposeDefinitions(): Object[] {
  return JSON.parse('[{"type":"function","function":{"name":"calendar_propose","description":"Propose ONE single, non-all-day calendar event in Beijing time. Nothing is written by this call: it ends the current turn and shows the user a confirmation card; only the user\'s confirmation creates the event. Call it only when the user explicitly asks to schedule or create an event and every field is known; otherwise ask the user in text. Never claim the event was created.","parameters":{"type":"object","additionalProperties":false,"properties":{"title":{"type":"string","description":"1-200 characters"},"startAt":{"type":"string","description":"YYYY-MM-DDTHH:mm:00+08:00, in the future"},"endAt":{"type":"string","description":"YYYY-MM-DDTHH:mm:00+08:00, later than startAt"},"timeZone":{"type":"string","enum":["Asia/Shanghai"]},"reminderMinutes":{"type":"integer","minimum":0,"maximum":10080,"description":"minutes before start; 0 means at start"}},"required":["title","startAt","endAt","timeZone","reminderMinutes"]}}}]') as Object[];
}

class AssistantAnswerWire { schemaVersion: string = '1.0'; kind: string = 'answer'; message: string = ''; }
class AssistantProposalWire { schemaVersion: string = '1.0'; kind: string = 'draft'; draft: CalendarProbeDraft = new CalendarProbeDraft(); note?: string; }

/** Turn policy of the tool-mode assistant: answers and calendar proposals use the existing AssistantIntent wire format. */
export class AssistantToolTurn implements ModelTurnPort {
  private readonly context: AssistantContext;
  private readonly clock: () => number;
  constructor(context: AssistantContext, clock: () => number = (): number => Date.now()) { this.context = context; this.clock = clock; }
  proposalNames(): string[] { return [CALENDAR_PROPOSE_TOOL]; }
  proposalDefinitions(): Object[] { return calendarProposeDefinitions(); }
  propose(name: string, argumentsJson: string, note: string): ModelProposalResult {
    const result: ModelProposalResult = new ModelProposalResult();
    if (name !== CALENDAR_PROPOSE_TOOL) { result.error = '不支持的提议工具'; return result; }
    let value: Record<string, Object>;
    try { value = JSON.parse(argumentsJson) as Record<string, Object>; } catch { result.error = '参数不是有效 JSON'; return result; }
    if (value === null || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== CALENDAR_PROPOSE_KEYS.length ||
      Object.keys(value).some((key: string): boolean => !CALENDAR_PROPOSE_KEYS.includes(key))) {
      result.error = '参数必须且只能包含 title、startAt、endAt、timeZone、reminderMinutes'; return result;
    }
    if (typeof value['title'] !== 'string' || typeof value['startAt'] !== 'string' || typeof value['endAt'] !== 'string' ||
      typeof value['timeZone'] !== 'string' || typeof value['reminderMinutes'] !== 'number') {
      result.error = '参数类型无效'; return result;
    }
    const draft: CalendarProbeDraft = new CalendarProbeDraft();
    draft.title = (value['title'] as string).trim(); draft.startAt = value['startAt'] as string; draft.endAt = value['endAt'] as string;
    draft.timeZone = value['timeZone'] as string; draft.reminderMinutes = value['reminderMinutes'] as number;
    const error: string = calendarProbeDraftError(draft, this.clock());
    if (error) { result.error = error; return result; }
    const wire: AssistantProposalWire = new AssistantProposalWire(); wire.draft = draft;
    if (note.trim()) wire.note = note.trim().slice(0, 6000);
    result.output = JSON.stringify(wire);
    result.toolReply = '{"ok":true,"status":"AWAITING_USER_CONFIRMATION","created":false}';
    result.summary = `已生成日程草稿「${draft.title}」，等待用户在确认卡上核对；尚未写入日历。`;
    return result;
  }
  answer(text: string): string {
    const wire: AssistantAnswerWire = new AssistantAnswerWire();
    const trimmed: string = text.trim();
    wire.message = !trimmed ? '模型没有给出文字回答。' :
      trimmed.length > ASSISTANT_MAX_MESSAGE ? trimmed.slice(0, ASSISTANT_MAX_MESSAGE - 12) + '\n…（回答过长已截断）' : trimmed;
    return JSON.stringify(wire);
  }
  conversationEpoch(): number { return this.context.conversationEpoch(); }
}

/** Tool-mode prompts over the same per-turn AssistantContext that the session binds before each send. */
export class AssistantToolPrompt implements ChatContextPort {
  private readonly context: AssistantContext;
  constructor(context: AssistantContext) { this.context = context; }
  systemPrompt(): string { return this.context.toolSystemPrompt(); }
  promptFor(intent: string): string | undefined { return this.context.toolPromptFor(intent); }
}
