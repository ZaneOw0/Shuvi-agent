import { describe, expect, it } from '@ohos/hypium';
import { ArtifactKind, ArtifactLifecycleStatus, CollaborationMode, ExecutionBudget,
  PrivacyClass, TaskFrame } from '@harmony_agent/agent-contracts';
import { ArtifactCollaborationPolicy, ArtifactCollaborationPolicyConfig, CollaborationPolicyLoaderPort,
  CollaborationPolicyEvaluatorPort, CollaborationPolicyInput, CollaborationPolicyCandidate,
  CollaborationCandidateRole } from '../main/ets/routing/ArtifactCollaborationPolicy';
import { prepareCollaboration, CollaborationPreparationOutcome } from '../main/ets/routing/CollaborationPreparation';
import { CollaborationPlanDigestPort } from '../main/ets/orchestration/RuntimePorts';
import { ArtifactPolicyCancellationSource } from '../main/ets/artifact/ArtifactPolicyExecutionControl';
import { ArtifactRegistryEntry } from '../main/ets/artifact/ArtifactRegistryTypes';
import { ArtifactCanaryAssignmentPort, ArtifactReleaseRegistryViewPort } from '../main/ets/artifact/ArtifactPolicyReleaseTypes';
import { ModelRegistry, RoleRegistry } from '../main/ets/registry/Registries';
import { ModelRegistryEntry, RoleRegistryEntry } from '../main/ets/registry/RegistryTypes';

// Deterministic test digest only. Not a cryptographic implementation or research checkpoint.
class FakeDigest implements CollaborationPlanDigestPort {
  digest(input: string): string {
    let hash: number = 0;
    for (let i: number = 0; i < input.length; i++) hash = (hash * 31 + input.charCodeAt(i)) >>> 0;
    return 'sha256:' + hash.toString(16).padStart(8, '0').repeat(8);
  }
}

class FakeRelease implements ArtifactReleaseRegistryViewPort, ArtifactCanaryAssignmentPort {
  enabled: boolean = true;
  reads: number = 0;
  shadowArtifacts(kind: ArtifactKind): ArtifactRegistryEntry[] { this.reads++; return []; }
  canaryArtifact(kind: ArtifactKind): ArtifactRegistryEntry | undefined { return undefined; }
  activeArtifact(kind: ArtifactKind): ArtifactRegistryEntry | undefined {
    if (!this.enabled) return undefined;
    const entry: ArtifactRegistryEntry = new ArtifactRegistryEntry();
    entry.manifest.artifactId = 'fake-t53-control-flow';
    entry.manifest.artifactKind = ArtifactKind.POLICY;
    entry.manifest.lifecycleStatus = ArtifactLifecycleStatus.ACTIVE;
    entry.manifest.artifactDigest = new FakeDigest().digest('fake');
    entry.packageDigest = new FakeDigest().digest('fake-package');
    return entry;
  }
  assigned(requestId: string, artifactDigest: string, traffic: number): boolean { return false; }
}

class FakeLoader implements CollaborationPolicyLoaderPort, CollaborationPolicyEvaluatorPort {
  calls: number = 0;
  fault: string = '';
  late?: (value: CollaborationPolicyCandidate) => void;
  last?: CollaborationPolicyCandidate;
  async load(artifact: ArtifactRegistryEntry): Promise<CollaborationPolicyEvaluatorPort> {
    this.calls++;
    if (this.fault === 'load') throw new Error('fake load failure');
    return this;
  }
  async evaluate(input: CollaborationPolicyInput): Promise<CollaborationPolicyCandidate> {
    const value: CollaborationPolicyCandidate = new CollaborationPolicyCandidate();
    value.taskId = input.taskId;
    value.inputDigest = input.inputDigest;
    value.registryDigest = input.registryDigest;
    value.artifactDigest = new FakeDigest().digest('fake');
    value.confidence = 0.95;
    value.mode = CollaborationMode.MULTI;
    for (const id of ['planner', 'verifier']) {
      const role: CollaborationCandidateRole = new CollaborationCandidateRole();
      role.roleId = id;
      role.roleVersion = '1';
      role.registryDigest = 'role-' + id;
      role.modelId = 'model';
      role.modelVersion = '1';
      role.modelRegistryDigest = 'model-digest';
      value.roles.push(role);
    }
    if (this.fault === 'confidence') value.confidence = 0.1;
    if (this.fault === 'nan') value.confidence = NaN;
    if (this.fault === 'infinity') value.estimatedCostMicros = Infinity;
    if (this.fault === 'cost') value.estimatedCostMicros = 10000;
    if (this.fault === 'role') value.roles[0].roleId = 'unknown';
    if (this.fault === 'role-version') value.roles[0].roleVersion = '2';
    if (this.fault === 'model') value.roles[0].modelId = 'unknown';
    if (this.fault === 'duplicate') value.roles[1] = value.roles[0];
    if (this.fault === 'input') value.inputDigest = 'wrong';
    if (this.fault === 'artifact') value.artifactDigest = 'wrong';
    this.last = value;
    if (this.fault === 'pending') return new Promise<CollaborationPolicyCandidate>((resolve) => { this.late = resolve; });
    return value;
  }
}

