import { describe, expect, it } from '@ohos/hypium';
import {
  ClarificationResponse,
  CollaborationMode,
  PrivacyClass,
  TaskEnvelope,
  TaskFrame,
  WorkflowGraph
} from '@harmony_agent/agent-contracts';
import {
  CollaborationPlan,
  CollaborationRoleAssignment,
  ModelRegistryEntry,
  PlanningMemoryContextItem,
  PlanningMemoryContextPort,
  PlanningMemoryContextRequest,
  PlanningMemoryContextResult,
  PlanningRequest,
  PlanningResult,
  PlanningStatus,
  RuntimeClockPort,
  RuntimeIdGeneratorPort
} from '@harmony_agent/agent-runtime';
import {
  ConnectorDigestPort,
  CollaborativeProviderSemanticPlanner,
  ModelInvocation,
  ModelProvider,
  ModelProviderProfile,
  ModelProviderResult,
  ProviderCancellationSignalPort,
  ProviderCapabilityKind,
  ProviderCatalog,
  ProviderFinishReason,
  ProviderPlanningPhase,
  ProviderPlannerTrace,
  ProviderPriceSnapshot,
  ProviderSemanticPlanner,
  ProviderSemanticPlannerConfig,
  ProviderSemanticPlannerError,
  ProviderSemanticPlannerErrorCode,
  ProviderSemanticPlannerObserverPort,
  ProviderUsage,
  RegisteredModelProvider
} from '../../Index';

class FixtureDigest implements ConnectorDigestPort {
  digest(value: string): string {
    return 'digest:' + value;
  }
}

class FixtureRuntimeClock implements RuntimeClockPort {
  nowMs(): number {
    return 1798761600000;
  }
}

class FixtureRuntimeIds implements RuntimeIdGeneratorPort {
  private sequence: number = 0;

  nextId(kind: string, requestId: string): string {
    this.sequence++;
    return kind + '-' + requestId + '-' + this.sequence.toString();
  }
}

class EmptyRuntimeIds implements RuntimeIdGeneratorPort {
  nextId(_kind: string, _requestId: string): string {
    return '';
  }
}

class FixturePlannerObserver implements ProviderSemanticPlannerObserverPort {
  traces: ProviderPlannerTrace[] = [];
  fail: boolean = false;

  onGenerationCompleted(trace: ProviderPlannerTrace): void {
    this.traces.push(trace);
    if (this.fail) throw new Error('observer failure');
  }
}

class FixturePlanningMemoryContext implements PlanningMemoryContextPort {
  calls: number = 0;
  fail: boolean = false;
  lastRequest?: PlanningMemoryContextRequest;
  result: PlanningMemoryContextResult = memoryResult();

  retrieve(request: PlanningMemoryContextRequest): PlanningMemoryContextResult {
    this.calls++;
    this.lastRequest = request;
    if (this.fail) throw new Error('memory unavailable');
    return this.result;
  }
}

class FixturePlannerProvider implements ModelProvider {
  readonly registered: RegisteredModelProvider;
  calls: number = 0;
  lastRequest?: ModelInvocation;
  requests: ModelInvocation[] = [];
  outputJson: string = readyOutput();
  finishReason: ProviderFinishReason = ProviderFinishReason.STOP;
  fail: boolean = false;
  mismatchRegistry: boolean = false;
  mismatchTrace: boolean = false;
  invalidUsage: boolean = false;
  waitForCancellation: boolean = false;
  cancellationObserved: boolean = false;
  entered: Promise<void>;
  private enteredResolve?: () => void;

  constructor(registered: RegisteredModelProvider) {
    this.registered = registered;
    this.entered = new Promise<void>((resolve: () => void): void => {
      this.enteredResolve = resolve;
    });
  }

  registryEntry(estimatedInputTokens: number, estimatedOutputTokens: number): ModelRegistryEntry {
    const result: ModelRegistryEntry = this.registered.registryEntry(estimatedInputTokens, estimatedOutputTokens);
    if (this.mismatchRegistry) result.modelVersion = 'unexpected-version';
    return result;
  }

