import {
  CollaborationMode,
  ContractValidator,
  DataBoundary,
  ExecutionBudget,
  PrivacyClass,
  RiskLevel,
  RouterCandidate,
  RouterDecision,
  RouterKind,
  RouterRequest,
  RouterScore,
  SideEffect,
  TaskFrame
} from '@harmony_agent/agent-contracts';
import {
  CollaborationPlanDigestPort,
  CollaborationPlanSelectorPort,
  CollaborationSelectorPort
} from '../orchestration/RuntimePorts';
import {
  CollaborationPlan,
  CollaborationRoleAssignment
} from '../orchestration/OrchestrationTypes';
import { ModelRegistry, RoleRegistry, ToolRegistry } from '../registry/Registries';
import { ModelRegistryEntry, RoleRegistryEntry, ToolRegistryEntry } from '../registry/RegistryTypes';
import {
  CollaborationRouteRequest,
  CollaborationRouteResult,
  ContextCandidate,
  ContextRouteRequest,
  ContextRouteResult,
  ContextSourceKind,
  DeterministicRouterConfig,
  LearnedRouterPort,
  ModelRouteRequest,
  RouterResult,
  ToolRouteRequest
} from './RouterTypes';

class ScoredId {
  id: string = '';
  score: number = 0;
  cost: number = 0;
}

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function validCount(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function includesText(values: string[], value: string): boolean {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i] === value) {
      return true;
    }
  }
  return false;
}

function containsAll(available: string[], required: string[]): boolean {
  for (let i: number = 0; i < required.length; i++) {
    if (!includesText(available, required[i])) {
      return false;
    }
  }
  return true;
}

function includesPrivacy(values: PrivacyClass[], value: PrivacyClass): boolean {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i] === value) {
      return true;
    }
  }
  return false;
}

function includesSideEffect(values: SideEffect[], value: SideEffect): boolean {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i] === value) {
      return true;
    }
  }
  return false;
}

function includesBoundary(values: DataBoundary[], value: DataBoundary): boolean {
  for (let i: number = 0; i < values.length; i++) {
    if (values[i] === value) {
      return true;
    }
  }
  return false;
}

function riskRank(value: RiskLevel): number {
  if (value === RiskLevel.LOW) return 0;
  if (value === RiskLevel.MEDIUM) return 1;
  if (value === RiskLevel.HIGH) return 2;
  return 3;
}

function sortScored(values: ScoredId[]): ScoredId[] {
  const result: ScoredId[] = values.slice();
  for (let i: number = 0; i < result.length; i++) {
    for (let j: number = i + 1; j < result.length; j++) {
      const shouldSwap: boolean = result[j].score > result[i].score ||
        (result[j].score === result[i].score && result[j].id < result[i].id);
      if (shouldSwap) {
        const temporary: ScoredId = result[i];
        result[i] = result[j];
        result[j] = temporary;
      }
    }
  }
  return result;
}

function routerScore(value: ScoredId): RouterScore {
  const score: RouterScore = new RouterScore();
  score.candidateId = value.id;
  score.score = value.score;
  return score;
}

function candidate(id: string, metadataJson: string): RouterCandidate {
  const value: RouterCandidate = new RouterCandidate();
  value.candidateId = id;
  value.metadataJson = metadataJson;
  return value;
}

function budget(cost: number, activations: number = 1): ExecutionBudget {
  const value: ExecutionBudget = new ExecutionBudget();
  value.maxMonetaryCostMicros = cost;
  value.maxAgentActivations = activations;
  return value;
}

function baselineDecision(kind: RouterKind, requestId: string, inputDigest: string, createdAt: string,
  config: DeterministicRouterConfig, scored: ScoredId[], selectedIds: string[], fallbackReason: string,
  estimatedCost: number = 0): RouterDecision {
  const value: RouterDecision = new RouterDecision();
  value.decisionId = 'deterministic:' + kind + ':' + requestId + ':' + inputDigest;
  value.requestId = requestId;
  value.routerKind = kind;
  value.policyVersion = config.policyVersion;
  value.artifactDigest = config.artifactDigest;
  value.inputFeatureDigest = inputDigest;
  value.selectedCandidateIds = selectedIds.slice();
  value.fallbackUsed = true;
  value.fallbackReason = fallbackReason;
  value.confidence = 1;
  value.latencyMs = 0;
  value.estimatedCostMicros = estimatedCost;
  value.createdAt = createdAt;
  for (let i: number = 0; i < scored.length; i++) {
    value.eligibleCandidateIds.push(scored[i].id);
    value.scores.push(routerScore(scored[i]));
  }
  return value;
}

