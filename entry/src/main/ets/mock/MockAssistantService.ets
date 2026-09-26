import {
  AssistantService, CalendarDraft, DemoScenario, DraftReply, OperationResult,
  OperationState, RequestState
} from '../model/AssistantModels';

export function validateDraft(draft: CalendarDraft): boolean {
  const start = Date.parse(draft.startAt);
  const end = Date.parse(draft.endAt);
  return draft.title.trim().length > 0 && Number.isFinite(start) && Number.isFinite(end) &&
    end > start && draft.timeZone === 'Asia/Shanghai' &&
    Number.isInteger(draft.reminderMinutesBefore) && draft.reminderMinutesBefore >= 0;
}

function copyDraft(draft: CalendarDraft): CalendarDraft {
  return {
    draftId: draft.draftId, requestId: draft.requestId, title: draft.title,
    startAt: draft.startAt, endAt: draft.endAt, timeZone: draft.timeZone,
    reminderMinutesBefore: draft.reminderMinutesBefore
  };
}

// In-memory fixtures: no model, filesystem, permissions or system calendar access.
export class MockAssistantService implements AssistantService {
  readonly sampleText: string = '2026 年 10 月 20 日下午 3 点到 4 点开项目会，提前 10 分钟提醒我';
  private sequence: number = 0;
  private activeRequests: Set<string> = new Set<string>();
  private drafts: Map<string, CalendarDraft> = new Map<string, CalendarDraft>();
  private draftOperations: Map<string, string> = new Map<string, string>();
  private operationDrafts: Map<string, string> = new Map<string, string>();
  private results: Map<string, OperationResult> = new Map<string, OperationResult>();
  private pending: Map<string, Promise<OperationResult>> = new Map<string, Promise<OperationResult>>();

  private delayMs: number;
  private timeoutMs: number;

  constructor(delayMs: number = 800, timeoutMs: number = 10000) {
    this.delayMs = delayMs;
    this.timeoutMs = timeoutMs;
  }

  nextId(prefix: string): string {
    this.sequence++;
    return `mock-${prefix}-${this.sequence}`;
  }

