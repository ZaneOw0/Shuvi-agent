import { CollaborationMode, ExecutionBudget, TaskFrame } from '@harmony_agent/agent-contracts';
import { CollaborationPlan, CollaborationRoleAssignment } from '../orchestration/OrchestrationTypes';
import { CollaborationPlanDigestPort } from '../orchestration/RuntimePorts';
import { CollaborationPlanValidator } from '../orchestration/CollaborationPlanValidator';
import { ModelRegistry, RoleRegistry } from '../registry/Registries';
import { ModelRegistryEntry, RoleRegistryEntry } from '../registry/RegistryTypes';
import { ArtifactRegistryEntry } from '../artifact/ArtifactRegistryTypes';
import { ArtifactPolicyReleaseRunner } from '../artifact/ArtifactPolicyReleaseRunner';
import {
  ArtifactBaselinePolicyPort, ArtifactReleasedPolicyPort, ArtifactPolicyRequest,
  ArtifactPolicyDecision, ArtifactPolicyRunResult, ArtifactPolicyReleaseConfig,
  ArtifactPolicyCancellationSignalPort, ArtifactReleaseRegistryViewPort,
  ArtifactCanaryAssignmentPort
} from '../artifact/ArtifactPolicyReleaseTypes';
import { CollaborationPolicyPreparationPort } from './CollaborationPreparation';
import { DeterministicCollaborationRouter } from './DeterministicRouters';
import { DeterministicRouterConfig } from './RouterTypes';

export class CollaborationCandidateRole {
  roleId: string = '';
  roleVersion: string = '';
  registryDigest: string = '';
  modelId: string = '';
  modelVersion: string = '';
  modelRegistryDigest: string = '';
}

/** Internal loader output. Model identities are advisory, never authorization. */
export class CollaborationPolicyCandidate {
  version: string = '1.0';
  taskId: string = '';
  inputDigest: string = '';
  registryDigest: string = '';
  artifactDigest: string = '';
  confidence: number = 0;
  estimatedCostMicros: number = 0;
  mode: CollaborationMode = CollaborationMode.SINGLE;
  roles: CollaborationCandidateRole[] = [];
}

export class CollaborationPolicyInput {
  taskId: string = '';
  inputDigest: string = '';
  registryDigest: string = '';
  frame: TaskFrame = new TaskFrame();
  budget: ExecutionBudget = new ExecutionBudget();
}

export interface CollaborationPolicyEvaluatorPort {
  evaluate(input: CollaborationPolicyInput,
    cancellation?: ArtifactPolicyCancellationSignalPort): Promise<CollaborationPolicyCandidate>;
}

export interface CollaborationPolicyLoaderPort {
  load(artifact: ArtifactRegistryEntry,
    cancellation?: ArtifactPolicyCancellationSignalPort): Promise<CollaborationPolicyEvaluatorPort>;
}

export class ArtifactCollaborationPolicyConfig {
  learnedEnabled: boolean = false;
  minimumConfidence: number = 0.8;
}

class BaselineDecision implements ArtifactBaselinePolicyPort {
  async decide(request: ArtifactPolicyRequest): Promise<ArtifactPolicyDecision> {
    const result: ArtifactPolicyDecision = new ArtifactPolicyDecision();
    result.selectedId = 'baseline';
    result.evidenceJson = '{"baseline":true}';
    return result;
  }
}

class ValidatedCandidate {
  artifactDigest: string = '';
  plan: CollaborationPlan = new CollaborationPlan();
}

class ReleasedDecision implements ArtifactReleasedPolicyPort {
  private owner: ArtifactCollaborationPolicy;
  private input: CollaborationPolicyInput;
  private loader: CollaborationPolicyLoaderPort;
  readonly candidates: ValidatedCandidate[] = [];

  constructor(owner: ArtifactCollaborationPolicy, input: CollaborationPolicyInput,
    loader: CollaborationPolicyLoaderPort) {
    this.owner = owner;
    this.input = input;
    this.loader = loader;
  }