  async generate(request: ModelInvocation,
    cancellation: ProviderCancellationSignalPort): Promise<ModelProviderResult> {
    this.calls++;
    this.lastRequest = request;
    this.requests.push(request);
    if (this.waitForCancellation) {
      const entered: (() => void) | undefined = this.enteredResolve;
      if (entered !== undefined) entered();
      return await new Promise<ModelProviderResult>((_resolve: (value: ModelProviderResult) => void,
        reject: (reason: Object) => void): void => {
        cancellation.subscribe((): void => {
          this.cancellationObserved = true;
          reject(new Error('provider cancelled'));
        });
      });
    }
    if (this.fail) throw new Error('provider unavailable');
    const profile: ModelProviderProfile = this.registered.profileSnapshot();
    const price: ProviderPriceSnapshot = this.registered.priceSnapshot();
    const result: ModelProviderResult = new ModelProviderResult();
    result.requestId = this.mismatchTrace ? 'unexpected-request' : request.context.requestId;
    result.outputJson = this.outputJson;
    result.finishReason = this.finishReason;
    result.modelId = profile.registryModelId;
    result.modelVersion = profile.modelVersion;
    result.region = profile.region;
    result.priceSnapshotId = price.snapshotId;
    result.usage.inputTokens = 100;
    result.usage.outputTokens = 20;
    result.usage.totalTokens = this.invalidUsage ? 121 : 120;
    result.usage.providerReportedCostMicros = 143;
    result.usage.settledCostMicros = 143;
    return result;
  }
}

function modelProfile(): ModelProviderProfile {
  const result: ModelProviderProfile = new ModelProviderProfile();
  result.registryModelId = 'model/planner';
  result.providerId = 'provider-planner';
  result.providerModelId = 'provider-model-v1';
  result.modelVersion = '2026-10';
  result.region = 'local';
  result.capabilityKind = ProviderCapabilityKind.MODEL;
  result.capabilityTags = ['planning', 'json'];
  result.privacyClasses = [PrivacyClass.PERSONAL];
  result.maxInputTokens = 8192;
  result.maxOutputTokens = 1024;
  result.qualityTier = 2;
  result.credentialScope = 'planner.invoke';
  result.available = true;
  return result;
}

function priceSnapshot(): ProviderPriceSnapshot {
  const result: ProviderPriceSnapshot = new ProviderPriceSnapshot();
  result.snapshotId = 'planner-price-v1';
  result.providerId = 'provider-planner';
  result.capabilityId = 'provider-model-v1';
  result.capabilityVersion = '2026-10';
  result.region = 'local';
  result.currency = 'USD';
  result.inputMicrosPerMillionTokens = 1000000;
  result.outputMicrosPerMillionTokens = 2000000;
  result.fixedCostMicros = 3;
  result.effectiveAt = '2026-10-01T00:00:00.000Z';
  result.snapshotDigest = 'planner-price-digest-v1';
  return result;
}

function registeredModel(): RegisteredModelProvider {
  const catalog: ProviderCatalog = new ProviderCatalog(new FixtureDigest());
  expect(catalog.registerModel(modelProfile(), priceSnapshot())).assertTrue();
  return catalog.getModel('model/planner') as RegisteredModelProvider;
}

function plannerConfig(): ProviderSemanticPlannerConfig {
  const result: ProviderSemanticPlannerConfig = new ProviderSemanticPlannerConfig();
  result.promptVersion = 'typed-workflow-v1';
  result.estimatedInputTokens = 100;
  result.maxOutputTokens = 512;
  result.temperature = 0;
  result.timeoutMs = 10000;
  result.clarificationTtlMs = 60000;
  result.maxSteps = 8;
  result.maxPromptCharacters = 20000;
  return result;
}

function memoryPlannerConfig(): ProviderSemanticPlannerConfig {
  const result: ProviderSemanticPlannerConfig = plannerConfig();
  result.maxMemoryItems = 2;
  result.maxMemoryCharacters = 64;
  return result;
}