  private wait(timeout: boolean = false): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, timeout ? this.timeoutMs : this.delayMs);
    });
  }

  cancel(requestId: string): void {
    this.activeRequests.delete(requestId);
  }

  discard(draftId: string): void {
    const operationId = this.draftOperations.get(draftId);
    const result = operationId ? this.results.get(operationId) : undefined;
    if (!operationId || (!this.pending.has(operationId) && (!result || !result.calendarCreated))) {
      this.drafts.delete(draftId);
    }
  }

  async generate(requestId: string, text: string, scenario: DemoScenario): Promise<DraftReply> {
    this.activeRequests.add(requestId);
    await this.wait(scenario === DemoScenario.GenerationTimeout);
    if (!this.activeRequests.delete(requestId)) {
      return { state: RequestState.Cancelled, message: '已取消生成' };
    }
    if (text.trim().length === 0 || text.length > 500) {
      return { state: RequestState.Failed, message: '请输入 1 至 500 个字符。' };
    }
    if (text.trim() !== this.sampleText) {
      return { state: RequestState.Unsupported, message: '当前为演示版本，请使用样例体验创建日程。' };
    }
    if (scenario === DemoScenario.GenerationTimeout) {
      return { state: RequestState.Failed, message: '模拟生成超时，请重试。' };
    }
    if (scenario === DemoScenario.ModelFailure) {
      return { state: RequestState.Failed, message: '模拟模型调用失败，输入已保留，可以重试。' };
    }
    if (scenario === DemoScenario.Clarification) {
      return { state: RequestState.Clarification, message: '模拟待澄清：请补充会议的结束时间。可取消后重新选择完整样例。' };
    }
    const draft: CalendarDraft = {
      draftId: this.nextId('draft'), requestId: requestId, title: '项目会',
      startAt: '2026-10-20T15:00:00+08:00', endAt: '2026-10-20T16:00:00+08:00',
      timeZone: 'Asia/Shanghai', reminderMinutesBefore: 10
    };
    if (scenario === DemoScenario.InvalidDraft) {
      draft.endAt = 'invalid';
    }
    if (!validateDraft(draft)) {
      return { state: RequestState.Failed, message: '模拟返回的日程字段无效，已阻止创建，请重试。' };
    }
    this.drafts.set(draft.draftId, copyDraft(draft));
    return { state: RequestState.Ready, message: '日程草稿已准备好，请核对后确认。', draft: draft };
  }

  confirm(draft: CalendarDraft, operationId: string, scenario: DemoScenario): Promise<OperationResult> {
    const registered = this.drafts.get(draft.draftId);
    if (!registered || !validateDraft(draft) || registered.title !== draft.title ||
      registered.startAt !== draft.startAt || registered.endAt !== draft.endAt ||
      registered.timeZone !== draft.timeZone || registered.requestId !== draft.requestId ||
      registered.reminderMinutesBefore !== draft.reminderMinutesBefore) {
      return Promise.resolve(this.failure(draft, operationId, '草稿已取消或字段无效，请重新生成。'));
    }
    const boundId = this.draftOperations.get(draft.draftId);
    if (boundId && boundId !== operationId) {
      return Promise.resolve(this.failure(draft, operationId, '该草稿已有操作，请查看原操作结果。'));
    }
    const boundDraft = this.operationDrafts.get(operationId);
    if (boundDraft && boundDraft !== draft.draftId) {
      return Promise.resolve(this.failure(draft, operationId, '操作标识已用于其他日程。'));
    }
    const previous = this.results.get(operationId);
    if (previous && previous.draft.draftId !== draft.draftId) {
      return Promise.resolve(this.failure(draft, operationId, '操作标识已用于其他日程。'));
    }
    if (previous && previous.calendarCreated) {
      return Promise.resolve(previous);
    }
    const running = this.pending.get(operationId);
    if (running) {
      return running;
    }
    // Bind before awaiting; neither concurrent clicks nor retries may create a second event.
    this.draftOperations.set(draft.draftId, operationId);
    this.operationDrafts.set(operationId, draft.draftId);
    const operation = this.execute(copyDraft(registered), operationId, scenario);
    this.pending.set(operationId, operation);
    return operation;
  }

  private failure(draft: CalendarDraft, operationId: string, message: string): OperationResult {
    return {
      operationId: operationId, draft: draft, state: OperationState.Failed,
      calendarCreated: false, reminderRegistered: false, message: message
    };
  }

  private async execute(draft: CalendarDraft, operationId: string,
    scenario: DemoScenario): Promise<OperationResult> {
    await this.wait(scenario === DemoScenario.ExecutionTimeout);
    let result: OperationResult;
    if (scenario === DemoScenario.PermissionDenied) {
      result = this.failure(draft, operationId, '模拟日历权限被拒绝，未创建日程。可切换正常场景后重试。');
    } else if (scenario === DemoScenario.CalendarFailure) {
      result = this.failure(draft, operationId, '模拟日程创建失败，未执行提醒，可重试。');
    } else if (scenario === DemoScenario.ExecutionTimeout) {
      result = this.failure(draft, operationId, '模拟执行超时，本场景未写入数据，可重试。');
    } else {
      const reminderOk = scenario !== DemoScenario.ReminderFailure;
      result = {
        operationId: operationId, draft: draft,
        state: reminderOk ? OperationState.Success : OperationState.Partial,
        calendarCreated: true, reminderRegistered: reminderOk,
        message: reminderOk ? '已添加到演示日程；未写入系统日历，不会实际提醒。' :
          '演示日程已保留，模拟提醒注册失败。重试只处理提醒，不会重复创建日程。'
      };
    }
    this.results.set(operationId, result);
    this.pending.delete(operationId);
    return result;
  }

  retryReminder(operationId: string): Promise<OperationResult> {
    const running = this.pending.get(operationId);
    if (running) {
      return running;
    }
    const result = this.results.get(operationId);
    if (!result || !result.calendarCreated) {
      return Promise.reject(new Error('没有可补救的演示日程。'));
    }
    if (result.reminderRegistered) {
      return Promise.resolve(result);
    }
    const operation = this.repairReminder(result);
    this.pending.set(operationId, operation);
    return operation;
  }

  private async repairReminder(previous: OperationResult): Promise<OperationResult> {
    await this.wait();
    const result: OperationResult = {
      operationId: previous.operationId, draft: previous.draft, state: OperationState.Success,
      calendarCreated: true, reminderRegistered: true,
      message: '模拟提醒已补充；原日程未重复创建，不会产生真实提醒。'
    };
    this.results.set(previous.operationId, result);
    this.pending.delete(previous.operationId);
    return result;
  }

  records(): OperationResult[] {
    return Array.from(this.results.values()).filter((result: OperationResult) => result.calendarCreated);
  }
}
