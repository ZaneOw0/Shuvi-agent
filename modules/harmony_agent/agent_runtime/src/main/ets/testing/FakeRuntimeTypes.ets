export enum FakeTaskScriptKind {
  COMPLETE = 'complete',
  AUTHORIZATION = 'authorization',
  CLARIFICATION = 'clarification',
  RECONCILIATION = 'reconciliation',
  PARTIAL_SUCCESS = 'partialSuccess',
  PAUSABLE = 'pausable'
}

export class FakeTaskScript {
  requestId: string = '';
  kind: FakeTaskScriptKind = FakeTaskScriptKind.COMPLETE;
}

export class FakeAgentRuntimeConfig {
  startTimeMs: number = 1000;
  scripts: FakeTaskScript[] = [];
}
