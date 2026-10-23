import {
  ArtifactKind,
  ArtifactManifest,
  ContractCodec
} from '@harmony_agent/agent-contracts';

export const ARTIFACT_REGISTRY_SCHEMA_VERSION: string = '1.0';

export enum ArtifactRegistryWriteCode {
  CREATED = 'CREATED',
  UPDATED = 'UPDATED',
  UNCHANGED = 'UNCHANGED',
  INVALID_MANIFEST = 'INVALID_MANIFEST',
  VERIFICATION_FAILED = 'VERIFICATION_FAILED',
  INCOMPATIBLE_RUNTIME = 'INCOMPATIBLE_RUNTIME',
  INVALID_TRANSITION = 'INVALID_TRANSITION',
  IDENTITY_CONFLICT = 'IDENTITY_CONFLICT',
  CANARY_CONFLICT = 'CANARY_CONFLICT',
  ROLLBACK_TARGET_NOT_FOUND = 'ROLLBACK_TARGET_NOT_FOUND',
  PERSISTENCE_CONFLICT = 'PERSISTENCE_CONFLICT',
  CORRUPT_SNAPSHOT = 'CORRUPT_SNAPSHOT'
}

export class ArtifactRegistryWriteResult {
  accepted: boolean = false;
  duplicate: boolean = false;
  code: ArtifactRegistryWriteCode = ArtifactRegistryWriteCode.INVALID_MANIFEST;
  activeArtifactDigest: string = '';
  canaryArtifactDigest: string = '';
}

export class ArtifactRuntimeEnvironment {
  runtimeVersion: string = '';
  apiVersion: number = 0;
  supportedFeatureSchemaVersions: string[] = [];
}

export class ArtifactCompatibilityResult {
  compatible: boolean = false;
  issues: string[] = [];
}

export class ArtifactRegistryEntry {
  manifest: ArtifactManifest = new ArtifactManifest();
  packageDigest: string = '';
  registeredAtMs: number = 0;
}

export class ArtifactRegistryChannel {
  artifactKind: ArtifactKind = ArtifactKind.CHECKPOINT;
  activeArtifactDigest: string = '';
  canaryArtifactDigest: string = '';
}

export class ArtifactRegistrySnapshot {
  schemaVersion: string = ARTIFACT_REGISTRY_SCHEMA_VERSION;
  revision: number = 0;
  entries: ArtifactRegistryEntry[] = [];
  channels: ArtifactRegistryChannel[] = [];
}

export class ArtifactRegistrySnapshotEnvelope {
  schemaVersion: string = ARTIFACT_REGISTRY_SCHEMA_VERSION;
  revision: number = 0;
  payloadJson: string = '';
  payloadDigest: string = '';
}

export interface ArtifactPackageVerifierPort {
  verify(packageDigest: string, manifest: ArtifactManifest): boolean;
}

export interface ArtifactRegistryDigestPort {
  digest(payloadJson: string): string;
}

export interface ArtifactRegistryPersistencePort {
  load(): ArtifactRegistrySnapshotEnvelope | undefined;
  compareAndSet(expectedRevision: number, next: ArtifactRegistrySnapshotEnvelope,
    nowMs: number): Promise<boolean>;
}

export function copyArtifactManifest(source: ArtifactManifest): ArtifactManifest {
  return ContractCodec.parseArtifactManifest(ContractCodec.stringify(source));
}

export function copyArtifactRuntimeEnvironment(source: ArtifactRuntimeEnvironment): ArtifactRuntimeEnvironment {
  const value: ArtifactRuntimeEnvironment = new ArtifactRuntimeEnvironment();
  value.runtimeVersion = source.runtimeVersion;
  value.apiVersion = source.apiVersion;
  value.supportedFeatureSchemaVersions = source.supportedFeatureSchemaVersions.slice();
  return value;
}

export function copyArtifactRegistryEntry(source: ArtifactRegistryEntry): ArtifactRegistryEntry {
  const value: ArtifactRegistryEntry = new ArtifactRegistryEntry();
  value.manifest = copyArtifactManifest(source.manifest);
  value.packageDigest = source.packageDigest;
  value.registeredAtMs = source.registeredAtMs;
  return value;
}

export function copyArtifactRegistryChannel(source: ArtifactRegistryChannel): ArtifactRegistryChannel {
  const value: ArtifactRegistryChannel = new ArtifactRegistryChannel();
  value.artifactKind = source.artifactKind;
  value.activeArtifactDigest = source.activeArtifactDigest;
  value.canaryArtifactDigest = source.canaryArtifactDigest;
  return value;
}

export function copyArtifactRegistrySnapshot(source: ArtifactRegistrySnapshot): ArtifactRegistrySnapshot {
  const value: ArtifactRegistrySnapshot = new ArtifactRegistrySnapshot();
  value.schemaVersion = source.schemaVersion;
  value.revision = source.revision;
  for (let i: number = 0; i < source.entries.length; i++) {
    value.entries.push(copyArtifactRegistryEntry(source.entries[i]));
  }
  for (let i: number = 0; i < source.channels.length; i++) {
    value.channels.push(copyArtifactRegistryChannel(source.channels[i]));
  }
  return value;
}
