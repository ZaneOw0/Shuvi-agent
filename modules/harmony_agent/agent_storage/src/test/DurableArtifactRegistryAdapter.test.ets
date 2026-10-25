import { describe, expect, it } from '@ohos/hypium';
import {
  ArtifactApprovalStatus,
  ArtifactKind,
  ArtifactLifecycleStatus,
  ArtifactManifest,
  ContractCodec
} from '@harmony_agent/agent-contracts';
import {
  ArtifactPackageVerifierPort,
  ArtifactRegistry,
  ArtifactRegistryDigestPort,
  ArtifactRegistrySnapshotEnvelope,
  ArtifactRuntimeEnvironment
} from '@harmony_agent/agent-runtime';
import {
  ARTIFACT_REGISTRY_RECORD_ID,
  DurableArtifactRegistryAdapter,
  DurableExecutionRecoveryStore,
  DurableSnapshotBackendPort,
  SnapshotIntegrityPort,
  StorageSnapshotEnvelope,
  StoredRegistryRecord
} from '../../Index';

class FixtureIntegrity implements SnapshotIntegrityPort {
  digest(payloadJson: string): string {
    return 'storage-integrity:' + payloadJson;
  }
}

function copyStorageEnvelope(source: StorageSnapshotEnvelope): StorageSnapshotEnvelope {
  const value: StorageSnapshotEnvelope = new StorageSnapshotEnvelope();
  value.schemaVersion = source.schemaVersion;
  value.revision = source.revision;
  value.payloadJson = source.payloadJson;
  value.payloadDigest = source.payloadDigest;
  return value;
}

class FixtureBackend implements DurableSnapshotBackendPort {
  snapshot?: StorageSnapshotEnvelope;

  async initialize(): Promise<void> {
  }

  async load(): Promise<StorageSnapshotEnvelope | undefined> {
    return this.snapshot === undefined ? undefined : copyStorageEnvelope(this.snapshot);
  }

  async compareAndSet(expectedRevision: number, next: StorageSnapshotEnvelope): Promise<boolean> {
    const currentRevision: number = this.snapshot === undefined ? 0 : this.snapshot.revision;
    if (currentRevision !== expectedRevision || next.revision <= expectedRevision) return false;
    this.snapshot = copyStorageEnvelope(next);
    return true;
  }
}

class FixtureArtifactDigest implements ArtifactRegistryDigestPort {
  digest(payloadJson: string): string {
    return 'artifact-registry-digest:' + payloadJson;
  }
}

