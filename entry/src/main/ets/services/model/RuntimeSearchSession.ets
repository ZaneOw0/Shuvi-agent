import { AgentRuntimeEventType, AgentTaskStatus } from '@harmony_agent/agent-contracts';
import { AgentFrontendAuthorizationPrompt, AgentFrontendClarificationPrompt, AgentFrontendEvent, AgentFrontendEventListener,
  AgentFrontendSubscription, AgentFrontendTaskRequest } from '@harmony_agent/agent-runtime';
import { ShuviRuntimeController, ShuviRuntimeState } from './ShuviRuntimeController';
import { ShuviRuntimeSessionFactory } from './ShuviRuntimeSession';
import { SearchRuntimeFactory } from './SearchRuntimeAssembly';
import { SearchAuthorizationPreview } from './SearchAuthorizationPreview';
import { LiveSearchSource, SearchAnswerContext, parseLiveSearch, validSearchCitations } from './SearchTaskSupport';
import { parseChatAnswer } from './ChatRuntimeAssembly';

const SEARCH_FULL: string = '本机搜索记录已满，暂时不能继续搜索；旧记录目前不会自动清理。';

export class RuntimeSearchView {
  lifecycle: ShuviRuntimeState = ShuviRuntimeState.IDLE;
  busy: boolean = false;
  stage: string = 'idle';
  message: string = '尚未启用真实搜索。';
  query: string = '';
  answer: string = '';
  sources: LiveSearchSource[] = [];
  preview?: SearchAuthorizationPreview;
  billing: string = '尚未发送搜索请求';
  allowance: boolean = false;
  clearEpoch: number = 0;
}
class SearchListener implements AgentFrontendEventListener {
  private readonly owner: RuntimeSearchSession; private readonly generation: number; private readonly answering: boolean;
  constructor(owner: RuntimeSearchSession, generation: number, answering: boolean) {
    this.owner = owner; this.generation = generation; this.answering = answering;
  }
  onEvent(event: AgentFrontendEvent): void { this.owner.event(this.generation, this.answering, event); }
  onAuthorizationRequired(prompt: AgentFrontendAuthorizationPrompt): void { this.owner.authorization(this.generation, this.answering, prompt); }
  onClarificationRequired(_prompt: AgentFrontendClarificationPrompt): void { this.owner.unexpected(this.generation); }
}