function planningRequest(): PlanningRequest {
  const envelope: TaskEnvelope = new TaskEnvelope();
  envelope.requestId = 'request-1';
  envelope.taskId = 'task-1';
  envelope.sessionId = 'session-1';
  envelope.userId = 'user-1';
  envelope.userIntent = 'Prepare a safe typed plan';
  envelope.locale = 'en-US';
  envelope.timeZone = 'UTC';
  envelope.referenceTime = '2027-01-01T00:00:00.000Z';
  envelope.createdAt = '2027-01-01T00:00:00.000Z';
  envelope.privacyClass = PrivacyClass.PERSONAL;
  envelope.executionBudget.maxWallTimeMs = 30000;
  envelope.executionBudget.maxInputTokens = 2000;
  envelope.executionBudget.maxOutputTokens = 256;
  envelope.executionBudget.maxMonetaryCostMicros = 10000;
  envelope.executionBudget.maxToolCalls = 4;
  envelope.executionBudget.maxAgentActivations = 4;
  envelope.executionBudget.maxRetries = 1;
  envelope.executionBudget.maxReplans = 1;
  const frame: TaskFrame = new TaskFrame();
  frame.taskId = envelope.taskId;
  frame.goal = 'Create the workflow';
  frame.capabilityCategories = ['reasoning'];
  const result: PlanningRequest = new PlanningRequest();
  result.envelope = envelope;
  result.frame = frame;
  result.collaborationMode = CollaborationMode.SINGLE;
  return result;
}

function fullDigest(character: string): string {
  return 'sha256:' + character.repeat(64);
}

function memoryResult(): PlanningMemoryContextResult {
  const result: PlanningMemoryContextResult = new PlanningMemoryContextResult();
  result.taskId = 'task-1';
  result.ownerId = 'user-1';
  const item: PlanningMemoryContextItem = new PlanningMemoryContextItem();
  item.memoryId = 'memory-1';
  item.chunkId = 'memory-1:v1:c0';
  item.memoryVersion = 1;
  item.content = 'Prefer morning meetings';
  item.tags = ['preference'];
  result.items.push(item);
  result.totalCharacters = item.content.length;
  return result;
}

function multiPlanningRequest(): PlanningRequest {
  const request: PlanningRequest = planningRequest();
  request.collaborationMode = CollaborationMode.MULTI;
  request.envelope.executionBudget.maxOutputTokens = 2048;
  const plan: CollaborationPlan = new CollaborationPlan();
  plan.taskId = request.envelope.taskId;
  plan.mode = CollaborationMode.MULTI;
  plan.roleRegistryDigest = fullDigest('a');
  plan.decisionDigest = fullDigest('b');
  const plannerRole: CollaborationRoleAssignment = new CollaborationRoleAssignment();
  plannerRole.roleId = 'planner';
  plannerRole.roleVersion = '1';
  plannerRole.roleRegistryDigest = fullDigest('c');
  plan.assignments.push(plannerRole);
  const verifierRole: CollaborationRoleAssignment = new CollaborationRoleAssignment();
  verifierRole.roleId = 'verifier';
  verifierRole.roleVersion = '1';
  verifierRole.roleRegistryDigest = fullDigest('d');
  plan.assignments.push(verifierRole);
  request.collaborationPlan = plan;
  return request;
}

function readyOutput(): string {
  return '{"status":"ready","workflow":{"entryStepIds":["step-1"],"steps":[' +
    '{"stepId":"step-1","kind":"llm","goal":"Produce a typed result","dependencies":[],' +
    '"inputBindings":[],"expectedOutputSchemaJson":"{\\"type\\":\\"object\\"}",' +
    '"capabilityRequirements":["reasoning"],"sideEffect":"none","riskLevel":"low",' +
    '"permissionRequirements":[],"idempotencyMode":"none","timeoutMs":1000,' +
    '"retryPolicyRef":"retry-v1","verificationPolicyRef":"verify-v1"}]}}';
}

function clarificationOutput(): string {
  return '{"status":"clarificationRequired","clarification":{"questionCode":"DESTINATION_REQUIRED",' +
    '"prompt":"Which destination should be used?","responseSchemaJson":"{\\"type\\":\\"object\\"}"}}';
}

function planner(provider: FixturePlannerProvider,
  observer: ProviderSemanticPlannerObserverPort = new FixturePlannerObserver(),
  config: ProviderSemanticPlannerConfig = plannerConfig(),
  memoryContext?: PlanningMemoryContextPort): ProviderSemanticPlanner {
  return new ProviderSemanticPlanner(provider.registered, provider, config, new FixtureRuntimeClock(),
    new FixtureRuntimeIds(), observer, memoryContext);
}