function validConfig(config: DeterministicRouterConfig): boolean {
  return validText(config.policyVersion) && validText(config.artifactDigest) &&
    Number.isFinite(config.minimumLearnedConfidence) && config.minimumLearnedConfidence >= 0 &&
    config.minimumLearnedConfidence <= 1;
}

function uniqueSubset(selected: string[], eligible: string[]): boolean {
  if (selected.length === 0) return false;
  for (let i: number = 0; i < selected.length; i++) {
    if (!includesText(eligible, selected[i])) return false;
    for (let previous: number = 0; previous < i; previous++) {
      if (selected[previous] === selected[i]) return false;
    }
  }
  return true;
}

function scoresStayEligible(scores: RouterScore[], eligible: string[]): boolean {
  for (let i: number = 0; i < scores.length; i++) {
    if (!includesText(eligible, scores[i].candidateId) || !Number.isFinite(scores[i].score)) return false;
  }
  return true;
}

function calculateSelectedCost(scored: ScoredId[], selected: string[]): number {
  let cost: number = 0;
  for (let i: number = 0; i < selected.length; i++) {
    for (let j: number = 0; j < scored.length; j++) {
      if (scored[j].id === selected[i]) {
        cost += scored[j].cost;
        break;
      }
    }
  }
  return cost;
}

function acceptLearned(value: RouterDecision, request: RouterRequest, eligibleIds: string[],
  config: DeterministicRouterConfig): boolean {
  return ContractValidator.validateRouterDecision(value).valid &&
    value.requestId === request.requestId && value.routerKind === request.routerKind &&
    validText(value.artifactDigest) && value.inputFeatureDigest === request.featuresJson &&
    value.confidence >= config.minimumLearnedConfidence &&
    uniqueSubset(value.selectedCandidateIds, eligibleIds) && scoresStayEligible(value.scores, eligibleIds);
}

function result(decision: RouterDecision): RouterResult {
  const value: RouterResult = new RouterResult();
  value.accepted = true;
  value.code = 'ROUTED';
  value.decision = decision;
  return value;
}

function rejected(code: string): RouterResult {
  const value: RouterResult = new RouterResult();
  value.code = code;
  return value;
}

export class DeterministicModelRouter {
  private registry: ModelRegistry;
  private config: DeterministicRouterConfig;
  private learned?: LearnedRouterPort;

  constructor(registry: ModelRegistry, config: DeterministicRouterConfig, learned?: LearnedRouterPort) {
    this.registry = registry;
    this.config = config;
    this.learned = learned;
  }

