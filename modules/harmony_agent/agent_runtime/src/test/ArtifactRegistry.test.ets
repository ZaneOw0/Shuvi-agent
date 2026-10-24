import { describe, expect, it } from '@ohos/hypium';
import {
  ArtifactApprovalStatus,
  ArtifactKind,
  ArtifactLifecycleStatus,
  ArtifactManifest,
  ContractCodec
} from '@harmony_agent/agent-contracts';
import {
  ArtifactBaselinePolicyPort,
  ArtifactCanaryAssignmentPort,
  ArtifactPolicyDecision,
  ArtifactPolicyExecutionMode,
  ArtifactPolicyReleaseConfig,
  ArtifactPolicyReleaseRunner,
  ArtifactPolicyRequest,
  ArtifactPackageVerifierPort,
  ArtifactRegistry,
  ArtifactRegistryDigestPort,
  ArtifactRegistryEntry,
  ArtifactRegistryPersistencePort,
  ArtifactRegistrySnapshotEnvelope,
  ArtifactRegistryWriteCode,
  ArtifactReleasedPolicyPort,
  ArtifactRuntimeCompatibilityEvaluator,
  ArtifactRuntimeEnvironment
} from '../../Index';

class RegistryRunnerBaseline implements ArtifactBaselinePolicyPort {
  async decide(request: ArtifactPolicyRequest): Promise<ArtifactPolicyDecision> {
    const value: ArtifactPolicyDecision = new ArtifactPolicyDecision();
    value.selectedId = 'baseline-choice';
    value.evidenceJson = '{"source":"baseline"}';
    return value;
  }
}

class RegistryRunnerReleased implements ArtifactReleasedPolicyPort {
  async decide(artifact: ArtifactRegistryEntry,
    request: ArtifactPolicyRequest): Promise<ArtifactPolicyDecision> {
    const value: ArtifactPolicyDecision = new ArtifactPolicyDecision();
    value.selectedId = artifact.manifest.artifactId + '-choice';
    value.evidenceJson = '{"source":"released"}';
    return value;
  }
}

class RegistryRunnerAssignment implements ArtifactCanaryAssignmentPort {
  assigned(requestId: string, artifactDigest: string, trafficBasisPoints: number): boolean {
    return false;
  }
}

class FixtureVerifier implements ArtifactPackageVerifierPort {
  accepted: boolean = true;
  throwOnVerify: boolean = false;
  calls: number = 0;

  verify(packageDigest: string, manifest: ArtifactManifest): boolean {
    this.calls++;
    if (this.throwOnVerify) throw new Error('fixture verifier failed');
    return this.accepted && packageDigest.length > 0 && manifest.signingKeyId === 'fixture-release-key';
  }
}

class FixtureRegistryDigest implements ArtifactRegistryDigestPort {
  digest(payloadJson: string): string {
    return 'registry-digest:' + payloadJson;
  }
}

function copyEnvelope(source: ArtifactRegistrySnapshotEnvelope): ArtifactRegistrySnapshotEnvelope {
  const result: ArtifactRegistrySnapshotEnvelope = new ArtifactRegistrySnapshotEnvelope();
  result.schemaVersion = source.schemaVersion;
  result.revision = source.revision;
  result.payloadJson = source.payloadJson;
  result.payloadDigest = source.payloadDigest;
  return result;
}

class FixtureRegistryPersistence implements ArtifactRegistryPersistencePort {
  envelope?: ArtifactRegistrySnapshotEnvelope;
  failNextWrite: boolean = false;

  load(): ArtifactRegistrySnapshotEnvelope | undefined {
    return this.envelope === undefined ? undefined : copyEnvelope(this.envelope);
  }

  async compareAndSet(expectedRevision: number, next: ArtifactRegistrySnapshotEnvelope,
    nowMs: number): Promise<boolean> {
    if (this.failNextWrite) {
      this.failNextWrite = false;
      return false;
    }
    const currentRevision: number = this.envelope === undefined ? 0 : this.envelope.revision;
    if (currentRevision !== expectedRevision || next.revision !== expectedRevision + 1 || nowMs < 0) return false;
    this.envelope = copyEnvelope(next);
    return true;
  }
}

function digest(character: string): string {
  return 'sha256:' + character.repeat(64);
}