class FixtureVerifier implements ArtifactPackageVerifierPort {
  verify(packageDigest: string, manifest: ArtifactManifest): boolean {
    return packageDigest.startsWith('sha256:') && manifest.signingKeyId === 'fixture-release-key';
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

function artifact(status: ArtifactLifecycleStatus = ArtifactLifecycleStatus.DISABLED): ArtifactManifest {
  const value: ArtifactManifest = new ArtifactManifest();
  value.artifactId = 'policy-a';
  value.artifactKind = ArtifactKind.POLICY;
  value.algorithm = 'MTRouter';
  value.artifactVersion = '1.0.0';
  value.sourceCommit = '0123456789abcdef0123456789abcdef01234567';
  value.sourceLicense = 'MIT';
  value.trainingDataLineage = ['harmony-agent-bench:system-live:20261017'];
  value.modelAndProviderSnapshotJson = '{"provider":"fixture","model":"fixture"}';
  value.featureSchemaVersion = 'router-features-1';
  value.runtimeCompatibility = ['harmony_agent-runtime>=0.14.0', 'api>=26'];
  value.artifactDigest = digest('a');
  value.paperReproductionResultsJson = '{"qualityBasisPoints":7500}';
  value.portParityResultsJson = '{"matched":12,"total":12}';
  value.harmonyAgentBenchResultsJson = '{"qualityPassed":19,"total":24}';
  value.lifecycleStatus = status;
  return value;
}

function withStatus(source: ArtifactManifest, status: ArtifactLifecycleStatus): ArtifactManifest {
  const value: ArtifactManifest = ContractCodec.parseArtifactManifest(ContractCodec.stringify(source));
  value.lifecycleStatus = status;
  if (status === ArtifactLifecycleStatus.CANARY || status === ArtifactLifecycleStatus.ACTIVE) {
    value.approvalStatus = ArtifactApprovalStatus.APPROVED;
    value.approvedBy = 'fixture-release-policy';
    value.approvedAt = '2026-10-18T02:00:00+08:00';
    value.signedManifestDigest = digest('e');
    value.signatureAlgorithm = 'Ed25519';
    value.signingKeyId = 'fixture-release-key';
    value.signatureBase64 = 'YWJjZA==';
    value.signedAt = '2026-10-18T02:01:00+08:00';
  }
  return value;
}

async function openDurable(backend: FixtureBackend): Promise<DurableExecutionRecoveryStore> {
  const opened = await DurableExecutionRecoveryStore.open(backend, new FixtureIntegrity());
  expect(opened.accepted).assertTrue();
  return opened.store as DurableExecutionRecoveryStore;
}

async function openRegistry(store: DurableExecutionRecoveryStore): Promise<ArtifactRegistry> {
  const opened = await ArtifactRegistry.open(
    environment(), new FixtureVerifier(), new DurableArtifactRegistryAdapter(store), new FixtureArtifactDigest());
  expect(opened.accepted).assertTrue();
  return opened.registry as ArtifactRegistry;
}

export default function durableArtifactRegistryAdapterTest(): void {
  describe('DurableArtifactRegistryAdapter', () => {
    it('persistsAndRestoresTheRuntimeOwnedArtifactRegistry', 0, async () => {
      const backend: FixtureBackend = new FixtureBackend();
      const firstStore: DurableExecutionRecoveryStore = await openDurable(backend);
      const first: ArtifactRegistry = await openRegistry(firstStore);
      const disabled: ArtifactManifest = artifact();
      await first.publish(digest('1'), disabled, 100);
      const shadow: ArtifactManifest = withStatus(disabled, ArtifactLifecycleStatus.SHADOW);
      await first.publish(digest('2'), shadow, 101);
      const canary: ArtifactManifest = withStatus(shadow, ArtifactLifecycleStatus.CANARY);
      await first.publish(digest('3'), canary, 102);
      const active: ArtifactManifest = withStatus(canary, ArtifactLifecycleStatus.ACTIVE);
      expect((await first.publish(digest('4'), active, 103)).accepted).assertTrue();

      const reopenedStore: DurableExecutionRecoveryStore = await openDurable(backend);
      const reopened: ArtifactRegistry = await openRegistry(reopenedStore);
      expect(reopened.revision()).assertEqual(4);
      expect(reopened.activeArtifact(ArtifactKind.POLICY)?.manifest.artifactId).assertEqual('policy-a');
      expect(reopenedStore.getRegistryRecord(ARTIFACT_REGISTRY_RECORD_ID)?.recordVersion).assertEqual('4');
    });

    it('keepsOneWinnerAcrossCompetingDurableSessions', 0, async () => {
      const backend: FixtureBackend = new FixtureBackend();
      const first: ArtifactRegistry = await openRegistry(await openDurable(backend));
      const second: ArtifactRegistry = await openRegistry(await openDurable(backend));
      expect((await first.publish(digest('1'), artifact(), 100)).accepted).assertTrue();
      const losing = await second.publish(digest('2'), artifact(), 101);
      expect(losing.accepted).assertFalse();
      expect(second.revision()).assertEqual(0);
      expect(second.get('policy-a') === undefined).assertTrue();
    });

    it('failsClosedWhenStoredRecordMetadataIsCorrupt', 0, async () => {
      const backend: FixtureBackend = new FixtureBackend();
      const store: DurableExecutionRecoveryStore = await openDurable(backend);
      const envelope: ArtifactRegistrySnapshotEnvelope = new ArtifactRegistrySnapshotEnvelope();
      envelope.revision = 1;
      envelope.payloadJson = '{"schemaVersion":"1.0","revision":1,"entries":[],"channels":[]}';
      envelope.payloadDigest = 'artifact-registry-digest:' + envelope.payloadJson;
      const record: StoredRegistryRecord = new StoredRegistryRecord();
      record.recordId = ARTIFACT_REGISTRY_RECORD_ID;
      record.recordVersion = '2';
      record.recordDigest = envelope.payloadDigest;
      record.payloadJson = JSON.stringify(envelope);
      record.updatedAtMs = 100;
      expect((await store.saveRegistryRecord(record)).accepted).assertTrue();
      const opened = await ArtifactRegistry.open(
        environment(), new FixtureVerifier(), new DurableArtifactRegistryAdapter(store),
        new FixtureArtifactDigest());
      expect(opened.accepted).assertFalse();
      const next: ArtifactRegistrySnapshotEnvelope = new ArtifactRegistrySnapshotEnvelope();
      next.revision = 3;
      next.payloadJson = '{"schemaVersion":"1.0","revision":3,"entries":[],"channels":[]}';
      next.payloadDigest = 'artifact-registry-digest:' + next.payloadJson;
      expect(await new DurableArtifactRegistryAdapter(store).compareAndSet(2, next, 101)).assertFalse();
      expect(store.getRegistryRecord(ARTIFACT_REGISTRY_RECORD_ID)?.recordVersion).assertEqual('2');
    });
  });
}