  route(request: ModelRouteRequest): RouterResult {
    if (!validConfig(this.config) || !validText(request.requestId) || !validText(request.taskId) ||
      !validText(request.region) || !validText(request.inputFeatureDigest) || !validText(request.createdAt) ||
      !validCount(request.estimatedInputTokens) || !validCount(request.maxCostMicros)) {
      return rejected('INVALID_REQUEST');
    }
    const active: ModelRegistryEntry[] = this.registry.activeEntries();
    const scored: ScoredId[] = [];
    const generic: RouterRequest = new RouterRequest();
    generic.requestId = request.requestId;
    generic.taskId = request.taskId;
    generic.routerKind = RouterKind.MODEL;
    generic.featuresJson = request.inputFeatureDigest;
    generic.remainingBudget = budget(request.maxCostMicros);
    generic.createdAt = request.createdAt;
    for (let i: number = 0; i < active.length; i++) {
      const entry: ModelRegistryEntry = active[i];
      if (!includesText(entry.regions, request.region) ||
        !includesPrivacy(entry.privacyClasses, request.privacyClass) ||
        !containsAll(entry.capabilityTags, request.requiredCapabilityTags) ||
        request.estimatedInputTokens > entry.maxInputTokens ||
        entry.estimatedCostMicros > request.maxCostMicros) {
        continue;
      }
      const value: ScoredId = new ScoredId();
      value.id = entry.modelId;
      value.score = entry.qualityTier * 1000000 - entry.estimatedCostMicros;
      value.cost = entry.estimatedCostMicros;
      scored.push(value);
      generic.candidates.push(candidate(entry.modelId,
        '{"modelVersion":"' + entry.modelVersion + '","registryDigest":"' + entry.registryDigest + '"}'));
    }
    const ordered: ScoredId[] = sortScored(scored);
    if (ordered.length === 0) return rejected('NO_ELIGIBLE_MODEL');
    const baseline: RouterDecision = baselineDecision(RouterKind.MODEL, request.requestId,
      request.inputFeatureDigest, request.createdAt, this.config, ordered, [ordered[0].id],
      this.config.learnedEnabled ? 'LEARNED_UNAVAILABLE' : 'LEARNED_DISABLED', ordered[0].cost);
    if (!this.config.learnedEnabled || this.learned === undefined) return result(baseline);
    try {
      const learned: RouterDecision = this.learned.route(generic);
      if (acceptLearned(learned, generic, baseline.eligibleCandidateIds, this.config) &&
        learned.selectedCandidateIds.length === 1) {
        learned.eligibleCandidateIds = baseline.eligibleCandidateIds.slice();
        learned.estimatedCostMicros = calculateSelectedCost(ordered, learned.selectedCandidateIds);
        return result(learned);
      }
      baseline.fallbackReason = learned.confidence < this.config.minimumLearnedConfidence ?
        'LOW_CONFIDENCE' : 'LEARNED_DECISION_REJECTED';
      return result(baseline);
    } catch (error) {
      baseline.fallbackReason = 'LEARNED_ERROR';
      return result(baseline);
    }
  }
}

function toolEligible(entry: ToolRegistryEntry, request: ToolRouteRequest): boolean {
  return includesText(request.allowedToolIds, entry.descriptor.toolId) &&
    includesText(request.allowedProviderIds, entry.descriptor.providerId) &&
    includesSideEffect(request.allowedSideEffects, entry.descriptor.sideEffect) &&
    includesBoundary(request.allowedDataBoundaries, entry.descriptor.dataBoundary) &&
    riskRank(entry.descriptor.riskLevel) <= riskRank(request.maxRiskLevel) &&
    containsAll(request.availablePermissions, entry.descriptor.permissionRequirements) &&
    entry.descriptor.availability === 'available' &&
    (!entry.requiresNetwork || request.networkAvailable) &&
    entry.estimatedCostMicros <= request.maxCostMicros;
}

function toolScore(entry: ToolRegistryEntry, request: ToolRouteRequest): number {
  let score: number = 0;
  const lowerGoal: string = request.step.goal.toLowerCase();
  for (let i: number = 0; i < entry.descriptor.capabilityTags.length; i++) {
    const tag: string = entry.descriptor.capabilityTags[i];
    if (includesText(request.step.capabilityRequirements, tag)) score += 100;
    if (lowerGoal.includes(tag.toLowerCase())) score += 10;
  }
  if (lowerGoal.includes(entry.descriptor.capabilityName.toLowerCase())) score += 20;
  return score * 1000000 - entry.estimatedCostMicros;
}

export class DeterministicToolRouter {
  private registry: ToolRegistry;
  private config: DeterministicRouterConfig;
  private learned?: LearnedRouterPort;

  constructor(registry: ToolRegistry, config: DeterministicRouterConfig, learned?: LearnedRouterPort) {
    this.registry = registry;
    this.config = config;
    this.learned = learned;
  }

