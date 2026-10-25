import {
  ARTIFACT_REGISTRY_SCHEMA_VERSION,
  ArtifactRegistryPersistencePort,
  ArtifactRegistrySnapshot,
  ArtifactRegistrySnapshotEnvelope
} from '@harmony_agent/agent-runtime';
import { DurableExecutionRecoveryStore } from '../storage/DurableExecutionRecoveryStore';
import {
  StorageWriteResult,
  StoredRegistryRecord
} from '../storage/StorageTypes';

export const ARTIFACT_REGISTRY_RECORD_ID: string = 'artifact-registry:m11';

/**
 * Persists the Runtime-owned Artifact Registry snapshot through the existing
 * durable execution-store CAS. This adapter exposes storage only and cannot
 * submit, control, authorize, or advance an Agent task.
 */
export class DurableArtifactRegistryAdapter implements ArtifactRegistryPersistencePort {
  private readonly store: DurableExecutionRecoveryStore;

  constructor(store: DurableExecutionRecoveryStore) {
    this.store = store;
  }

  load(): ArtifactRegistrySnapshotEnvelope | undefined {
    const record: StoredRegistryRecord | undefined = this.store.getRegistryRecord(ARTIFACT_REGISTRY_RECORD_ID);
    if (record === undefined) return undefined;
    let parsed: ArtifactRegistrySnapshotEnvelope;
    try {
      parsed = JSON.parse(record.payloadJson) as ArtifactRegistrySnapshotEnvelope;
    } catch (error) {
      throw new Error('artifact registry record is not valid JSON');
    }
    const recordRevision: number = Number(record.recordVersion);
    if (parsed.schemaVersion !== ARTIFACT_REGISTRY_SCHEMA_VERSION ||
      !Number.isSafeInteger(recordRevision) || recordRevision <= 0 || parsed.revision !== recordRevision ||
      parsed.payloadDigest !== record.recordDigest || parsed.payloadJson.length === 0) {
      throw new Error('artifact registry record metadata does not match its envelope');
    }
    const result: ArtifactRegistrySnapshotEnvelope = new ArtifactRegistrySnapshotEnvelope();
    result.schemaVersion = parsed.schemaVersion;
    result.revision = parsed.revision;
    result.payloadJson = parsed.payloadJson;
    result.payloadDigest = parsed.payloadDigest;
    return result;
  }

  async compareAndSet(expectedRevision: number, next: ArtifactRegistrySnapshotEnvelope,
    nowMs: number): Promise<boolean> {
    if (!Number.isSafeInteger(expectedRevision) || expectedRevision < 0 ||
      !Number.isSafeInteger(nowMs) || nowMs < 0 ||
      next.schemaVersion !== ARTIFACT_REGISTRY_SCHEMA_VERSION ||
      next.revision !== expectedRevision + 1 || next.payloadJson.length === 0 ||
      next.payloadDigest.length === 0) return false;
    let payload: ArtifactRegistrySnapshot;
    try {
      payload = JSON.parse(next.payloadJson) as ArtifactRegistrySnapshot;
    } catch (error) {
      return false;
    }
    if (payload.schemaVersion !== ARTIFACT_REGISTRY_SCHEMA_VERSION || payload.revision !== next.revision ||
      !Array.isArray(payload.entries) || !Array.isArray(payload.channels)) return false;
    const current: StoredRegistryRecord | undefined = this.store.getRegistryRecord(ARTIFACT_REGISTRY_RECORD_ID);
    if (current === undefined) {
      if (expectedRevision !== 0) return false;
    } else {
      try {
        const loaded: ArtifactRegistrySnapshotEnvelope | undefined = this.load();
        if (loaded === undefined || loaded.revision !== expectedRevision) return false;
      } catch (error) {
        return false;
      }
    }
    const record: StoredRegistryRecord = new StoredRegistryRecord();
    record.recordId = ARTIFACT_REGISTRY_RECORD_ID;
    record.recordVersion = next.revision.toString();
    record.recordDigest = next.payloadDigest;
    record.payloadJson = JSON.stringify(next);
    record.updatedAtMs = nowMs;
    const saved: StorageWriteResult = await this.store.saveRegistryRecord(record);
    return saved.accepted && !saved.duplicate;
  }
}
