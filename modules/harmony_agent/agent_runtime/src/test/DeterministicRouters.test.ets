import { describe, expect, it } from '@ohos/hypium';
import {
  CollaborationMode,
  DataBoundary,
  PrivacyClass,
  RiskLevel,
  RouterDecision,
  RouterKind,
  RouterRequest,
  SideEffect,
  TaskFrame,
  ToolDescriptor,
  ToolSourceType,
  WorkflowGraph,
  WorkflowStep,
  WorkflowStepKind
} from '@harmony_agent/agent-contracts';
import {
  ModelRegistry,
  RoleRegistry,
  ToolRegistry,
  WorkflowRegistry
} from '../main/ets/registry/Registries';
import {
  ModelRegistryEntry,
  RegistryWriteCode,
  RoleRegistryEntry,
  ToolRegistryEntry,
  WorkflowRegistryEntry
} from '../main/ets/registry/RegistryTypes';
import {
  DeterministicCollaborationRouter,
  DeterministicContextRouter,
  DeterministicModelRouter,
  DeterministicToolRouter
} from '../main/ets/routing/DeterministicRouters';
import {
  CollaborationRouteRequest,
  ContextCandidate,
  ContextRouteRequest,
  ContextSourceKind,
  DeterministicRouterConfig,
  LearnedRouterPort,
  ModelRouteRequest,
  ToolRouteRequest
} from '../main/ets/routing/RouterTypes';
import { CollaborationPlan } from '../main/ets/orchestration/OrchestrationTypes';
import { CollaborationPlanDigestPort } from '../main/ets/orchestration/RuntimePorts';
import { CollaborationPlanValidator } from '../main/ets/orchestration/CollaborationPlanValidator';

class FixtureCollaborationDigest implements CollaborationPlanDigestPort {
  digest(value: string): string {
    let sum: number = 0;
    for (let i: number = 0; i < value.length; i++) sum = (sum + value.charCodeAt(i)) % 16;
    return 'sha256:' + '0123456789abcdef'.charAt(sum).repeat(64);
  }
}

function config(learned: boolean = false): DeterministicRouterConfig {
  const value: DeterministicRouterConfig = new DeterministicRouterConfig();
  value.policyVersion = 'router-policy-v1';
  value.artifactDigest = 'sha256:deterministic-router';
  value.learnedEnabled = learned;
  value.minimumLearnedConfidence = 0.8;
  return value;
}

function model(id: string, quality: number = 1, cost: number = 10): ModelRegistryEntry {
  const value: ModelRegistryEntry = new ModelRegistryEntry();
  value.modelId = id;
  value.providerId = 'provider-' + id;
  value.modelVersion = '1';
  value.registryDigest = 'sha256:' + id;
  value.capabilityTags = ['reasoning'];
  value.regions = ['cn'];
  value.privacyClasses = [PrivacyClass.PERSONAL];
  value.maxInputTokens = 1000;
  value.maxOutputTokens = 1000;
  value.estimatedCostMicros = cost;
  value.qualityTier = quality;
  value.available = true;
  return value;
}

function modelRequest(): ModelRouteRequest {
  const value: ModelRouteRequest = new ModelRouteRequest();
  value.requestId = 'model-request';
  value.taskId = 'task-1';
  value.requiredCapabilityTags = ['reasoning'];
  value.region = 'cn';
  value.privacyClass = PrivacyClass.PERSONAL;
  value.estimatedInputTokens = 100;
  value.maxCostMicros = 100;
  value.inputFeatureDigest = 'sha256:model-input';
  value.createdAt = '2026-09-29T06:00:00.000Z';
  return value;
}

function tool(id: string, tag: string, cost: number = 5): ToolRegistryEntry {
  const descriptor: ToolDescriptor = new ToolDescriptor();
  descriptor.toolId = id;
  descriptor.sourceType = ToolSourceType.MCP;
  descriptor.providerId = 'provider-1';
  descriptor.capabilityName = tag;
  descriptor.capabilityVersion = '1';
  descriptor.toolIdentityVersion = 'identity-1';
  descriptor.displayName = id;
  descriptor.description = tag;
  descriptor.inputSchemaJson = '{"type":"object"}';
  descriptor.schemaDigest = 'sha256:schema-' + id;
  descriptor.capabilityTags = [tag];
  descriptor.riskLevel = RiskLevel.LOW;
  descriptor.sideEffect = SideEffect.NONE;
  descriptor.permissionRequirements = [];
  descriptor.dataBoundary = DataBoundary.APP_SANDBOX;
  descriptor.availability = 'available';
  descriptor.adapterRef = 'adapter-' + id;
  const value: ToolRegistryEntry = new ToolRegistryEntry();
  value.descriptor = descriptor;
  value.registryVersion = '1';
  value.registryDigest = 'sha256:registry-' + id;
  value.descriptionDigest = 'sha256:description-' + id;
  value.retrievalRelationVersion = '1';
  value.estimatedCostMicros = cost;
  value.enabled = true;
  return value;
}