/** Search and answer are two bounded Runtime tasks; source completion is distinct from answer completion. */
export class RuntimeSearchSession {
  readonly search: ShuviRuntimeController = new ShuviRuntimeController();
  readonly model: ShuviRuntimeController = new ShuviRuntimeController();
  readonly context: SearchAnswerContext = new SearchAnswerContext();
  private view: RuntimeSearchView = new RuntimeSearchView();
  private listener?: (view: RuntimeSearchView) => void;
  private factory?: SearchRuntimeFactory;
  private prompt?: AgentFrontendAuthorizationPrompt;
  private generation: number = 0;
  private taskId: string = '';
  private sequence: number = 0;
  private subscription?: AgentFrontendSubscription;
  private timer?: number;
  private deciding: boolean = false;
  private stopping: boolean = false;
  attach(listener: (view: RuntimeSearchView) => void): void { this.listener = listener; this.publish(); }
  detach(): void { this.listener = undefined; void this.stop(); }
  snapshot(): RuntimeSearchView { return copyRuntimeSearchView(this.view); }
  clearConversation(): void {
    if (this.view.busy) return;
    this.context.clear(); this.view.query = ''; this.view.sources = []; this.view.answer = '';
    this.view.stage = 'idle'; this.view.preview = undefined; this.publish();
  }
  private publish(): void { this.listener?.(this.snapshot()); }
  private active(generation: number): boolean { return this.generation === generation && this.view.busy && !this.stopping; }
  onForeground(): void { this.search.onForeground(); this.model.onForeground(); }
  async onBackground(): Promise<void> { await this.stop(); await this.search.onBackground(); await this.model.onBackground(); }
  async onDestroy(): Promise<void> { await this.onBackground(); }
  async start(factory: SearchRuntimeFactory, answerFactory: ShuviRuntimeSessionFactory, key: Uint8Array): Promise<void> {
    if (this.view.lifecycle === ShuviRuntimeState.STARTING || this.view.lifecycle === ShuviRuntimeState.READY || this.stopping) { key.fill(0); return; }
    const generation = ++this.generation; const modelKey = key.slice(); this.factory = factory;
    factory.onOutcomeRejected = (taskId: string): void => {
      if (!this.view.busy || this.taskId !== taskId || this.view.stage === 'answering' || this.stopping) return;
      void this.stopAfterUncertainSearch();
    };
    this.view.lifecycle = ShuviRuntimeState.STARTING; this.view.clearEpoch++; this.view.message = '正在连接搜索服务…'; this.publish();
    try {
      await this.search.start(factory, key);
      if (generation !== this.generation) return;
      await this.model.start(answerFactory, modelKey);
      if (generation !== this.generation) return;
      this.view.lifecycle = ShuviRuntimeState.READY; this.view.allowance = factory.available();
      this.view.message = this.view.allowance ? '已就绪。发送关键词后，仍需确认本次搜索。' : SEARCH_FULL;
      this.publish();
    } catch {
      if (generation === this.generation) {
        await this.stop(); this.view.message = '启动失败。请确认已在「我的 → API Key 管理」保存 Tavily Key，并检查本机存储；未自动调用搜索。';
        if (this.search.lifecycleState() !== ShuviRuntimeState.BLOCKED && this.model.lifecycleState() !== ShuviRuntimeState.BLOCKED) {
          this.view.lifecycle = ShuviRuntimeState.FAILED;
        }
        this.publish();
      }
    } finally { key.fill(0); modelKey.fill(0); }
  }
  private clearWatch(): void {
    if (this.timer !== undefined) clearTimeout(this.timer); this.timer = undefined;
    this.subscription?.close(); this.subscription = undefined;
  }
  private async stopAfterUncertainSearch(): Promise<void> {
    await this.stop();
    if (this.view.lifecycle !== ShuviRuntimeState.STOPPED) return;
    this.view.stage = 'failed';
    this.view.message = '搜索失败或结果未能可靠保存，未生成回答；请核对执行记录与 Tavily 用量。';
    this.view.billing = '执行结果 / 费用待核对（CNY），未记为零'; this.publish();
  }
  async stop(): Promise<void> {
    if (this.stopping) return;
    this.stopping = true; ++this.generation; this.clearWatch(); this.prompt = undefined;
    this.view.preview = undefined; this.view.busy = false; this.view.allowance = false;
    this.view.clearEpoch++; this.view.lifecycle = ShuviRuntimeState.STOPPING;
    this.view.message = '正在停止请求并清理凭据…'; this.context.clear(); this.publish();
    let failed = false;
    try { await this.search.stop(); } catch { failed = true; }
    try { await this.model.stop(); } catch { failed = true; }
    this.factory?.previews.clear(); this.stopping = false;
    this.view.lifecycle = failed ? ShuviRuntimeState.BLOCKED : ShuviRuntimeState.STOPPED;
    this.view.stage = 'stopped'; this.view.message = failed ? '资源关闭未确认，请重启排查；未清除记录。' :
      '会话已停止，已有来源保留；已发送请求可能计费，不自动重试。'; this.publish();
  }
  async send(query: string): Promise<boolean> {
    const value = query.trim();
    if (this.view.busy || this.view.lifecycle !== ShuviRuntimeState.READY || !this.view.allowance || !value || value.length > 500) return false;
    this.context.clear(); this.view.query = value; this.view.sources = []; this.view.answer = ''; this.view.preview = undefined;
    this.view.billing = '尚未发送搜索请求'; this.view.busy = true; this.view.stage = 'preparing';
    this.view.message = '正在准备授权…'; const generation = ++this.generation; this.publish(); this.watch(generation);
    await this.submit(generation, false); return true;
  }
  private watch(generation: number): void {
    this.timer = setTimeout((): void => {
      if (this.active(generation)) void this.stop();
    }, 120000);
  }
  private async submit(generation: number, answering: boolean): Promise<void> {
    const controller = answering ? this.model : this.search;
    this.taskId = ''; this.sequence = 0;
    const request = new AgentFrontendTaskRequest(); request.intent = this.view.query;
    try {
      const handle = await controller.submit(request); if (!this.active(generation)) return;
      this.taskId = handle.taskId;
      const subscription = await controller.subscribe(handle.taskId, new SearchListener(this, generation, answering), 0);
      if (!this.active(generation) || this.taskId !== handle.taskId) { subscription.close(); return; }
      this.subscription = subscription;
      const state = await controller.getTask(handle.taskId);
      if (this.active(generation) && this.taskId === handle.taskId) this.apply(generation, answering, state.status, state.resultJson);
    } catch {
      if (this.active(generation)) {
        this.finish(answering ? 'answerFailed' : 'failed', answering ? '回答未完成，真实来源已保留；可仅重试回答。' :
          '搜索任务未完成，未自动重试。请检查网络和 Tavily Key；费用不能按零计算。');
      }
    }
  }
  event(generation: number, answering: boolean, event: AgentFrontendEvent): void {
    if (!this.active(generation) || event.taskId !== this.taskId || !Number.isSafeInteger(event.sequence) || event.sequence <= this.sequence) return;
    this.sequence = event.sequence;
    if (event.eventType === AgentRuntimeEventType.TASK_COMPLETED) this.apply(generation, answering, AgentTaskStatus.COMPLETED, event.payloadJson);
    else if (event.eventType === AgentRuntimeEventType.TASK_FAILED) this.apply(generation, answering, AgentTaskStatus.FAILED, event.payloadJson);
    else if (event.eventType === AgentRuntimeEventType.TASK_CANCELLED) this.apply(generation, answering, AgentTaskStatus.CANCELLED, event.payloadJson);
  }
  authorization(generation: number, answering: boolean, prompt: AgentFrontendAuthorizationPrompt): void {
    if (!this.active(generation) || prompt.taskId !== this.taskId) return;
    if (answering) { this.unexpected(generation); return; }
    const preview = this.factory?.previews.resolve(prompt, Date.now());
    if (preview === undefined || preview.query !== this.view.query) { this.unexpected(generation); return; }
    this.prompt = prompt; this.view.preview = preview; this.view.stage = 'authorization';
    this.view.message = '请确认下面的真实外发关键词。'; this.publish();
  }
  async decide(approved: boolean): Promise<void> {
    const prompt = this.prompt; const generation = this.generation;
    if (this.deciding || !this.active(generation) || prompt === undefined) return;
    this.deciding = true;
    try {
      const preview = this.factory?.previews.resolve(prompt, Date.now());
      if (approved && preview === undefined) { await this.stop(); return; }
      if (approved) { this.view.billing = '费用待核对（CNY）；失败或取消也不代表免费'; this.view.stage = 'searching'; }
      this.view.preview = undefined; this.publish();
      const receipt = await this.search.authorize(prompt, approved);
      if (!this.active(generation)) return;
      if (!receipt.accepted) { await this.stop(); return; }
      this.prompt = undefined;
      if (!approved) this.finish('denied', '已拒绝本次搜索，未调用工具。');
      else if (this.view.stage === 'searching') { this.view.message = '正在搜索公开资料…'; this.publish(); }
    } catch { if (this.active(generation)) await this.stop(); }
    finally { this.deciding = false; }
  }
  unexpected(generation: number): void { if (this.active(generation)) void this.stop(); }
  private apply(generation: number, answering: boolean, status: AgentTaskStatus, json: string): void {
    if (status === AgentTaskStatus.COMPLETED) {
      if (answering) {
        const answer = parseChatAnswer(json);
        if (answer === undefined || !validSearchCitations(answer.text, this.view.sources.length)) {
          this.finish('answerFailed', '回答格式或引用编号无效，真实来源已保留。');
        }
        else { this.view.answer = answer.text; this.finish('complete', '搜索与回答已完成；搜索费用待核对。'); }
      } else {
        if (this.view.stage === 'answering') return;
        const result = parseLiveSearch(json, this.view.query);
        this.view.allowance = false;
        if (result === undefined) { this.finish('failed', '搜索结果未通过校验，未生成回答。'); return; }
        this.view.sources = result.results; this.view.billing = '搜索结果已保存，费用待核对（CNY）';
        if (result.results.length === 0) { this.finish('empty', '搜索已完成，未找到来源；不调用模型。'); return; }
        if (!this.context.set(json, this.view.query)) { this.finish('answerFailed', '来源无法交给模型，已保留结果。'); return; }
        this.subscription?.close(); this.subscription = undefined;
        this.view.stage = 'answering'; this.view.message = '真实来源已保存，正在整理回答…'; this.publish();
        // A new generation isolates all late events and synchronous subscription replay from the search task.
        this.clearWatch(); const next = ++this.generation; this.watch(next); void this.submit(next, true);
      }
    } else if (status === AgentTaskStatus.FAILED || status === AgentTaskStatus.CANCELLED) {
      if (!answering && this.view.stage === 'authorization' && this.deciding && this.view.billing === '尚未发送搜索请求') {
        this.finish('denied', '已拒绝本次搜索，未调用工具。'); return;
      }
      this.finish(answering ? 'answerFailed' : 'failed', answering ? '回答未完成，真实来源已保留；可仅重试回答。' :
        '搜索未完成或已取消，未自动重试；费用和执行结果需核对。');
    }
  }
  private finish(stage: string, message: string): void {
    this.clearWatch(); ++this.generation; this.view.busy = false; this.view.stage = stage; this.view.message = message;
    this.view.preview = undefined; this.prompt = undefined;
    this.factory?.previews.forgetTask(this.taskId);
    try { this.view.allowance = this.factory?.available() === true; } catch { this.view.allowance = false; }
    if (!this.view.allowance && this.view.lifecycle === ShuviRuntimeState.READY) this.view.message = message + SEARCH_FULL;
    this.publish();
  }
  async retryAnswer(): Promise<void> {
    if (this.view.busy || this.view.lifecycle !== ShuviRuntimeState.READY || this.view.stage !== 'answerFailed' || this.view.sources.length === 0) return;
    this.view.busy = true; this.view.stage = 'answering'; this.view.message = '仅重试模型回答，不再次搜索。';
    const generation = ++this.generation; this.watch(generation); this.publish(); await this.submit(generation, true);
  }
}

