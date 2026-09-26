import { MockAssistantService, validateDraft } from '../main/ets/mock/MockAssistantService';
import { CalendarDraft, DemoScenario, OperationState, RequestState } from '../main/ets/model/AssistantModels';

export interface MockTestCase {
  name: string;
  run: () => Promise<void>;
}

function check(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(message);
  }
}

async function sample(service: MockAssistantService): Promise<CalendarDraft> {
  const reply = await service.generate(service.nextId('request'), service.sampleText, DemoScenario.Normal);
  if (!reply.draft) {
    throw new Error('Expected a valid sample draft');
  }
  return reply.draft;
}

// The same deterministic cases can run in Hypium or the documented host runner.
// Short injected delays do not exercise ArkUI or real platform capabilities.
export function mockAssistantCases(): MockTestCase[] {
  return [
    {
      name: '正常确认保留日程并区分提醒状态',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        const draft = await sample(service);
        const result = await service.confirm(draft, 'op', DemoScenario.Normal);
        check(result.state === OperationState.Success && result.calendarCreated &&
          result.reminderRegistered, 'Expected both simulated steps to succeed');
        check(service.records().length === 1, 'Expected one record');
        check(result.draft.startAt === '2026-10-20T15:00:00+08:00', 'Fixture time changed');
      }
    },
    {
      name: '并发与重复确认只创建一条日程',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        const draft = await sample(service);
        await Promise.all([
          service.confirm(draft, 'op', DemoScenario.Normal),
          service.confirm(draft, 'op', DemoScenario.Normal)
        ]);
        await service.confirm(draft, 'op', DemoScenario.Normal);
        const other = await service.confirm(draft, 'other-op', DemoScenario.Normal);
        check(other.state === OperationState.Failed, 'Draft must stay bound to its operation');
        check(service.records().length === 1, 'Duplicate records created');
      }
    },
    {
      name: '取消生成后迟到回复不能产生草稿',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        const pending = service.generate('cancelled', service.sampleText, DemoScenario.Normal);
        service.cancel('cancelled');
        const replacement = service.generate('replacement', service.sampleText, DemoScenario.Normal);
        const reply = await pending;
        check(reply.state === RequestState.Cancelled && !reply.draft, 'Cancelled reply produced a draft');
        check((await replacement).state === RequestState.Ready, 'Cancellation affected the next request');
        check(service.records().length === 0, 'Generation wrote a record');
      }
    },
    {
      name: '取消草稿及失败后取消都阻止旧草稿执行',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        const first = await sample(service);
        service.discard(first.draftId);
        check((await service.confirm(first, 'op1', DemoScenario.Normal)).state === OperationState.Failed,
          'Discarded draft executed');
        const second = await sample(service);
        await service.confirm(second, 'op2', DemoScenario.CalendarFailure);
        service.discard(second.draftId);
        check((await service.confirm(second, 'op2', DemoScenario.Normal)).state === OperationState.Failed,
          'Discard after failure did not invalidate the draft');
        check(service.records().length === 0, 'Cancelled draft left a record');
      }
    },
    {
      name: '权限拒绝和日程失败不写入并允许同操作重试',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        const draft = await sample(service);
        const denied = await service.confirm(draft, 'op', DemoScenario.PermissionDenied);
        check(!denied.calendarCreated && !denied.reminderRegistered, 'Permission denial wrote data');
        await service.confirm(draft, 'op', DemoScenario.CalendarFailure);
        check(service.records().length === 0, 'Failed calendar operation wrote data');
        await service.confirm(draft, 'op', DemoScenario.Normal);
        check(service.records().length === 1, 'Same-operation retry did not recover');
      }
    },
    {
      name: '提醒部分失败和并发补救保留同一日程',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        const draft = await sample(service);
        const partial = await service.confirm(draft, 'op', DemoScenario.ReminderFailure);
        check(partial.state === OperationState.Partial && partial.calendarCreated &&
          !partial.reminderRegistered, 'Expected partial success');
        await Promise.all([service.retryReminder('op'), service.retryReminder('op')]);
        const records = service.records();
        check(records.length === 1 && records[0].draft.draftId === draft.draftId &&
          records[0].reminderRegistered, 'Reminder retry duplicated or replaced the calendar');
      }
    },
    {
      name: '无日程不能补救提醒',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        let rejected: boolean = false;
        try {
          await service.retryReminder('missing');
        } catch {
          rejected = true;
        }
        check(rejected && service.records().length === 0, 'Missing operation was accepted');
      }
    },
    {
      name: '模型失败无效字段和待澄清均无可执行草稿',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        const scenarios: DemoScenario[] = [DemoScenario.ModelFailure, DemoScenario.InvalidDraft,
          DemoScenario.Clarification];
        for (const scenario of scenarios) {
          const reply = await service.generate(service.nextId('request'), service.sampleText, scenario);
          check(!reply.draft && reply.state !== RequestState.Ready, 'Invalid model result was accepted');
        }
        check(service.records().length === 0, 'Model failure produced a record');
      }
    },
    {
      name: '模拟超时无写入且可恢复',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        const timedOut = await service.generate('timeout', service.sampleText, DemoScenario.GenerationTimeout);
        check(timedOut.state === RequestState.Failed && !timedOut.draft, 'Generation did not time out');
        const draft = await sample(service);
        const execution = await service.confirm(draft, 'op', DemoScenario.ExecutionTimeout);
        check(execution.state === OperationState.Failed && service.records().length === 0,
          'Mock timeout should not write data');
        await service.confirm(draft, 'op', DemoScenario.Normal);
        check(service.records().length === 1, 'Timeout recovery failed');
      }
    },
    {
      name: '空白超长和非样例输入不套用固定日程',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        for (const input of ['   ', 'a'.repeat(501), '明天去买菜']) {
          const reply = await service.generate(service.nextId('request'), input, DemoScenario.Normal);
          check(!reply.draft, 'Unsupported input produced a fixture draft');
        }
      }
    },
    {
      name: '草稿字段校验覆盖空标题逆序时间和非法提醒',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        const draft = await sample(service);
        draft.title = ' ';
        check(!validateDraft(draft), 'Blank title accepted');
        draft.title = '项目会';
        draft.endAt = '2026-10-20T14:00:00+08:00';
        check(!validateDraft(draft), 'Reversed time range accepted');
        draft.endAt = '2026-10-20T16:00:00+08:00';
        draft.reminderMinutesBefore = -1;
        check(!validateDraft(draft), 'Negative reminder accepted');
        draft.reminderMinutesBefore = 1.5;
        check(!validateDraft(draft), 'Fractional reminder accepted');
        draft.reminderMinutesBefore = 10;
        draft.startAt = 'invalid';
        check(!validateDraft(draft), 'Invalid timestamp accepted');
      }
    },
    {
      name: '同一操作标识不能并发执行不同草稿',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        const first = await sample(service);
        const second = await sample(service);
        const pending = service.confirm(first, 'op', DemoScenario.Normal);
        const collision = await service.confirm(second, 'op', DemoScenario.Normal);
        check(collision.state === OperationState.Failed, 'Operation ID collision was accepted');
        await pending;
        check(service.records().length === 1, 'Operation ID collision corrupted records');
      }
    },
    {
      name: '确认拒绝被修改的草稿并接受字段一致的副本',
      run: async () => {
        const service = new MockAssistantService(1, 5);
        const draft = await sample(service);
        draft.title = '未经确认的修改';
        check((await service.confirm(draft, 'op', DemoScenario.Normal)).state === OperationState.Failed,
          'Mutated draft was accepted');
        draft.title = '项目会';
        const copy: CalendarDraft = {
          draftId: draft.draftId, requestId: draft.requestId, title: draft.title,
          startAt: draft.startAt, endAt: draft.endAt, timeZone: draft.timeZone,
          reminderMinutesBefore: draft.reminderMinutesBefore
        };
        check((await service.confirm(copy, 'op', DemoScenario.Normal)).state === OperationState.Success,
          'Equivalent UI object was rejected');
      }
    }
  ];
}
