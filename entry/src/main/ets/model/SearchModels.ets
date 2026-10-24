// 仅用于页面演示，不是 MCP / Agent 公共契约，也不代表真实授权结果。
export enum SearchState {
  Searching = '正在搜索相关资料',
  Answering = '正在整理回答',
  Complete = '搜索与回答已完成',
  Empty = '暂时没有找到相关资料',
  Failed = '这次搜索没有完成',
  Cancelled = '已停止本次任务',
  Denied = '尚未允许联网搜索',
  AnswerFailed = '回答还没有准备好',
  Unsupported = '请使用搜索样例体验'
}

export enum SearchScenario {
  Normal = '搜索与回答成功',
  Empty = '没有搜索结果',
  Timeout = '搜索超时',
  Denied = '联网授权被拒绝',
  AnswerFailure = '搜索成功，回答失败'
}

export const SEARCH_SCENARIOS: SearchScenario[] = [SearchScenario.Normal, SearchScenario.Empty,
  SearchScenario.Timeout, SearchScenario.Denied, SearchScenario.AnswerFailure];
export const SEARCH_SAMPLE: string = '帮我找一下 ArkUI 的官方开发文档，应该从哪里开始？';

export interface SearchSource {
  number: number;
  title: string;
  url: string;
  snippet: string;
}

export class SearchTurn {
  id: string;
  query: string;
  state: SearchState;
  sources: SearchSource[];

  constructor(id: string, query: string, state: SearchState, sources: SearchSource[] = []) {
    this.id = id;
    this.query = query;
    this.state = state;
    this.sources = sources;
  }
}

export function searchIsBusy(state: SearchState): boolean {
  return state === SearchState.Searching || state === SearchState.Answering;
}

export function searchDetail(turn: SearchTurn): string {
  switch (turn.state) {
    case SearchState.Searching: return '演示查找公开网页，不发起网络请求。';
    case SearchState.Answering: return '已找到 3 条示例来源，正在模拟整理回答。';
    case SearchState.Complete: return '固定样例已展示，你可以展开来源核对。';
    case SearchState.Empty: return '试试更具体的关键词，或减少限制条件。';
    case SearchState.Failed: return '模拟搜索服务连接超时，请稍后重试。';
    case SearchState.Cancelled: return turn.sources.length > 0 ?
      '已停止生成回答，参考来源已保留。' : '搜索已取消，问题已保留，可修改后重新搜索。';
    case SearchState.Denied: return '真实搜索会外发关键词。本次仅演示授权被拒绝的界面。';
    case SearchState.AnswerFailed: return '搜索已完成，参考来源已保留；回答生成失败。';
    case SearchState.Unsupported: return '当前只演示固定的 ArkUI 文档问题，尚未接入真实搜索与模型。';
  }
}