  route(request: ToolRouteRequest): RouterResult {
    if (!validConfig(this.config) || !validText(request.requestId) || !validText(request.taskId) ||
      !validText(request.step.stepId) || !validText(request.inputFeatureDigest) || !validText(request.createdAt) ||
      !validCount(request.maxCostMicros) || !Number.isSafeInteger(request.maxTools) || request.maxTools <= 0) {
      return rejected('INVALID_REQUEST');
    }
    const active: ToolRegistryEntry[] = this.registry.activeEntries();
    const scored: ScoredId[] = [];
    const generic: RouterRequest = new RouterRequest();
    generic.requestId = request.requestId;
    generic.taskId = request.taskId;
    generic.stepId = request.step.stepId;
    generic.routerKind = RouterKind.TOOL_SET;
    generic.featuresJson = request.inputFeatureDigest;
    generic.remainingBudget = budget(request.maxCostMicros);
    generic.createdAt = request.createdAt;
    for (let i: number = 0; i < active.length; i++) {
      const entry: ToolRegistryEntry = active[i];
      if (!toolEligible(entry, request)) continue;
      const value: ScoredId = new ScoredId();
      value.id = entry.descriptor.toolId;
      value.score = toolScore(entry, request);
      value.cost = entry.estimatedCostMicros;
      scored.push(value);
      generic.candidates.push(candidate(entry.descriptor.toolId,
        '{"toolIdentityVersion":"' + entry.descriptor.toolIdentityVersion +
        '","schemaDigest":"' + entry.descriptor.schemaDigest + '"}'));
    }
    const ordered: ScoredId[] = sortScored(scored);
    if (ordered.length === 0) return rejected('NO_ELIGIBLE_TOOL');
    const selected: string[] = [];
    let selectedCost: number = 0;
    for (let i: number = 0; i < ordered.length && selected.length < request.maxTools; i++) {
      if (selectedCost + ordered[i].cost <= request.maxCostMicros) {
        selected.push(ordered[i].id);
        selectedCost += ordered[i].cost;
      }
    }
    const baseline: RouterDecision = baselineDecision(RouterKind.TOOL_SET, request.requestId,
      request.inputFeatureDigest, request.createdAt, this.config, ordered, selected,
      this.config.learnedEnabled ? 'LEARNED_UNAVAILABLE' : 'LEARNED_DISABLED', selectedCost);
    if (!this.config.learnedEnabled || this.learned === undefined) return result(baseline);
    try {
      const learned: RouterDecision = this.learned.route(generic);
      const learnedCost: number = calculateSelectedCost(ordered, learned.selectedCandidateIds);
      if (acceptLearned(learned, generic, baseline.eligibleCandidateIds, this.config) &&
        learned.selectedCandidateIds.length <= request.maxTools && learnedCost <= request.maxCostMicros) {
        learned.eligibleCandidateIds = baseline.eligibleCandidateIds.slice();
        learned.estimatedCostMicros = learnedCost;
        return result(learned);
      }
      baseline.fallbackReason = learned.confidence < this.config.minimumLearnedConfidence ?
        'LOW_CONFIDENCE' : 'LEARNED_DECISION_REJECTED';
      return result(baseline);
    } catch (error) {
      baseline.fallbackReason = 'LEARNED_ERROR';
      return result(baseline);
    }
  }
}

function contextPriority(value: ContextSourceKind): number {
  if (value === ContextSourceKind.SYSTEM) return 0;
  if (value === ContextSourceKind.USER) return 1;
  if (value === ContextSourceKind.DEPENDENCY) return 2;
  if (value === ContextSourceKind.SHORT_TERM) return 3;
  if (value === ContextSourceKind.MEMORY) return 4;
  return 5;
}

function requiredContext(value: ContextCandidate): boolean {
  return value.sourceKind === ContextSourceKind.SYSTEM || value.sourceKind === ContextSourceKind.USER ||
    value.sourceKind === ContextSourceKind.DEPENDENCY;
}

function sortContext(values: ContextCandidate[]): ContextCandidate[] {
  const result: ContextCandidate[] = values.slice();
  for (let i: number = 0; i < result.length; i++) {
    for (let j: number = i + 1; j < result.length; j++) {
      const left: ContextCandidate = result[i];
      const right: ContextCandidate = result[j];
      const swap: boolean = contextPriority(right.sourceKind) < contextPriority(left.sourceKind) ||
        (contextPriority(right.sourceKind) === contextPriority(left.sourceKind) &&
          (right.relevanceScore > left.relevanceScore ||
            (right.relevanceScore === left.relevanceScore &&
              (right.freshnessScore > left.freshnessScore ||
                (right.freshnessScore === left.freshnessScore && right.contextId < left.contextId)))));
      if (swap) {
        const temporary: ContextCandidate = result[i];
        result[i] = result[j];
        result[j] = temporary;
      }
    }
  }
  return result;
}