function environment(): ArtifactRuntimeEnvironment {
  const value: ArtifactRuntimeEnvironment = new ArtifactRuntimeEnvironment();
  value.runtimeVersion = '0.14.0';
  value.apiVersion = 26;
  value.supportedFeatureSchemaVersions = ['router-features-1'];
  return value;
}

function artifact(artifactId: string, artifactDigest: string,
  status: ArtifactLifecycleStatus = ArtifactLifecycleStatus.DISABLED): ArtifactManifest {
  const value: ArtifactManifest = new ArtifactManifest();
  value.artifactId = artifactId;
  value.artifactKind = ArtifactKind.POLICY;
  value.algorithm = 'MTRouter';
  value.artifactVersion = '1.0.0';
  value.sourceCommit = '0123456789abcdef0123456789abcdef01234567';
  value.sourceLicense = 'MIT';
  value.trainingDataLineage = ['harmony-agent-bench:system-live:20261017'];
  value.modelAndProviderSnapshotJson = '{"provider":"fixture","model":"fixture"}';
  value.featureSchemaVersion = 'router-features-1';
  value.runtimeCompatibility = ['harmony_agent-runtime>=0.14.0', 'api>=26'];
  value.artifactDigest = artifactDigest;
  value.paperReproductionResultsJson = '{"qualityBasisPoints":7500}';
  value.portParityResultsJson = '{"matched":12,"total":12}';
  value.harmonyAgentBenchResultsJson = '{"qualityPassed":19,"total":24}';
  value.lifecycleStatus = status;
  if (status === ArtifactLifecycleStatus.CANARY || status === ArtifactLifecycleStatus.ACTIVE ||
    status === ArtifactLifecycleStatus.ROLLED_BACK) {
    value.approvalStatus = ArtifactApprovalStatus.APPROVED;
    value.approvedBy = 'fixture-release-policy';
    value.approvedAt = '2026-10-18T01:00:00+08:00';
    value.signedManifestDigest = digest('e');
    value.signatureAlgorithm = 'Ed25519';
    value.signingKeyId = 'fixture-release-key';
    value.signatureBase64 = 'YWJjZA==';
    value.signedAt = '2026-10-18T01:01:00+08:00';
  }
  return value;
}

function withStatus(source: ArtifactManifest, status: ArtifactLifecycleStatus): ArtifactManifest {
  const value: ArtifactManifest = ContractCodec.parseArtifactManifest(ContractCodec.stringify(source));
  value.lifecycleStatus = status;
  if (status === ArtifactLifecycleStatus.CANARY || status === ArtifactLifecycleStatus.ACTIVE ||
    status === ArtifactLifecycleStatus.ROLLED_BACK) {
    value.approvalStatus = ArtifactApprovalStatus.APPROVED;
    value.approvedBy = 'fixture-release-policy';
    value.approvedAt = '2026-10-18T01:00:00+08:00';
    value.signedManifestDigest = digest('e');
    value.signatureAlgorithm = 'Ed25519';
    value.signingKeyId = 'fixture-release-key';
    value.signatureBase64 = 'YWJjZA==';
    value.signedAt = '2026-10-18T01:01:00+08:00';
  } else {
    value.approvalStatus = ArtifactApprovalStatus.UNREVIEWED;
    value.approvedBy = '';
    value.approvedAt = undefined;
    value.signedManifestDigest = '';
    value.signatureAlgorithm = '';
    value.signingKeyId = '';
    value.signatureBase64 = '';
    value.signedAt = undefined;
    value.rollbackTargetDigest = undefined;
  }
  return value;
}

async function openRegistry(persistence: FixtureRegistryPersistence,
  verifier: FixtureVerifier = new FixtureVerifier()): Promise<ArtifactRegistry> {
  const opened = await ArtifactRegistry.open(
    environment(), verifier, persistence, new FixtureRegistryDigest());
  expect(opened.accepted).assertTrue();
  return opened.registry as ArtifactRegistry;
}