function toolRequest(): ToolRouteRequest {
  const value: ToolRouteRequest = new ToolRouteRequest();
  value.requestId = 'tool-request';
  value.taskId = 'task-1';
  value.step = new WorkflowStep();
  value.step.stepId = 'step-1';
  value.step.kind = WorkflowStepKind.TOOL;
  value.step.goal = 'read calendar events';
  value.step.capabilityRequirements = ['calendar.read'];
  value.allowedToolIds = ['calendar.read', 'calendar.write'];
  value.allowedProviderIds = ['provider-1'];
  value.allowedSideEffects = [SideEffect.NONE];
  value.allowedDataBoundaries = [DataBoundary.APP_SANDBOX];
  value.maxRiskLevel = RiskLevel.LOW;
  value.maxCostMicros = 100;
  value.maxTools = 1;
  value.networkAvailable = true;
  value.inputFeatureDigest = 'sha256:tool-input';
  value.createdAt = '2026-09-29T06:00:00.000Z';
  return value;
}

class FixtureLearnedRouter implements LearnedRouterPort {
  calls: number = 0;
  candidateIds: string[] = [];
  selectedId: string = '';
  confidence: number = 1;

  route(request: RouterRequest): RouterDecision {
    this.calls++;
    this.candidateIds = [];
    for (let i: number = 0; i < request.candidates.length; i++) {
      this.candidateIds.push(request.candidates[i].candidateId);
    }
    const value: RouterDecision = new RouterDecision();
    value.decisionId = 'learned-decision';
    value.requestId = request.requestId;
    value.routerKind = request.routerKind;
    value.policyVersion = 'learned-policy-v1';
    value.artifactDigest = 'sha256:learned-artifact';
    value.inputFeatureDigest = request.featuresJson;
    value.eligibleCandidateIds = this.candidateIds.slice();
    value.selectedCandidateIds = [this.selectedId];
    value.confidence = this.confidence;
    value.createdAt = request.createdAt;
    return value;
  }
}

function context(id: string, kind: ContextSourceKind, tokens: number): ContextCandidate {
  const value: ContextCandidate = new ContextCandidate();
  value.contextId = id;
  value.sourceKind = kind;
  value.tokenCount = tokens;
  value.relevanceScore = 1;
  value.freshnessScore = 1;
  value.verified = true;
  value.privacyAllowed = true;
  value.contentDigest = 'sha256:' + id;
  return value;
}

function role(id: string, tag: string): RoleRegistryEntry {
  const value: RoleRegistryEntry = new RoleRegistryEntry();
  value.roleId = id;
  value.roleVersion = '1';
  value.registryDigest = 'sha256:' + id;
  value.capabilityTags = [tag];
  value.enabled = true;
  return value;
}

function workflowEntry(): WorkflowRegistryEntry {
  const graph: WorkflowGraph = new WorkflowGraph();
  graph.workflowId = 'workflow-1';
  graph.taskId = 'task-1';
  graph.workflowVersion = '1';
  graph.createdAt = '2026-09-29T06:00:00.000Z';
  const workflowStep: WorkflowStep = new WorkflowStep();
  workflowStep.stepId = 'step-1';
  workflowStep.goal = 'prepare result';
  workflowStep.expectedOutputSchemaJson = '{"type":"object"}';
  workflowStep.retryPolicyRef = 'retry-v1';
  workflowStep.verificationPolicyRef = 'verify-v1';
  workflowStep.timeoutMs = 1000;
  graph.entryStepIds = ['step-1'];
  graph.steps = [workflowStep];
  const value: WorkflowRegistryEntry = new WorkflowRegistryEntry();
  value.workflow = graph;
  value.registryDigest = 'sha256:workflow-1';
  value.capabilityTags = ['planning'];
  value.enabled = true;
  return value;
}