export class DeterministicContextRouter {
  private config: DeterministicRouterConfig;

  constructor(config: DeterministicRouterConfig) {
    this.config = config;
  }

  route(request: ContextRouteRequest): ContextRouteResult {
    const output: ContextRouteResult = new ContextRouteResult();
    if (!validConfig(this.config) || !validText(request.requestId) || !validText(request.taskId) ||
      !validText(request.stepId) || !validText(request.inputFeatureDigest) || !validText(request.createdAt) ||
      !validCount(request.tokenBudget)) {
      output.code = 'INVALID_REQUEST';
      return output;
    }
    const eligible: ContextCandidate[] = [];
    for (let i: number = 0; i < request.candidates.length; i++) {
      const value: ContextCandidate = request.candidates[i];
      if (!validText(value.contextId) || !validText(value.contentDigest) || !validCount(value.tokenCount) ||
        !Number.isFinite(value.relevanceScore) || !Number.isFinite(value.freshnessScore)) {
        output.code = 'INVALID_CANDIDATE';
        return output;
      }
      if (!value.privacyAllowed || (value.sourceKind === ContextSourceKind.DEPENDENCY && !value.verified)) continue;
      eligible.push(value);
    }
    const ordered: ContextCandidate[] = sortContext(eligible);
    const scored: ScoredId[] = [];
    const selected: string[] = [];
    let tokens: number = 0;
    for (let i: number = 0; i < ordered.length; i++) {
      const value: ContextCandidate = ordered[i];
      const score: ScoredId = new ScoredId();
      score.id = value.contextId;
      score.score = (6 - contextPriority(value.sourceKind)) * 1000000 +
        value.relevanceScore * 1000 + value.freshnessScore;
      scored.push(score);
      if (requiredContext(value) && tokens + value.tokenCount > request.tokenBudget) {
        output.code = 'REQUIRED_CONTEXT_EXCEEDS_BUDGET';
        return output;
      }
      if (tokens + value.tokenCount <= request.tokenBudget) {
        selected.push(value.contextId);
        tokens += value.tokenCount;
      }
    }
    if (selected.length === 0) {
      output.code = 'NO_CONTEXT_SELECTED';
      return output;
    }
    const decision: RouterDecision = baselineDecision(RouterKind.CONTEXT, request.requestId,
      request.inputFeatureDigest, request.createdAt, this.config, scored, selected, 'DETERMINISTIC_CONTEXT');
    output.accepted = true;
    output.code = 'ROUTED';
    output.decision = decision;
    output.totalTokens = tokens;
    return output;
  }
}

function roleScore(entry: RoleRegistryEntry, categories: string[]): number {
  let score: number = 0;
  for (let i: number = 0; i < categories.length; i++) {
    if (includesText(entry.capabilityTags, categories[i])) score++;
  }
  return score;
}

function addsDistinctCapability(first: RoleRegistryEntry, second: RoleRegistryEntry,
  categories: string[]): boolean {
  for (let i: number = 0; i < categories.length; i++) {
    if (includesText(second.capabilityTags, categories[i]) && !includesText(first.capabilityTags, categories[i])) {
      return true;
    }
  }
  return false;
}

function findRole(roles: RoleRegistryEntry[], roleId: string): RoleRegistryEntry | undefined {
  for (let i: number = 0; i < roles.length; i++) {
    if (roles[i].roleId === roleId) return roles[i];
  }
  return undefined;
}

export class DeterministicCollaborationRouter implements CollaborationSelectorPort, CollaborationPlanSelectorPort {
  private registry: RoleRegistry;
  private config: DeterministicRouterConfig;
  private digest?: CollaborationPlanDigestPort;

  constructor(registry: RoleRegistry, config: DeterministicRouterConfig,
    digest?: CollaborationPlanDigestPort) {
    this.registry = registry;
    this.config = config;
    this.digest = digest;
  }

  select(frame: TaskFrame): CollaborationMode {
    return CollaborationMode.SINGLE;
  }