export default function providerSemanticPlannerTest(): void {
  describe('ProviderSemanticPlanner', () => {
    it('buildsTrustedWorkflowFromPinnedProviderInvocationAndSafeTrace', 0, async () => {
      const provider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const observer: FixturePlannerObserver = new FixturePlannerObserver();
      const result: PlanningResult = await planner(provider, observer).plan(planningRequest());

      expect(result.status).assertEqual(PlanningStatus.READY);
      expect(result.workflow?.taskId).assertEqual('task-1');
      expect(result.workflow?.workflowId.startsWith('workflow-request-1-')).assertTrue();
      expect(result.workflow?.workflowVersion).assertEqual('1');
      expect(result.workflow?.createdAt).assertEqual('2027-01-01T00:00:00.000Z');
      expect(provider.lastRequest?.modelId).assertEqual('model/planner');
      expect(provider.lastRequest?.modelVersion).assertEqual('2026-10');
      expect(provider.lastRequest?.context.providerId).assertEqual('provider-planner');
      expect(provider.lastRequest?.context.priceSnapshotId).assertEqual('planner-price-v1');
      expect(provider.lastRequest?.maxOutputTokens).assertEqual(256);
      expect(provider.lastRequest?.responseSchemaJson.includes('clarificationRequired')).assertTrue();
      expect(provider.lastRequest?.responseSchemaJson.includes('entryStepIds')).assertTrue();
      expect(provider.lastRequest?.messages[1].content.includes('responseContract=')).assertTrue();
      expect(provider.lastRequest?.messages[1].content.includes('never return those fields')).assertTrue();
      expect(observer.traces.length).assertEqual(1);
      expect(observer.traces[0].usage.totalTokens).assertEqual(120);
      const traceText: string = JSON.stringify(observer.traces[0]);
      expect(traceText.includes('Prepare a safe typed plan')).assertFalse();
      expect(traceText.includes('Produce a typed result')).assertFalse();
    });

    it('createsTrustedClarificationAndPreservesWorkflowIdentityOnReplan', 0, async () => {
      const provider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      provider.outputJson = clarificationOutput();
      const adapter: ProviderSemanticPlanner = planner(provider);
      const request: PlanningRequest = planningRequest();
      const clarification: PlanningResult = await adapter.plan(request);
      expect(clarification.status).assertEqual(PlanningStatus.CLARIFICATION_REQUIRED);
      expect(clarification.clarification?.taskId).assertEqual('task-1');
      expect(clarification.clarification?.expiresAtMs).assertEqual(1798761660000);

      const response: ClarificationResponse = new ClarificationResponse();
      response.taskId = 'task-1';
      response.answerJson = '{"destination":"local"}';
      provider.outputJson = readyOutput();
      const resumed: PlanningResult = await adapter.resume(request, response);
      expect(resumed.status).assertEqual(PlanningStatus.READY);
      expect(provider.lastRequest?.messages[1].content.includes('clarificationResponse=')).assertTrue();

      request.previousWorkflow = resumed.workflow;
      request.affectedStepIds = ['step-1'];
      const previousId: string = (resumed.workflow as WorkflowGraph).workflowId;
      const replanned: PlanningResult = await adapter.replan(request);
      expect(replanned.status).assertEqual(PlanningStatus.READY);
      expect(replanned.workflow?.workflowId).assertEqual(previousId);
      expect(replanned.workflow?.workflowVersion === '1').assertFalse();
      expect(provider.lastRequest?.messages[1].content.includes('step-1')).assertTrue();
    });

    it('rejectsPrivacyTokenCostAndPromptPrechecksWithoutCallingProvider', 0, async () => {
      const privacyProvider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const privacyRequest: PlanningRequest = planningRequest();
      privacyRequest.envelope.privacyClass = PrivacyClass.SENSITIVE;
      const privacy: PlanningResult = await planner(privacyProvider).plan(privacyRequest);
      expect(privacy.rejectionCode).assertEqual('PLANNER_PRIVACY_NOT_SUPPORTED');
      expect(privacyProvider.calls).assertEqual(0);

      const inputProvider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const inputRequest: PlanningRequest = planningRequest();
      inputRequest.envelope.executionBudget.maxInputTokens = 99;
      const input: PlanningResult = await planner(inputProvider).plan(inputRequest);
      expect(input.rejectionCode).assertEqual('PLANNER_INPUT_BUDGET_EXCEEDED');
      expect(inputProvider.calls).assertEqual(0);

      const tokenProvider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const tokenRequest: PlanningRequest = planningRequest();
      tokenRequest.envelope.executionBudget.maxOutputTokens = 0;
      const token: PlanningResult = await planner(tokenProvider).plan(tokenRequest);
      expect(token.rejectionCode).assertEqual('PLANNER_OUTPUT_BUDGET_EXHAUSTED');
      expect(tokenProvider.calls).assertEqual(0);

      const costProvider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const costRequest: PlanningRequest = planningRequest();
      costRequest.envelope.executionBudget.maxMonetaryCostMicros = 1;
      const cost: PlanningResult = await planner(costProvider).plan(costRequest);
      expect(cost.rejectionCode).assertEqual('PLANNER_COST_BUDGET_EXCEEDED');
      expect(costProvider.calls).assertEqual(0);

      const promptProvider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const smallConfig: ProviderSemanticPlannerConfig = plannerConfig();
      smallConfig.maxPromptCharacters = 10;
      const prompt: PlanningResult = await planner(promptProvider, new FixturePlannerObserver(), smallConfig)
        .plan(planningRequest());
      expect(prompt.rejectionCode).assertEqual('PLANNER_PROMPT_TOO_LARGE');
      expect(promptProvider.calls).assertEqual(0);
    });

    it('failsClosedForMalformedMixedCyclicIncompleteAndMismatchedProviderOutputs', 0, async () => {
      const provider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const adapter: ProviderSemanticPlanner = planner(provider);
      provider.outputJson = '{"status":"ready","workflow":{},"unexpected":true}';
      expect((await adapter.plan(planningRequest())).rejectionCode).assertEqual('PLANNER_OUTPUT_INVALID');

      provider.outputJson = readyOutput().replace('"entryStepIds"',
        '"workflowId":"provider-controlled","entryStepIds"');
      expect((await adapter.plan(planningRequest())).rejectionCode).assertEqual('PLANNER_WORKFLOW_INVALID');

      provider.outputJson = '{"status":"ready","workflow":{"entryStepIds":[],"steps":[' +
        '{"stepId":"step-1","kind":"llm","goal":"cycle","dependencies":["step-1"],' +
        '"inputBindings":[],"expectedOutputSchemaJson":"{}","capabilityRequirements":["reasoning"],' +
        '"sideEffect":"none","riskLevel":"low","permissionRequirements":[],"idempotencyMode":"none",' +
        '"timeoutMs":1000,"retryPolicyRef":"retry-v1","verificationPolicyRef":"verify-v1"}]}}';
      expect((await adapter.plan(planningRequest())).rejectionCode).assertEqual('PLANNER_WORKFLOW_INVALID');

      const ready: string = readyOutput();
      provider.outputJson = ready.substring(0, ready.length - 1) + ',"clarification":{}}';
      expect((await adapter.plan(planningRequest())).rejectionCode).assertEqual('PLANNER_OUTPUT_INVALID');

      provider.outputJson = readyOutput();
      provider.finishReason = ProviderFinishReason.LENGTH;
      expect((await adapter.plan(planningRequest())).rejectionCode).assertEqual('PLANNER_PROVIDER_INCOMPLETE');
      provider.finishReason = ProviderFinishReason.STOP;
      provider.mismatchTrace = true;
      expect((await adapter.plan(planningRequest())).rejectionCode).assertEqual('PLANNER_PROVIDER_TRACE_MISMATCH');
      provider.mismatchTrace = false;
      provider.invalidUsage = true;
      expect((await adapter.plan(planningRequest())).rejectionCode).assertEqual('PLANNER_PROVIDER_TRACE_MISMATCH');
    });

    it('keepsProviderFailureVisibleAndObserverFailureIsolated', 0, async () => {
      const failingProvider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      failingProvider.fail = true;
      let failure: string = '';
      try {
        await planner(failingProvider).plan(planningRequest());
      } catch (error) {
        failure = (error as Error).message;
      }
      expect(failure).assertEqual('provider unavailable');

      const observerProvider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const observer: FixturePlannerObserver = new FixturePlannerObserver();
      observer.fail = true;
      const result: PlanningResult = await planner(observerProvider, observer).plan(planningRequest());
      expect(result.status).assertEqual(PlanningStatus.READY);
      expect(observer.traces.length).assertEqual(1);
    });

    it('rejectsProviderIdentityMismatchAtCompositionTime', 0, async () => {
      const provider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      provider.mismatchRegistry = true;
      let code: ProviderSemanticPlannerErrorCode = ProviderSemanticPlannerErrorCode.INVALID_CONFIGURATION;
      try {
        planner(provider);
      } catch (error) {
        if (error instanceof ProviderSemanticPlannerError) code = error.code;
      }
      expect(code).assertEqual(ProviderSemanticPlannerErrorCode.PROVIDER_IDENTITY_MISMATCH);
      expect(provider.calls).assertEqual(0);

      const idProvider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const invalidIds: ProviderSemanticPlanner = new ProviderSemanticPlanner(idProvider.registered, idProvider,
        plannerConfig(), new FixtureRuntimeClock(), new EmptyRuntimeIds());
      const result: PlanningResult = await invalidIds.plan(planningRequest());
      expect(result.rejectionCode).assertEqual('PLANNER_RUNTIME_ID_INVALID');
      expect(idProvider.calls).assertEqual(0);
    });

    it('executesOneAuditableProviderRequestPerRegisteredRole', 0, async () => {
      const provider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const observer: FixturePlannerObserver = new FixturePlannerObserver();
      const collaborative: CollaborativeProviderSemanticPlanner =
        new CollaborativeProviderSemanticPlanner(planner(provider, observer));

      const result: PlanningResult = await collaborative.plan(multiPlanningRequest());

      expect(result.status).assertEqual(PlanningStatus.READY);
      expect(provider.calls).assertEqual(2);
      expect(observer.traces.length).assertEqual(2);
      expect(observer.traces[0].roleId).assertEqual('planner');
      expect(observer.traces[1].roleId).assertEqual('verifier');
      expect(observer.traces[0].phase).assertEqual(ProviderPlanningPhase.PLAN);
      expect(observer.traces[1].phase).assertEqual(ProviderPlanningPhase.REPLAN);
      expect(observer.traces[0].agentActivationId === observer.traces[1].agentActivationId).assertFalse();
      expect(observer.traces[0].collaborationDecisionDigest).assertEqual(fullDigest('b'));
      expect(provider.requests[0].messages[1].content.includes('"roleId":"planner"')).assertTrue();
      expect(provider.requests[1].messages[1].content.includes('"roleId":"verifier"')).assertTrue();
      expect(provider.requests[1].messages[1].content.includes('phase=replan')).assertTrue();
      expect(provider.requests[1].messages[1].content.includes('previousWorkflow')).assertTrue();
    });

    it('rejectsAggregateCollaborationBudgetBeforeProviderCalls', 0, async () => {
      const provider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const collaborative: CollaborativeProviderSemanticPlanner =
        new CollaborativeProviderSemanticPlanner(planner(provider));
      const request: PlanningRequest = multiPlanningRequest();
      request.envelope.executionBudget.maxOutputTokens = 512;

      const result: PlanningResult = await collaborative.plan(request);

      expect(result.status).assertEqual(PlanningStatus.REJECTED);
      expect(result.rejectionCode).assertEqual('COLLABORATION_OUTPUT_BUDGET_EXCEEDED');
      expect(provider.calls).assertEqual(0);
    });

    it('rejectsRoleOutsideBoundCollaborationPlanBeforeProviderCalls', 0, async () => {
      const provider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const request: PlanningRequest = multiPlanningRequest();
      const unregistered: CollaborationRoleAssignment = new CollaborationRoleAssignment();
      unregistered.roleId = 'unregistered';
      unregistered.roleVersion = '1';
      unregistered.roleRegistryDigest = fullDigest('e');

      const result: PlanningResult = await planner(provider).planForRole(request, unregistered);

      expect(result.status).assertEqual(PlanningStatus.REJECTED);
      expect(result.rejectionCode).assertEqual('PLANNER_ROLE_BINDING_INVALID');
      expect(provider.calls).assertEqual(0);
    });

    it('addsBoundedOwnerScopedMemoryToTheProviderPrompt', 0, async () => {
      const provider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const memory: FixturePlanningMemoryContext = new FixturePlanningMemoryContext();
      const observer: FixturePlannerObserver = new FixturePlannerObserver();

      const result: PlanningResult = await planner(
        provider, observer, memoryPlannerConfig(), memory).plan(planningRequest());

      expect(result.status).assertEqual(PlanningStatus.READY);
      expect(memory.calls).assertEqual(1);
      expect(memory.lastRequest?.taskId).assertEqual('task-1');
      expect(memory.lastRequest?.ownerId).assertEqual('user-1');
      if (memory.lastRequest !== undefined) {
        expect(memory.lastRequest.queryTerms.indexOf('Prepare a safe typed plan') >= 0).assertTrue();
        expect(memory.lastRequest.queryTerms.indexOf('Create the workflow') >= 0).assertTrue();
      }
      expect(provider.lastRequest?.messages[1].content.includes('memoryContext=')).assertTrue();
      expect(provider.lastRequest?.messages[1].content.includes('Prefer morning meetings')).assertTrue();
      expect(JSON.stringify(observer.traces[0]).includes('Prefer morning meetings')).assertFalse();
    });

    it('failsClosedForMemoryFailureOrIdentityMismatchBeforeProviderCall', 0, async () => {
      const unavailableProvider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const unavailable: FixturePlanningMemoryContext = new FixturePlanningMemoryContext();
      unavailable.fail = true;
      const failed: PlanningResult = await planner(unavailableProvider, new FixturePlannerObserver(),
        memoryPlannerConfig(), unavailable).plan(planningRequest());
      expect(failed.rejectionCode).assertEqual('PLANNER_MEMORY_CONTEXT_FAILED');
      expect(unavailableProvider.calls).assertEqual(0);

      const mismatchProvider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const mismatch: FixturePlanningMemoryContext = new FixturePlanningMemoryContext();
      mismatch.result.ownerId = 'another-user';
      const rejected: PlanningResult = await planner(mismatchProvider, new FixturePlannerObserver(),
        memoryPlannerConfig(), mismatch).plan(planningRequest());
      expect(rejected.rejectionCode).assertEqual('PLANNER_MEMORY_CONTEXT_FAILED');
      expect(mismatchProvider.calls).assertEqual(0);
    });

    it('accountsMemoryCharactersAgainstInputAndCostBudgets', 0, async () => {
      const provider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const memory: FixturePlanningMemoryContext = new FixturePlanningMemoryContext();
      const request: PlanningRequest = planningRequest();
      request.envelope.executionBudget.maxInputTokens = 110;

      const result: PlanningResult = await planner(provider, new FixturePlannerObserver(),
        memoryPlannerConfig(), memory).plan(request);

      expect(result.rejectionCode).assertEqual('PLANNER_INPUT_BUDGET_EXCEEDED');
      expect(provider.calls).assertEqual(0);
    });

    it('interruptsOnlyTheBoundInFlightProviderRequestAndReleasesRegistration', 0, async () => {
      const provider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      provider.waitForCancellation = true;
      const semantic: ProviderSemanticPlanner = planner(provider, new FixturePlannerObserver());
      const pending: Promise<PlanningResult> = semantic.plan(planningRequest());
      await provider.entered;
      expect(semantic.interrupt('another-task')).assertFalse();
      expect(semantic.interrupt('task-1')).assertTrue();
      let rejected: boolean = false;
      try {
        await pending;
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
      expect(provider.cancellationObserved).assertTrue();
      expect(semantic.interrupt('task-1')).assertFalse();
    });

    it('requiresMemoryPortAndBudgetsToBeConfiguredTogether', 0, () => {
      const provider: FixturePlannerProvider = new FixturePlannerProvider(registeredModel());
      const memory: FixturePlanningMemoryContext = new FixturePlanningMemoryContext();
      let missingBudgetRejected: boolean = false;
      try {
        planner(provider, new FixturePlannerObserver(), plannerConfig(), memory);
      } catch (error) {
        missingBudgetRejected = error instanceof ProviderSemanticPlannerError &&
          error.code === ProviderSemanticPlannerErrorCode.INVALID_CONFIGURATION;
      }
      expect(missingBudgetRejected).assertTrue();

      let missingPortRejected: boolean = false;
      try {
        planner(provider, new FixturePlannerObserver(), memoryPlannerConfig());
      } catch (error) {
        missingPortRejected = error instanceof ProviderSemanticPlannerError &&
          error.code === ProviderSemanticPlannerErrorCode.INVALID_CONFIGURATION;
      }
      expect(missingPortRejected).assertTrue();
    });
  });
}