export default function deterministicRoutersTest(): void {
  describe('DeterministicRouters', () => {
    it('keepsRegistryOrderCopiesAndVersionIdentityStable', 0, () => {
      const registry: ModelRegistry = new ModelRegistry();
      registry.register(model('z-model'));
      registry.register(model('a-model'));
      const first = registry.activeEntries();
      expect(first[0].modelId).assertEqual('a-model');
      first[0].modelId = 'mutated';
      expect(registry.activeEntries()[0].modelId).assertEqual('a-model');
      expect(registry.snapshot().snapshotVersion).assertEqual(2);
      expect(registry.snapshot().snapshotDigest.includes('a-model@1')).assertTrue();
    });

    it('rejectsSameVersionWithChangedRegistryContent', 0, () => {
      const registry: ModelRegistry = new ModelRegistry();
      const first: ModelRegistryEntry = model('model-a');
      expect(registry.register(first).code).assertEqual(RegistryWriteCode.CREATED);
      expect(registry.register(first).code).assertEqual(RegistryWriteCode.UNCHANGED);
      const changed: ModelRegistryEntry = model('model-a');
      changed.qualityTier = 9;
      expect(registry.register(changed).code).assertEqual(RegistryWriteCode.VERSION_CONFLICT);
    });

    it('validatesWorkflowRegistryAndRejectsSameVersionDrift', 0, () => {
      const registry: WorkflowRegistry = new WorkflowRegistry();
      const original: WorkflowRegistryEntry = workflowEntry();
      expect(registry.register(original).code).assertEqual(RegistryWriteCode.CREATED);
      const changed: WorkflowRegistryEntry = workflowEntry();
      changed.workflow.steps[0].goal = 'changed goal';
      expect(registry.register(changed).code).assertEqual(RegistryWriteCode.VERSION_CONFLICT);
      const invalid: WorkflowRegistryEntry = workflowEntry();
      invalid.workflow.workflowId = '';
      expect(registry.register(invalid).code).assertEqual(RegistryWriteCode.INVALID_ENTRY);
    });

    it('filtersModelsBeforeLearnedPolicyAndUsesDeterministicFallback', 0, () => {
      const registry: ModelRegistry = new ModelRegistry();
      registry.register(model('allowed', 2));
      const denied: ModelRegistryEntry = model('wrong-region', 100);
      denied.regions = ['us'];
      registry.register(denied);
      const learned: FixtureLearnedRouter = new FixtureLearnedRouter();
      learned.selectedId = 'wrong-region';
      const routed = new DeterministicModelRouter(registry, config(true), learned).route(modelRequest());
      expect(learned.candidateIds.length).assertEqual(1);
      expect(learned.candidateIds[0]).assertEqual('allowed');
      expect(routed.decision?.selectedCandidateIds[0]).assertEqual('allowed');
      expect(routed.decision?.fallbackReason).assertEqual('LEARNED_DECISION_REJECTED');
    });

    it('routesModelTiesByStableIdWhenLearnedPolicyIsDisabled', 0, () => {
      const registry: ModelRegistry = new ModelRegistry();
      registry.register(model('model-b'));
      registry.register(model('model-a'));
      const learned: FixtureLearnedRouter = new FixtureLearnedRouter();
      learned.selectedId = 'model-b';
      const router: DeterministicModelRouter = new DeterministicModelRouter(registry, config(false), learned);
      const routed = router.route(modelRequest());
      const repeated = router.route(modelRequest());
      expect(learned.calls).assertEqual(0);
      expect(routed.decision?.selectedCandidateIds[0]).assertEqual('model-a');
      expect(routed.decision?.fallbackReason).assertEqual('LEARNED_DISABLED');
      expect(repeated.decision?.decisionId).assertEqual(routed.decision?.decisionId);
      expect(repeated.decision?.selectedCandidateIds[0]).assertEqual(routed.decision?.selectedCandidateIds[0]);
    });

    it('fallsBackWhenLearnedConfidenceIsLow', 0, () => {
      const registry: ModelRegistry = new ModelRegistry();
      registry.register(model('model-a', 2));
      registry.register(model('model-b', 1));
      const learned: FixtureLearnedRouter = new FixtureLearnedRouter();
      learned.selectedId = 'model-b';
      learned.confidence = 0.2;
      const routed = new DeterministicModelRouter(registry, config(true), learned).route(modelRequest());
      expect(routed.decision?.selectedCandidateIds[0]).assertEqual('model-a');
      expect(routed.decision?.fallbackReason).assertEqual('LOW_CONFIDENCE');
    });

    it('routesToolsWithoutEmbeddingsUsingTagsAndStableTieBreaks', 0, () => {
      const registry: ToolRegistry = new ToolRegistry();
      registry.register(tool('calendar.write', 'calendar.write'));
      registry.register(tool('calendar.read', 'calendar.read'));
      const routed = new DeterministicToolRouter(registry, config()).route(toolRequest());
      expect(routed.accepted).assertTrue();
      expect(routed.decision?.routerKind).assertEqual(RouterKind.TOOL_SET);
      expect(routed.decision?.selectedCandidateIds[0]).assertEqual('calendar.read');
    });

    it('filtersToolsBeforeLearnedPolicyByRiskPermissionAndBoundary', 0, () => {
      const registry: ToolRegistry = new ToolRegistry();
      registry.register(tool('calendar.read', 'calendar.read'));
      const denied: ToolRegistryEntry = tool('calendar.write', 'calendar.write');
      denied.descriptor.sideEffect = SideEffect.REVERSIBLE;
      denied.descriptor.riskLevel = RiskLevel.HIGH;
      denied.descriptor.permissionRequirements = ['calendar.write'];
      registry.register(denied);
      const learned: FixtureLearnedRouter = new FixtureLearnedRouter();
      learned.selectedId = 'calendar.read';
      const routed = new DeterministicToolRouter(registry, config(true), learned).route(toolRequest());
      expect(routed.accepted).assertTrue();
      expect(learned.candidateIds.length).assertEqual(1);
      expect(learned.candidateIds[0]).assertEqual('calendar.read');
    });

    it('rejectsAllToolsWhenAllowListsDoNotAuthorizeThem', 0, () => {
      const registry: ToolRegistry = new ToolRegistry();
      registry.register(tool('calendar.read', 'calendar.read'));
      const request: ToolRouteRequest = toolRequest();
      request.allowedToolIds = [];
      expect(new DeterministicToolRouter(registry, config()).route(request).code)
        .assertEqual('NO_ELIGIBLE_TOOL');
    });

    it('keepsMultiToolSelectionWithinCumulativeCostBudget', 0, () => {
      const registry: ToolRegistry = new ToolRegistry();
      registry.register(tool('calendar.read', 'calendar.read', 60));
      registry.register(tool('calendar.write', 'calendar.write', 60));
      const request: ToolRouteRequest = toolRequest();
      request.maxTools = 2;
      request.maxCostMicros = 100;
      const routed = new DeterministicToolRouter(registry, config()).route(request);
      expect(routed.decision?.selectedCandidateIds.length).assertEqual(1);
      expect(routed.decision?.estimatedCostMicros).assertEqual(60);
    });

    it('keepsToolRegistrySchemaAndRetrievalVersionsSeparate', 0, () => {
      const registry: ToolRegistry = new ToolRegistry();
      const original: ToolRegistryEntry = tool('calendar.read', 'calendar.read');
      expect(registry.register(original).code).assertEqual(RegistryWriteCode.CREATED);
      const changed: ToolRegistryEntry = tool('calendar.read', 'calendar.read');
      changed.descriptionDigest = 'sha256:changed-description';
      expect(registry.register(changed).code).assertEqual(RegistryWriteCode.VERSION_CONFLICT);
    });

    it('prioritizesRequiredContextThenUsesRemainingTokenBudget', 0, () => {
      const request: ContextRouteRequest = new ContextRouteRequest();
      request.requestId = 'context-request';
      request.taskId = 'task-1';
      request.stepId = 'step-1';
      request.tokenBudget = 7;
      request.candidates = [
        context('optional', ContextSourceKind.OPTIONAL, 3),
        context('system', ContextSourceKind.SYSTEM, 4),
        context('memory', ContextSourceKind.MEMORY, 3)
      ];
      request.inputFeatureDigest = 'sha256:context-input';
      request.createdAt = '2026-09-29T06:00:00.000Z';
      const routed = new DeterministicContextRouter(config()).route(request);
      expect(routed.totalTokens).assertEqual(7);
      expect(routed.decision?.selectedCandidateIds[0]).assertEqual('system');
      expect(routed.decision?.selectedCandidateIds[1]).assertEqual('memory');
    });

    it('rejectsRequiredContextOverflowAndSkipsUnverifiedDependencies', 0, () => {
      const request: ContextRouteRequest = new ContextRouteRequest();
      request.requestId = 'context-overflow';
      request.taskId = 'task-1';
      request.stepId = 'step-1';
      request.tokenBudget = 2;
      const dependency: ContextCandidate = context('dependency', ContextSourceKind.DEPENDENCY, 1);
      dependency.verified = false;
      request.candidates = [dependency, context('system', ContextSourceKind.SYSTEM, 3)];
      request.inputFeatureDigest = 'sha256:overflow';
      request.createdAt = '2026-09-29T06:00:00.000Z';
      expect(new DeterministicContextRouter(config()).route(request).code)
        .assertEqual('REQUIRED_CONTEXT_EXCEEDS_BUDGET');
    });

    it('keepsCompositionSelectorSingleAndRequiresExplicitBudgetForMultiRoute', 0, () => {
      const registry: RoleRegistry = new RoleRegistry();
      registry.register(role('planner', 'planning'));
      registry.register(role('verifier', 'verification'));
      const router: DeterministicCollaborationRouter = new DeterministicCollaborationRouter(registry, config());
      const request: CollaborationRouteRequest = new CollaborationRouteRequest();
      request.requestId = 'collaboration-request';
      request.taskId = 'task-1';
      request.frame.taskId = 'task-1';
      request.frame.capabilityCategories = ['planning', 'verification'];
      request.frame.canParallelize = true;
      request.maxAgentActivations = 1;
      request.inputFeatureDigest = 'sha256:collaboration';
      request.createdAt = '2026-09-29T06:00:00.000Z';
      expect(router.select(request.frame)).assertEqual(CollaborationMode.SINGLE);
      expect(router.route(request).mode).assertEqual(CollaborationMode.SINGLE);
      request.maxAgentActivations = 2;
      expect(router.route(request).mode).assertEqual(CollaborationMode.MULTI);
    });

    it('doesNotUseMultipleRolesThatAddNoDistinctCapability', 0, () => {
      const registry: RoleRegistry = new RoleRegistry();
      registry.register(role('planner-a', 'planning'));
      registry.register(role('planner-b', 'planning'));
      const router: DeterministicCollaborationRouter = new DeterministicCollaborationRouter(registry, config());
      const request: CollaborationRouteRequest = new CollaborationRouteRequest();
      request.requestId = 'same-role-request';
      request.taskId = 'task-1';
      request.frame.taskId = 'task-1';
      request.frame.capabilityCategories = ['planning', 'verification'];
      request.frame.canParallelize = true;
      request.maxAgentActivations = 2;
      request.inputFeatureDigest = 'sha256:same-role';
      request.createdAt = '2026-09-29T06:00:00.000Z';
      expect(router.route(request).mode).assertEqual(CollaborationMode.SINGLE);
    });

    it('buildsValidatedPlanOnlyFromRegisteredRoleIdentities', 0, () => {
      const registry: RoleRegistry = new RoleRegistry();
      registry.register(role('planner', 'planning'));
      registry.register(role('verifier', 'verification'));
      const router: DeterministicCollaborationRouter = new DeterministicCollaborationRouter(
        registry, config(), new FixtureCollaborationDigest());
      const frame: TaskFrame = new TaskFrame();
      frame.taskId = 'task-plan';
      frame.capabilityCategories = ['planning', 'verification'];
      frame.canParallelize = true;

      const plan: CollaborationPlan = router.selectPlan(frame, 2);

      expect(CollaborationPlanValidator.validate(plan, frame, 2).valid).assertTrue();
      expect(plan.mode).assertEqual(CollaborationMode.MULTI);
      expect(plan.assignments.length).assertEqual(2);
      expect(plan.assignments[0].roleId).assertEqual('planner');
      expect(plan.assignments[1].roleId).assertEqual('verifier');
      expect(plan.roleRegistryDigest.length).assertEqual(71);
      expect(plan.decisionDigest.length).assertEqual(71);
    });
  });
}