  async decide(artifact: ArtifactRegistryEntry, request: ArtifactPolicyRequest,
    cancellation?: ArtifactPolicyCancellationSignalPort): Promise<ArtifactPolicyDecision> {
    const evaluator: CollaborationPolicyEvaluatorPort = await this.loader.load(artifact, cancellation);
    if (cancellation !== undefined && cancellation.isCancellationRequested()) throw new Error('cancelled');
    // Hosts cannot mutate the canonical request used by validation.
    const isolated: CollaborationPolicyInput = JSON.parse(JSON.stringify(this.input));
    const candidate: CollaborationPolicyCandidate = await evaluator.evaluate(isolated, cancellation);
    if (cancellation !== undefined && cancellation.isCancellationRequested()) throw new Error('cancelled');
    const value: ValidatedCandidate = new ValidatedCandidate();
    value.artifactDigest = artifact.manifest.artifactDigest;
    value.plan = this.owner.validateCandidate(candidate, this.input, value.artifactDigest);
    this.candidates.push(value);
    const result: ArtifactPolicyDecision = new ArtifactPolicyDecision();
    result.selectedId = 'candidate';
    result.evidenceJson = '{"validated":true}';
    return result;
  }
}

/** Per-composition adapter. No filesystem, network, training or production activation. */
export class ArtifactCollaborationPolicy implements CollaborationPolicyPreparationPort {
  private roles: RoleRegistry;
  private models: ModelRegistry;
  private digest: CollaborationPlanDigestPort;
  private baseline: DeterministicCollaborationRouter;
  private registry: ArtifactReleaseRegistryViewPort;
  private loader: CollaborationPolicyLoaderPort;
  private assignment: ArtifactCanaryAssignmentPort;
  private release: ArtifactPolicyReleaseConfig;
  private enabled: boolean;
  private confidence: number;
  private generation: number = 0;
  private binding: string = '';
  private prepared?: CollaborationPlan;

  constructor(roles: RoleRegistry, models: ModelRegistry, digest: CollaborationPlanDigestPort,
    registry: ArtifactReleaseRegistryViewPort, loader: CollaborationPolicyLoaderPort,
    assignment: ArtifactCanaryAssignmentPort, config: ArtifactCollaborationPolicyConfig,
    release: ArtifactPolicyReleaseConfig = new ArtifactPolicyReleaseConfig()) {
    if (typeof config.learnedEnabled !== 'boolean' || !Number.isFinite(config.minimumConfidence) ||
      config.minimumConfidence < 0 || config.minimumConfidence > 1) throw new Error('invalid policy config');
    this.roles = roles;
    this.models = models;
    this.digest = digest;
    this.registry = registry;
    this.loader = loader;
    this.assignment = assignment;
    this.release = JSON.parse(JSON.stringify(release));
    this.enabled = config.learnedEnabled;
    this.confidence = config.minimumConfidence;
    const deterministic: DeterministicRouterConfig = new DeterministicRouterConfig();
    deterministic.policyVersion = 't53-baseline-1';
    deterministic.artifactDigest = digest.digest('t53-baseline-1');
    this.baseline = new DeterministicCollaborationRouter(roles, deterministic, digest);
  }

  selectBaselinePlan(frame: TaskFrame, maxAgentActivations: number): CollaborationPlan {
    const plan: CollaborationPlan = this.baseline.selectPlan(frame, 1);
    if (!CollaborationPlanValidator.validate(plan, frame, maxAgentActivations).valid) {
      throw new Error('invalid collaboration baseline');
    }
    return plan;
  }

  async prepare(frame: TaskFrame, budget: ExecutionBudget,
    cancellation: ArtifactPolicyCancellationSignalPort): Promise<void> {
    const generation: number = ++this.generation;
    this.prepared = undefined;
    this.binding = '';
    this.selectBaselinePlan(frame, budget.maxAgentActivations);
    if (!this.enabled || cancellation.isCancellationRequested()) return;
    const input: CollaborationPolicyInput = new CollaborationPolicyInput();
    input.frame = JSON.parse(JSON.stringify(frame));
    input.budget = JSON.parse(JSON.stringify(budget));
    input.taskId = frame.taskId;
    input.inputDigest = this.digest.digest(JSON.stringify(frame));
    input.registryDigest = this.registryIdentity();
    const binding: string = this.identity(frame, budget.maxAgentActivations);
    const released: ReleasedDecision = new ReleasedDecision(this, input, this.loader);
    const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(this.registry,
      new BaselineDecision(), released, this.assignment, this.release);
    const request: ArtifactPolicyRequest = new ArtifactPolicyRequest();
    request.requestId = frame.taskId + ':' + generation.toString();
    request.candidateIds = ['baseline', 'candidate'];
    request.inputJson = JSON.stringify(input);
    const result: ArtifactPolicyRunResult = await runner.run(request, cancellation);
    if (cancellation.isCancellationRequested() || generation !== this.generation ||
      binding !== this.identity(frame, budget.maxAgentActivations)) return;
    if (!result.accepted || result.decision === undefined || result.decision.selectedId !== 'candidate') return;
    for (let i: number = released.candidates.length - 1; i >= 0; i--) {
      const candidate: ValidatedCandidate = released.candidates[i];
      if (candidate.artifactDigest === result.selectedArtifactDigest) {
        this.binding = binding;
        this.prepared = JSON.parse(JSON.stringify(candidate.plan));
        return;
      }
    }
  }

