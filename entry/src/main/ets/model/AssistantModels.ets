// Frontend prototype types only; the shared Agent/platform contract is still pending.
export enum DemoScenario {
  Normal = '正常流程',
  ModelFailure = '模型调用失败',
  InvalidDraft = '模型字段无效',
  Clarification = '需要补充信息',
  GenerationTimeout = '生成超时',
  CalendarFailure = '日程创建失败',
  PermissionDenied = '日历权限拒绝',
  ReminderFailure = '提醒注册失败',
  ExecutionTimeout = '执行超时'
}

export const DEMO_SCENARIOS: DemoScenario[] = [
  DemoScenario.Normal, DemoScenario.ModelFailure, DemoScenario.InvalidDraft,
  DemoScenario.Clarification, DemoScenario.GenerationTimeout, DemoScenario.CalendarFailure,
  DemoScenario.PermissionDenied, DemoScenario.ReminderFailure, DemoScenario.ExecutionTimeout
];

export enum RequestState {
  Ready = 'ready',
  Failed = 'failed',
  Cancelled = 'cancelled',
  Clarification = 'clarification',
  Unsupported = 'unsupported'
}

export enum OperationState {
  Success = 'success',
  Partial = 'partial',
  Failed = 'failed'
}

export interface ChatMessage {
  id: string;
  isUser: boolean;
  text: string;
}

export interface CalendarDraft {
  draftId: string;
  requestId: string;
  title: string;
  startAt: string;
  endAt: string;
  timeZone: string;
  reminderMinutesBefore: number;
}

export interface DraftReply {
  state: RequestState;
  message: string;
  draft?: CalendarDraft;
}

export interface OperationResult {
  operationId: string;
  draft: CalendarDraft;
  state: OperationState;
  calendarCreated: boolean;
  reminderRegistered: boolean;
  message: string;
}

export interface AssistantService {
  sampleText: string;
  nextId(prefix: string): string;
  generate(requestId: string, text: string, scenario: DemoScenario): Promise<DraftReply>;
  cancel(requestId: string): void;
  discard(draftId: string): void;
  confirm(draft: CalendarDraft, operationId: string, scenario: DemoScenario): Promise<OperationResult>;
  retryReminder(operationId: string): Promise<OperationResult>;
  records(): OperationResult[];
}
