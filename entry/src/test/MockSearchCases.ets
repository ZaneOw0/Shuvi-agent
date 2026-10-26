import { MockSearchSession } from '../main/ets/mock/MockSearchSession';
import { SEARCH_SAMPLE, SearchScenario, SearchState, SearchTurn } from '../main/ets/model/SearchModels';
import { MockTestCase } from './MockAssistantCases';

function check(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(message);
  }
}

export function mockSearchCases(): MockTestCase[] {
  return [
    {
      name: '搜索与回答分步完成，来源不重复',
      run: async () => {
        const session = new MockSearchSession(1);
        const states: SearchState[] = [];
        let result: SearchTurn = new SearchTurn('', '', SearchState.Searching);
        await session.start(SEARCH_SAMPLE, SearchScenario.Normal, (turn: SearchTurn) => {
          states.push(turn.state);
          result = turn;
        });
        check(states.join(',') === [SearchState.Searching, SearchState.Answering, SearchState.Complete].join(','),
          'Expected separate search and answer stages');
        check(result.sources.length === 3 && result.sources[0].number === 1 && !session.busy(), 'Expected three sources');
      }
    },
    {
      name: '未知问题不伪造样例答案，空输入与超长输入不启动',
      run: async () => {
        const session = new MockSearchSession(1);
        const states: SearchState[] = [];
        await session.start('今天上海天气如何', SearchScenario.Normal, (turn: SearchTurn) => {
          states.push(turn.state);
          check(turn.sources.length === 0, 'Unsupported query must have no fabricated sources');
        });
        await session.start(' ', SearchScenario.Normal, () => { throw new Error('Empty query accepted'); });
        await session.start('长'.repeat(501), SearchScenario.Normal, () => { throw new Error('Long query accepted'); });
        check(states.length === 1 && states[0] === SearchState.Unsupported, 'Expected an explicit sample limitation');
      }
    },
    {
      name: '空结果、超时与拒绝授权互相区分，均不生成回答',
      run: async () => {
        const scenarios: SearchScenario[] = [SearchScenario.Empty, SearchScenario.Timeout, SearchScenario.Denied];
        const expected: SearchState[] = [SearchState.Empty, SearchState.Failed, SearchState.Denied];
        for (let index = 0; index < scenarios.length; index++) {
          const session = new MockSearchSession(1);
          let result: SearchTurn = new SearchTurn('', '', SearchState.Searching);
          let updates: number = 0;
          await session.start(SEARCH_SAMPLE, scenarios[index], (turn: SearchTurn) => {
            result = turn;
            updates++;
            check(turn.state !== SearchState.Answering && turn.state !== SearchState.Complete, 'Unexpected answer');
          });
          check(result.state === expected[index] && result.sources.length === 0, 'Incorrect error mapping');
          check(index !== 2 || updates === 1, 'Denied request must not enter search stage');
        }
      }
    },
    {
      name: '重复发送被拦截，取消搜索后不追加来源或回答',
      run: async () => {
        const session = new MockSearchSession(5);
        const states: SearchState[] = [];
        const pending = session.start(SEARCH_SAMPLE, SearchScenario.Normal, (turn: SearchTurn) => states.push(turn.state));
        await session.start(SEARCH_SAMPLE, SearchScenario.Normal, () => { throw new Error('Duplicate start accepted'); });
        const cancelled = session.cancel();
        await pending;
        check(cancelled !== undefined && cancelled.state === SearchState.Cancelled && cancelled.sources.length === 0,
          'Expected cancelled search without sources');
        check(states.length === 1 && !session.busy(), 'Late result published after cancellation');
      }
    },
    {
      name: '回答失败保留来源，重试回答不重新搜索',
      run: async () => {
        const session = new MockSearchSession(1);
        let failed: SearchTurn = new SearchTurn('', '', SearchState.Searching);
        await session.start(SEARCH_SAMPLE, SearchScenario.AnswerFailure, (turn: SearchTurn) => failed = turn);
        check(failed.state === SearchState.AnswerFailed && failed.sources.length === 3, 'Missing sources after answer failure');
        const states: SearchState[] = [];
        await session.retryAnswer(failed, (turn: SearchTurn) => {
          states.push(turn.state);
          check(turn.id === failed.id && turn.sources === failed.sources, 'Retry replaced the original sources');
        });
        check(states.join(',') === [SearchState.Answering, SearchState.Complete].join(','), 'Answer retry searched again');
      }
    },
    {
      name: '停止生成保留来源，取消状态不会被迟到完成覆盖',
      run: async () => {
        const session = new MockSearchSession(1);
        let stopped: SearchTurn | undefined = undefined;
        let complete: boolean = false;
        await session.start(SEARCH_SAMPLE, SearchScenario.Normal, (turn: SearchTurn) => {
          if (turn.state === SearchState.Answering) {
            stopped = session.cancel();
          }
          if (turn.state === SearchState.Complete) {
            complete = true;
          }
        });
        check(stopped !== undefined && stopped.sources.length === 3 && stopped.state === SearchState.Cancelled && !complete,
          'Stopped answer lost sources or received a late answer');
      }
    },
    {
      name: '取消旧请求后立即发送新请求，新旧状态隔离',
      run: async () => {
        const session = new MockSearchSession(2);
        const oldStates: SearchState[] = [];
        const newStates: SearchState[] = [];
        const oldTask = session.start(SEARCH_SAMPLE, SearchScenario.Normal, (turn: SearchTurn) => oldStates.push(turn.state));
        session.cancel();
        const newTask = session.start(SEARCH_SAMPLE, SearchScenario.Empty, (turn: SearchTurn) => newStates.push(turn.state));
        await Promise.all([oldTask, newTask]);
        check(oldStates.length === 1 && newStates.join(',') === [SearchState.Searching, SearchState.Empty].join(','),
          'Cancelled task contaminated the next request');
      }
    }
  ];
}