  selectPlan(frame: TaskFrame, maxAgentActivations: number): CollaborationPlan {
    const plan: CollaborationPlan | undefined = this.prepared;
    if (plan === undefined || this.binding !== this.identity(frame, maxAgentActivations) ||
      !CollaborationPlanValidator.validate(plan, frame, maxAgentActivations).valid) {
      return this.selectBaselinePlan(frame, maxAgentActivations);
    }
    return JSON.parse(JSON.stringify(plan));
  }

  validateCandidate(candidate: CollaborationPolicyCandidate, input: CollaborationPolicyInput,
    artifactDigest: string): CollaborationPlan {
    // Validate before copying/serializing: JSON would turn NaN/Infinity into null.
    if (candidate === null || typeof candidate !== 'object' || candidate.version !== '1.0' ||
      candidate.taskId !== input.taskId || candidate.inputDigest !== input.inputDigest ||
      candidate.registryDigest !== input.registryDigest || input.registryDigest !== this.registryIdentity() ||
      candidate.artifactDigest !== artifactDigest || !Number.isFinite(candidate.confidence) ||
      candidate.confidence < this.confidence || candidate.confidence > 1 ||
      !Number.isSafeInteger(candidate.estimatedCostMicros) || candidate.estimatedCostMicros < 0 ||
      candidate.estimatedCostMicros > input.budget.maxMonetaryCostMicros ||
      !Array.isArray(candidate.roles) || candidate.roles.length === 0 || candidate.roles.length > 6 ||
      candidate.roles.length > input.budget.maxAgentActivations) throw new Error('invalid policy candidate');
    const plan: CollaborationPlan = new CollaborationPlan();
    plan.taskId = input.taskId;
    plan.mode = candidate.mode;
    plan.roleRegistryDigest = this.digest.digest('collaboration-registry|' + this.roles.snapshot().snapshotDigest);
    const registered: RoleRegistryEntry[] = this.roles.activeEntries();
    for (let i: number = 0; i < candidate.roles.length; i++) {
      const selected: CollaborationCandidateRole = candidate.roles[i];
      if (selected === null || typeof selected !== 'object') throw new Error('invalid role');
      const role: RoleRegistryEntry | undefined = registered.find((item: RoleRegistryEntry) =>
        item.roleId === selected.roleId && item.roleVersion === selected.roleVersion &&
        item.registryDigest === selected.registryDigest);
      if (role === undefined || typeof selected.modelId !== 'string') throw new Error('unknown role');
      const model: ModelRegistryEntry | undefined = this.models.get(selected.modelId);
      if (model === undefined || !model.available || model.modelVersion !== selected.modelVersion ||
        model.registryDigest !== selected.modelRegistryDigest) throw new Error('unknown model');
      const assignment: CollaborationRoleAssignment = new CollaborationRoleAssignment();
      assignment.roleId = role.roleId;
      assignment.roleVersion = role.roleVersion;
      assignment.roleRegistryDigest = this.digest.digest('collaboration-role|' + role.roleId + '|' +
        role.roleVersion + '|' + role.registryDigest);
      plan.assignments.push(assignment);
    }
    plan.decisionDigest = this.digest.digest(JSON.stringify(candidate));
    if (!CollaborationPlanValidator.validate(plan, input.frame, input.budget.maxAgentActivations).valid) {
      throw new Error('invalid collaboration plan');
    }
    return plan;
  }

  private registryIdentity(): string {
    return this.digest.digest(this.roles.snapshot().snapshotDigest + '|' + this.models.snapshot().snapshotDigest);
  }

  private identity(frame: TaskFrame, maxAgentActivations: number): string {
    return JSON.stringify(frame) + '|' + maxAgentActivations.toString() + '|' + this.registryIdentity();
  }
}
