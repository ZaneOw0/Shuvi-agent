import { SEARCH_SAMPLE, SearchScenario, SearchSource, SearchState, SearchTurn, searchIsBusy } from '../model/SearchModels';

function sampleSources(): SearchSource[] {
  return [
    { number: 1, title: 'ArkUI · 框架概览', url: 'https://developer.huawei.com/consumer/cn/arkui',
      snippet: 'ArkUI 提供声明式 UI 语法、组件与实时预览工具。先从概览了解框架能力，再进入开发入门。此处为固定样例整理的摘要示意，完整内容请查看原文。' },
    { number: 2, title: 'ArkUI · 开发入门', url: 'https://developer.huawei.com/consumer/cn/arkui/devstart',
      snippet: '从 ArkUI 开始构建应用界面，查阅开发指引、API 参考与常见问题。此处为固定摘要示意，具体步骤和版本要求请以原文为准。' },
    { number: 3, title: 'HarmonyOS · 文档中心', url: 'https://developer.huawei.com/consumer/cn/doc',
      snippet: '在文档中心继续查找 ArkTS、ArkUI 及相关开发资源。此处为固定摘要示意，真实搜索的内容和顺序会随查询变化。' }
  ];
}

// 只调度本机定时器。取消会解除等待，并用代次隔离迟到回调；不调用 MCP、模型或网络。
export class MockSearchSession {
  private current: SearchTurn | undefined = undefined;
  private epoch: number = 0;
  private sequence: number = 0;
  private timer: number = -1;
  private finishWait: (() => void) | undefined = undefined;
  private delay: number;

  constructor(delay: number = 1600) {
    this.delay = delay;
  }

  busy(): boolean {
    return this.current !== undefined && searchIsBusy(this.current.state);
  }

  private publish(turn: SearchTurn, update: (turn: SearchTurn) => void): void {
    this.current = turn;
    update(turn);
  }

  private wait(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      this.finishWait = resolve;
      this.timer = setTimeout(() => {
        this.timer = -1;
        this.finishWait = undefined;
        resolve();
      }, this.delay);
    });
  }

  cancel(): SearchTurn | undefined {
    this.epoch++;
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    const finish = this.finishWait;
    this.finishWait = undefined;
    if (finish) {
      finish();
    }
    const turn = this.current;
    if (!turn || !searchIsBusy(turn.state)) {
      return undefined;
    }
    this.current = new SearchTurn(turn.id, turn.query, SearchState.Cancelled, turn.sources);
    return this.current;
  }

  async start(query: string, scenario: SearchScenario, update: (turn: SearchTurn) => void): Promise<void> {
    if (this.busy() || query.trim().length === 0 || query.length > 500) {
      return;
    }
    const epoch = ++this.epoch;
    const id = `search-${++this.sequence}`;
    const text = query.trim();
    if (text !== SEARCH_SAMPLE && text !== 'HarmonyOS ArkUI 官方开发文档') {
      this.publish(new SearchTurn(id, text, SearchState.Unsupported), update);
      return;
    }
    if (scenario === SearchScenario.Denied) {
      this.publish(new SearchTurn(id, text, SearchState.Denied), update);
      return;
    }
    this.publish(new SearchTurn(id, text, SearchState.Searching), update);
    if (epoch !== this.epoch) {
      return;
    }
    await this.wait();
    if (epoch !== this.epoch) {
      return;
    }
    if (scenario === SearchScenario.Empty || scenario === SearchScenario.Timeout) {
      const state = scenario === SearchScenario.Empty ? SearchState.Empty : SearchState.Failed;
      this.publish(new SearchTurn(id, text, state), update);
      return;
    }
    const sources = sampleSources();
    this.publish(new SearchTurn(id, text, SearchState.Answering, sources), update);
    await this.finishAnswer(epoch, id, text, sources, scenario === SearchScenario.AnswerFailure, update);
  }

  async retryAnswer(turn: SearchTurn, update: (turn: SearchTurn) => void): Promise<void> {
    if (this.busy() || turn.sources.length === 0 ||
      (turn.state !== SearchState.AnswerFailed && turn.state !== SearchState.Cancelled)) {
      return;
    }
    const epoch = ++this.epoch;
    this.publish(new SearchTurn(turn.id, turn.query, SearchState.Answering, turn.sources), update);
    await this.finishAnswer(epoch, turn.id, turn.query, turn.sources, false, update);
  }

  private async finishAnswer(epoch: number, id: string, query: string, sources: SearchSource[],
    failed: boolean, update: (turn: SearchTurn) => void): Promise<void> {
    if (epoch !== this.epoch) {
      return;
    }
    await this.wait();
    if (epoch === this.epoch) {
      this.publish(new SearchTurn(id, query, failed ? SearchState.AnswerFailed : SearchState.Complete, sources), update);
    }
  }
}