  selectPlan(frame: TaskFrame, maxAgentActivations: number): CollaborationPlan {
    const digestPort: CollaborationPlanDigestPort | undefined = this.digest;
    if (digestPort === undefined) throw new Error('collaboration plan digest port is required');
    const request: CollaborationRouteRequest = new CollaborationRouteRequest();
    request.requestId = frame.taskId + ':collaboration-plan';
    request.taskId = frame.taskId;
    request.frame = frame;
    request.maxAgentActivations = maxAgentActivations;
    request.inputFeatureDigest = digestPort.digest('collaboration-frame|' + JSON.stringify(frame));
    request.createdAt = '1970-01-01T00:00:00.000Z';
    const routed: CollaborationRouteResult = this.route(request);
    if (!routed.accepted) throw new Error('collaboration route was rejected');
    const roles: RoleRegistryEntry[] = this.registry.activeEntries();
    const registryIdentity: string = this.registry.snapshot().snapshotDigest;
    const value: CollaborationPlan = new CollaborationPlan();
    value.taskId = frame.taskId;
    value.mode = routed.mode;
    value.roleRegistryDigest = digestPort.digest('collaboration-registry|' + registryIdentity);
    let decisionIdentity: string = 'collaboration-decision|' + this.config.policyVersion + '|' +
      this.config.artifactDigest + '|' + value.roleRegistryDigest + '|' + value.mode;
    for (let i: number = 0; i < routed.selectedRoleIds.length; i++) {
      const role: RoleRegistryEntry | undefined = findRole(roles, routed.selectedRoleIds[i]);
      if (role === undefined) throw new Error('collaboration route selected an unregistered role');
      const assignment: CollaborationRoleAssignment = new CollaborationRoleAssignment();
      assignment.roleId = role.roleId;
      assignment.roleVersion = role.roleVersion;
      assignment.roleRegistryDigest = digestPort.digest('collaboration-role|' + role.roleId + '|' +
        role.roleVersion + '|' + role.registryDigest);
      value.assignments.push(assignment);
      decisionIdentity += '|' + assignment.roleId + '@' + assignment.roleVersion + ':' +
        assignment.roleRegistryDigest;
    }
    value.decisionDigest = digestPort.digest(decisionIdentity);
    return value;
  }

  route(request: CollaborationRouteRequest): CollaborationRouteResult {
    const output: CollaborationRouteResult = new CollaborationRouteResult();
    if (!validConfig(this.config) || !validText(request.requestId) || !validText(request.taskId) ||
      !validText(request.inputFeatureDigest) || !validText(request.createdAt) ||
      !Number.isSafeInteger(request.maxAgentActivations) || request.maxAgentActivations <= 0) {
      output.code = 'INVALID_REQUEST';
      return output;
    }
    const roles: RoleRegistryEntry[] = this.registry.activeEntries();
    const scored: ScoredId[] = [];
    for (let i: number = 0; i < roles.length; i++) {
      const value: ScoredId = new ScoredId();
      value.id = roles[i].roleId;
      value.score = roleScore(roles[i], request.frame.capabilityCategories);
      if (value.score > 0 || request.frame.capabilityCategories.length === 0) scored.push(value);
    }
    const ordered: ScoredId[] = sortScored(scored);
    if (ordered.length === 0) {
      output.code = 'NO_ELIGIBLE_ROLE';
      return output;
    }
    const selected: string[] = [ordered[0].id];
    const firstRole: RoleRegistryEntry | undefined = findRole(roles, ordered[0].id);
    if (request.frame.canParallelize && request.frame.capabilityCategories.length >= 2 &&
      request.maxAgentActivations >= 2 && ordered.length >= 2 && firstRole !== undefined) {
      for (let i: number = 1; i < ordered.length; i++) {
        const candidateRole: RoleRegistryEntry | undefined = findRole(roles, ordered[i].id);
        if (candidateRole !== undefined && addsDistinctCapability(firstRole, candidateRole,
          request.frame.capabilityCategories)) {
          selected.push(ordered[i].id);
          output.mode = CollaborationMode.MULTI;
          break;
        }
      }
    }
    output.selectedRoleIds = selected.slice();
    output.decision = baselineDecision(RouterKind.COLLABORATION, request.requestId,
      request.inputFeatureDigest, request.createdAt, this.config, ordered, selected, 'SINGLE_FIRST_POLICY');
    output.accepted = true;
    output.code = 'ROUTED';
    return output;
  }
}