async function publishActive(registry: ArtifactRegistry, artifactId: string,
  artifactDigest: string, timeOffset: number): Promise<void> {
  const disabled: ArtifactManifest = artifact(artifactId, artifactDigest);
  expect((await registry.publish(digest('1'), disabled, timeOffset)).accepted).assertTrue();
  const shadow: ArtifactManifest = withStatus(disabled, ArtifactLifecycleStatus.SHADOW);
  expect((await registry.publish(digest('2'), shadow, timeOffset + 1)).accepted).assertTrue();
  const canary: ArtifactManifest = withStatus(shadow, ArtifactLifecycleStatus.CANARY);
  expect((await registry.publish(digest('3'), canary, timeOffset + 2)).accepted).assertTrue();
  const active: ArtifactManifest = withStatus(canary, ArtifactLifecycleStatus.ACTIVE);
  expect((await registry.publish(digest('4'), active, timeOffset + 3)).accepted).assertTrue();
}

export default function artifactRegistryTest(): void {
  describe('ArtifactRegistry', () => {
    it('evaluatesRuntimeApiAndFeatureSchemaCompatibility', 0, () => {
      const manifest: ArtifactManifest = artifact('policy-a', digest('a'), ArtifactLifecycleStatus.SHADOW);
      expect(ArtifactRuntimeCompatibilityEvaluator.evaluate(manifest, environment()).compatible).assertTrue();
      const oldRuntime: ArtifactRuntimeEnvironment = environment();
      oldRuntime.runtimeVersion = '0.13.9';
      expect(ArtifactRuntimeCompatibilityEvaluator.evaluate(manifest, oldRuntime).compatible).assertFalse();
      manifest.runtimeCompatibility.push('device=phone');
      expect(ArtifactRuntimeCompatibilityEvaluator.evaluate(manifest, environment()).compatible).assertFalse();
    });

    it('publishesShadowCanaryAndActiveThroughDurableTransitions', 0, async () => {
      const persistence: FixtureRegistryPersistence = new FixtureRegistryPersistence();
      const verifier: FixtureVerifier = new FixtureVerifier();
      const registry: ArtifactRegistry = await openRegistry(persistence, verifier);
      await publishActive(registry, 'policy-a', digest('a'), 100);
      expect(registry.revision()).assertEqual(4);
      expect(registry.activeArtifact(ArtifactKind.POLICY)?.manifest.artifactId).assertEqual('policy-a');
      expect(registry.canaryArtifact(ArtifactKind.POLICY) === undefined).assertTrue();
      expect(verifier.calls).assertEqual(2);
    });

    it('rejectsDirectActivationAndSameStateDrift', 0, async () => {
      const registry: ArtifactRegistry = await openRegistry(new FixtureRegistryPersistence());
      const disabled: ArtifactManifest = artifact('policy-a', digest('a'));
      await registry.publish(digest('1'), disabled, 100);
      const shadow: ArtifactManifest = withStatus(disabled, ArtifactLifecycleStatus.SHADOW);
      await registry.publish(digest('2'), shadow, 101);
      const active: ArtifactManifest = withStatus(shadow, ArtifactLifecycleStatus.ACTIVE);
      expect((await registry.publish(digest('3'), active, 102)).code)
        .assertEqual(ArtifactRegistryWriteCode.INVALID_TRANSITION);
      shadow.approvedBy = 'drift';
      expect((await registry.publish(digest('4'), shadow, 103)).code)
        .assertEqual(ArtifactRegistryWriteCode.INVALID_TRANSITION);
    });

    it('failsClosedOnVerificationAndRuntimeCompatibility', 0, async () => {
      const verifier: FixtureVerifier = new FixtureVerifier();
      const registry: ArtifactRegistry = await openRegistry(new FixtureRegistryPersistence(), verifier);
      const disabled: ArtifactManifest = artifact('policy-a', digest('a'));
      await registry.publish(digest('1'), disabled, 100);
      const shadow: ArtifactManifest = withStatus(disabled, ArtifactLifecycleStatus.SHADOW);
      await registry.publish(digest('2'), shadow, 101);
      const canary: ArtifactManifest = withStatus(shadow, ArtifactLifecycleStatus.CANARY);
      verifier.accepted = false;
      expect((await registry.publish(digest('3'), canary, 102)).code)
        .assertEqual(ArtifactRegistryWriteCode.VERIFICATION_FAILED);
      verifier.accepted = true;
      canary.featureSchemaVersion = 'unknown-schema';
      expect((await registry.publish(digest('3'), canary, 102)).code)
        .assertEqual(ArtifactRegistryWriteCode.INCOMPATIBLE_RUNTIME);
      expect(registry.revision()).assertEqual(2);
    });

    it('turnsVerifierExceptionsIntoStableRejection', 0, async () => {
      const verifier: FixtureVerifier = new FixtureVerifier();
      const registry: ArtifactRegistry = await openRegistry(new FixtureRegistryPersistence(), verifier);
      const disabled: ArtifactManifest = artifact('policy-a', digest('a'));
      await registry.publish(digest('1'), disabled, 100);
      const shadow: ArtifactManifest = withStatus(disabled, ArtifactLifecycleStatus.SHADOW);
      await registry.publish(digest('2'), shadow, 101);
      verifier.throwOnVerify = true;
      const canary: ArtifactManifest = withStatus(shadow, ArtifactLifecycleStatus.CANARY);
      expect((await registry.publish(digest('3'), canary, 102)).code)
        .assertEqual(ArtifactRegistryWriteCode.VERIFICATION_FAILED);
      expect(registry.revision()).assertEqual(2);
    });

    it('keepsOnlyOneCanaryPerArtifactKind', 0, async () => {
      const registry: ArtifactRegistry = await openRegistry(new FixtureRegistryPersistence());
      const first: ArtifactManifest = artifact('policy-a', digest('a'));
      await registry.publish(digest('1'), first, 100);
      const firstShadow: ArtifactManifest = withStatus(first, ArtifactLifecycleStatus.SHADOW);
      await registry.publish(digest('2'), firstShadow, 101);
      await registry.publish(digest('3'), withStatus(firstShadow, ArtifactLifecycleStatus.CANARY), 102);
      const second: ArtifactManifest = artifact('policy-b', digest('b'));
      await registry.publish(digest('4'), second, 103);
      const secondShadow: ArtifactManifest = withStatus(second, ArtifactLifecycleStatus.SHADOW);
      await registry.publish(digest('5'), secondShadow, 104);
      expect((await registry.publish(
        digest('6'), withStatus(secondShadow, ArtifactLifecycleStatus.CANARY), 105)).code)
        .assertEqual(ArtifactRegistryWriteCode.CANARY_CONFLICT);
    });

    it('replacesActiveSelectionAndRollsBackByDigest', 0, async () => {
      const registry: ArtifactRegistry = await openRegistry(new FixtureRegistryPersistence());
      await publishActive(registry, 'policy-a', digest('a'), 100);
      await publishActive(registry, 'policy-b', digest('b'), 200);
      expect(registry.activeArtifact(ArtifactKind.POLICY)?.manifest.artifactId).assertEqual('policy-b');
      const current: ArtifactManifest = registry.get('policy-b')?.manifest as ArtifactManifest;
      const rolledBack: ArtifactManifest = withStatus(current, ArtifactLifecycleStatus.ROLLED_BACK);
      rolledBack.rollbackTargetDigest = digest('a');
      const result = await registry.publish(digest('5'), rolledBack, 300);
      expect(result.accepted).assertTrue();
      expect(result.activeArtifactDigest).assertEqual(digest('a'));
      expect(registry.activeArtifact(ArtifactKind.POLICY)?.manifest.artifactId).assertEqual('policy-a');
    });

    it('doesNotPublishWhenPersistenceCasFails', 0, async () => {
      const persistence: FixtureRegistryPersistence = new FixtureRegistryPersistence();
      const registry: ArtifactRegistry = await openRegistry(persistence);
      persistence.failNextWrite = true;
      expect((await registry.publish(digest('1'), artifact('policy-a', digest('a')), 100)).code)
        .assertEqual(ArtifactRegistryWriteCode.PERSISTENCE_CONFLICT);
      expect(registry.revision()).assertEqual(0);
      expect(registry.get('policy-a') === undefined).assertTrue();
    });

    it('restoresWithReverificationAndRejectsCorruptSnapshots', 0, async () => {
      const persistence: FixtureRegistryPersistence = new FixtureRegistryPersistence();
      const firstVerifier: FixtureVerifier = new FixtureVerifier();
      const first: ArtifactRegistry = await openRegistry(persistence, firstVerifier);
      await publishActive(first, 'policy-a', digest('a'), 100);
      const secondVerifier: FixtureVerifier = new FixtureVerifier();
      const reopened = await ArtifactRegistry.open(
        environment(), secondVerifier, persistence, new FixtureRegistryDigest());
      expect(reopened.accepted).assertTrue();
      expect(reopened.registry?.activeArtifact(ArtifactKind.POLICY)?.manifest.artifactId).assertEqual('policy-a');
      expect(secondVerifier.calls).assertEqual(1);
      if (persistence.envelope !== undefined) persistence.envelope.payloadDigest = 'corrupt';
      const rejected = await ArtifactRegistry.open(
        environment(), secondVerifier, persistence, new FixtureRegistryDigest());
      expect(rejected.accepted).assertFalse();
      expect(rejected.code).assertEqual(ArtifactRegistryWriteCode.CORRUPT_SNAPSHOT);
      if (persistence.envelope !== undefined) {
        persistence.envelope.payloadJson =
          '{"schemaVersion":"1.0","revision":4,"entries":{},"channels":[]}';
        persistence.envelope.payloadDigest = new FixtureRegistryDigest().digest(persistence.envelope.payloadJson);
      }
      const malformed = await ArtifactRegistry.open(
        environment(), secondVerifier, persistence, new FixtureRegistryDigest());
      expect(malformed.accepted).assertFalse();
    });

    it('returnsDefensiveCopiesAndRejectsArtifactIdentityDrift', 0, async () => {
      const registry: ArtifactRegistry = await openRegistry(new FixtureRegistryPersistence());
      const original: ArtifactManifest = artifact('policy-a', digest('a'));
      await registry.publish(digest('1'), original, 100);
      const copy: ArtifactManifest = registry.get('policy-a')?.manifest as ArtifactManifest;
      copy.algorithm = 'mutated';
      expect(registry.get('policy-a')?.manifest.algorithm).assertEqual('MTRouter');
      const drift: ArtifactManifest = withStatus(original, ArtifactLifecycleStatus.SHADOW);
      drift.sourceCommit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      expect((await registry.publish(digest('2'), drift, 101)).code)
        .assertEqual(ArtifactRegistryWriteCode.IDENTITY_CONFLICT);
    });

    it('changesReleasedPolicySelectionAfterDurableDigestRollback', 0, async () => {
      const registry: ArtifactRegistry = await openRegistry(new FixtureRegistryPersistence());
      await publishActive(registry, 'policy-a', digest('a'), 100);
      await publishActive(registry, 'policy-b', digest('b'), 200);
      const releaseConfig: ArtifactPolicyReleaseConfig = new ArtifactPolicyReleaseConfig();
      releaseConfig.canaryTrafficBasisPoints = 0;
      releaseConfig.maxShadowEvaluations = 2;
      const runner: ArtifactPolicyReleaseRunner = new ArtifactPolicyReleaseRunner(
        registry,
        new RegistryRunnerBaseline(),
        new RegistryRunnerReleased(),
        new RegistryRunnerAssignment(),
        releaseConfig
      );
      const policyRequest: ArtifactPolicyRequest = new ArtifactPolicyRequest();
      policyRequest.requestId = 'request-rollback';
      policyRequest.artifactKind = ArtifactKind.POLICY;
      policyRequest.candidateIds = ['baseline-choice', 'policy-a-choice', 'policy-b-choice'];
      policyRequest.inputJson = '{"fixture":true}';
      const before = await runner.run(policyRequest);
      expect(before.executionMode).assertEqual(ArtifactPolicyExecutionMode.ACTIVE);
      expect(before.decision?.selectedId).assertEqual('policy-b-choice');

      const current: ArtifactManifest = registry.get('policy-b')?.manifest as ArtifactManifest;
      const rolledBack: ArtifactManifest = withStatus(current, ArtifactLifecycleStatus.ROLLED_BACK);
      rolledBack.rollbackTargetDigest = digest('a');
      expect((await registry.publish(digest('5'), rolledBack, 300)).accepted).assertTrue();

      const after = await runner.run(policyRequest);
      expect(after.executionMode).assertEqual(ArtifactPolicyExecutionMode.ACTIVE);
      expect(after.decision?.selectedId).assertEqual('policy-a-choice');
      expect(after.selectedArtifactDigest).assertEqual(digest('a'));
    });
  });
}