class Fixture {
  roles: RoleRegistry = new RoleRegistry();
  models: ModelRegistry = new ModelRegistry();
  release: FakeRelease = new FakeRelease();
  loader: FakeLoader = new FakeLoader();
  frame: TaskFrame = new TaskFrame();
  budget: ExecutionBudget = new ExecutionBudget();
  policy: ArtifactCollaborationPolicy;
  constructor(enabled: boolean = true) {
    for (const id of ['planner', 'verifier']) {
      const role: RoleRegistryEntry = new RoleRegistryEntry();
      role.roleId = id; role.roleVersion = '1'; role.registryDigest = 'role-' + id;
      role.capabilityTags = ['reasoning']; role.enabled = true;
      expect(this.roles.register(role).accepted).assertTrue();
    }
    const model: ModelRegistryEntry = new ModelRegistryEntry();
    model.modelId = 'model'; model.providerId = 'fake'; model.modelVersion = '1';
    model.registryDigest = 'model-digest'; model.available = true;
    model.capabilityTags = ['reasoning']; model.regions = ['test']; model.privacyClasses = [PrivacyClass.PERSONAL];
    expect(this.models.register(model).accepted).assertTrue();
    this.frame.taskId = 'task'; this.frame.goal = 'reason'; this.frame.capabilityCategories = ['reasoning'];
    this.budget.maxAgentActivations = 4; this.budget.maxMonetaryCostMicros = 100;
    const config: ArtifactCollaborationPolicyConfig = new ArtifactCollaborationPolicyConfig();
    config.learnedEnabled = enabled;
    this.policy = new ArtifactCollaborationPolicy(this.roles, this.models, new FakeDigest(),
      this.release, this.loader, this.release, config);
  }
  async prepare(): Promise<void> { await this.policy.prepare(this.frame, this.budget, new ArtifactPolicyCancellationSource()); }
}

export default function collaborationPreparationTests(): void {
  describe('T53CollaborationPreparation', () => {
    it('disabledDoesNotReadReleaseOrLoadArtifact', 0, async () => {
      const f: Fixture = new Fixture(false); await f.prepare();
      expect(f.loader.calls).assertEqual(0); expect(f.release.reads).assertEqual(0);
      expect(f.policy.selectPlan(f.frame, 4).mode).assertEqual(CollaborationMode.SINGLE);
    });
    it('validatedFakeSelectsMultiAndReturnsDefensiveCopy', 0, async () => {
      const f: Fixture = new Fixture(); await f.prepare();
      const plan = f.policy.selectPlan(f.frame, 4);
      expect(plan.mode).assertEqual(CollaborationMode.MULTI);
      plan.assignments[0].roleId = 'mutated';
      expect(f.policy.selectPlan(f.frame, 4).assignments[0].roleId).assertEqual('planner');
    });
    for (const fault of ['load', 'confidence', 'nan', 'infinity', 'cost', 'role', 'role-version', 'model', 'duplicate', 'input', 'artifact']) {
      it('fallsBack_' + fault, 0, async () => {
        const f: Fixture = new Fixture(); f.loader.fault = fault; await f.prepare();
        expect(f.policy.selectPlan(f.frame, 4).mode).assertEqual(CollaborationMode.SINGLE);
      });
    }
    it('missingReleaseAndInsufficientBudgetFallBack', 0, async () => {
      const f: Fixture = new Fixture(); f.release.enabled = false; await f.prepare();
      expect(f.loader.calls).assertEqual(0);
      f.release.enabled = true; f.budget.maxAgentActivations = 1; await f.prepare();
      expect(f.policy.selectPlan(f.frame, 1).mode).assertEqual(CollaborationMode.SINGLE);
    });
    it('rejectsCrossTaskChangedInputAndRegistryDrift', 0, async () => {
      const f: Fixture = new Fixture(); await f.prepare();
      f.frame.taskId = 'other'; expect(f.policy.selectPlan(f.frame, 4).mode).assertEqual(CollaborationMode.SINGLE);
      f.frame.taskId = 'task'; f.frame.goal = 'changed';
      expect(f.policy.selectPlan(f.frame, 4).mode).assertEqual(CollaborationMode.SINGLE);
      f.frame.goal = 'reason';
      const role = f.roles.activeEntries()[0]; role.roleVersion = '2';
      expect(f.roles.register(role).accepted).assertTrue();
      expect(f.policy.selectPlan(f.frame, 4).mode).assertEqual(CollaborationMode.SINGLE);
    });
    it('totalDeadlineDiscardsLateResult', 0, async () => {
      const f: Fixture = new Fixture(); f.loader.fault = 'pending';
      const result = await prepareCollaboration(f.policy, f.frame, f.budget, new ArtifactPolicyCancellationSource(), 10);
      expect(result).assertEqual(CollaborationPreparationOutcome.FALLBACK);
      const late = f.loader.late; const candidate = f.loader.last;
      if (late !== undefined && candidate !== undefined) late(candidate);
      await Promise.resolve(); await Promise.resolve();
      expect(f.policy.selectPlan(f.frame, 4).mode).assertEqual(CollaborationMode.SINGLE);
    });
    it('preCancelledDoesNotInvokeLoader', 0, async () => {
      const f: Fixture = new Fixture(); const source = new ArtifactPolicyCancellationSource(); source.cancel();
      expect(await prepareCollaboration(f.policy, f.frame, f.budget, source, 10))
        .assertEqual(CollaborationPreparationOutcome.INTERRUPTED);
      expect(f.loader.calls).assertEqual(0);
    });
    it('newPreparationInvalidatesOlderGeneration', 0, async () => {
      const f: Fixture = new Fixture(); f.loader.fault = 'pending';
      const first = f.prepare();
      // Yield until the fake evaluator has actually entered its pending operation.
      for (let i: number = 0; i < 30 && f.loader.late === undefined; i++) await Promise.resolve();
      const late = f.loader.late; const candidate = f.loader.last;
      expect(late !== undefined && candidate !== undefined).assertTrue();
      f.loader.fault = 'confidence'; await f.prepare();
      if (late !== undefined && candidate !== undefined) late(candidate);
      await first;
      expect(f.policy.selectPlan(f.frame, 4).mode).assertEqual(CollaborationMode.SINGLE);
    });
  });
}