function copyRuntimeSearchView(value: RuntimeSearchView): RuntimeSearchView {
  const copy = new RuntimeSearchView();
  copy.lifecycle = value.lifecycle;
  copy.busy = value.busy;
  copy.stage = value.stage;
  copy.message = value.message;
  copy.query = value.query;
  copy.answer = value.answer;
  copy.sources = value.sources.map((item: LiveSearchSource): LiveSearchSource => copyLiveSearchSource(item));
  if (value.preview !== undefined) copy.preview = copySearchAuthorizationPreview(value.preview);
  copy.billing = value.billing;
  copy.allowance = value.allowance;
  copy.clearEpoch = value.clearEpoch;
  return copy;
}

function copyLiveSearchSource(value: LiveSearchSource): LiveSearchSource {
  const copy = new LiveSearchSource();
  copy.title = value.title;
  copy.url = value.url;
  copy.snippet = value.snippet;
  return copy;
}

function copySearchAuthorizationPreview(value: SearchAuthorizationPreview): SearchAuthorizationPreview {
  const copy = new SearchAuthorizationPreview();
  copy.requestId = value.requestId;
  copy.taskId = value.taskId;
  copy.stepId = value.stepId;
  copy.operationId = value.operationId;
  copy.argumentsDigest = value.argumentsDigest;
  copy.query = value.query;
  copy.maxResults = value.maxResults;
  copy.estimatedCostMicros = value.estimatedCostMicros;
  copy.requestedAt = value.requestedAt;
  copy.expiresAt = value.expiresAt;
  copy.expiresAtMs = value.expiresAtMs;
  return copy;
}
