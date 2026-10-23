import {
  ArtifactKind,
  ArtifactLifecycleStatus,
  ArtifactManifest,
  ContractCodec,
  ContractValidator
} from '@harmony_agent/agent-contracts';
import {
  ARTIFACT_REGISTRY_SCHEMA_VERSION,
  ArtifactPackageVerifierPort,
  ArtifactRegistryChannel,
  ArtifactRegistryDigestPort,
  ArtifactRegistryEntry,
  ArtifactRegistryPersistencePort,
  ArtifactRegistrySnapshot,
  ArtifactRegistrySnapshotEnvelope,
  ArtifactRegistryWriteCode,
  ArtifactRegistryWriteResult,
  ArtifactRuntimeEnvironment,
  copyArtifactManifest,
  copyArtifactRegistryChannel,
  copyArtifactRegistryEntry,
  copyArtifactRegistrySnapshot,
  copyArtifactRuntimeEnvironment
} from './ArtifactRegistryTypes';
import { ArtifactRuntimeCompatibilityEvaluator } from './ArtifactRuntimeCompatibility';
import { ArtifactReleaseRegistryViewPort } from './ArtifactPolicyReleaseTypes';

export class ArtifactRegistryOpenResult {
  accepted: boolean = false;
  code: ArtifactRegistryWriteCode = ArtifactRegistryWriteCode.CORRUPT_SNAPSHOT;
  registry?: ArtifactRegistry;
}

function writeResult(accepted: boolean, duplicate: boolean,
  code: ArtifactRegistryWriteCode): ArtifactRegistryWriteResult {
  const result: ArtifactRegistryWriteResult = new ArtifactRegistryWriteResult();
  result.accepted = accepted;
  result.duplicate = duplicate;
  result.code = code;
  return result;
}

function validDigest(value: string): boolean {
  return /^sha256:[0-9a-f]{64}$/.test(value);
}

function validCount(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function isSignedRelease(status: ArtifactLifecycleStatus): boolean {
  return status === ArtifactLifecycleStatus.CANARY || status === ArtifactLifecycleStatus.ACTIVE ||
    status === ArtifactLifecycleStatus.ROLLED_BACK;
}

function validArtifactKind(kind: ArtifactKind): boolean {
  return kind === ArtifactKind.CHECKPOINT || kind === ArtifactKind.POLICY || kind === ArtifactKind.WORKFLOW;
}

function sameStrings(left: string[], right: string[]): boolean {
  if (left.length !== right.length) return false;
  for (let i: number = 0; i < left.length; i++) if (left[i] !== right[i]) return false;
  return true;
}

function sameArtifactIdentity(left: ArtifactManifest, right: ArtifactManifest): boolean {
  return left.artifactId === right.artifactId && left.artifactKind === right.artifactKind &&
    left.algorithm === right.algorithm && left.artifactVersion === right.artifactVersion &&
    left.sourceCommit === right.sourceCommit && left.sourceLicense === right.sourceLicense &&
    sameStrings(left.trainingDataLineage, right.trainingDataLineage) &&
    left.modelAndProviderSnapshotJson === right.modelAndProviderSnapshotJson &&
    left.featureSchemaVersion === right.featureSchemaVersion &&
    sameStrings(left.runtimeCompatibility, right.runtimeCompatibility) &&
    left.artifactDigest === right.artifactDigest && left.checkpointDigest === right.checkpointDigest &&
    left.paperReproductionResultsJson === right.paperReproductionResultsJson &&
    left.portParityResultsJson === right.portParityResultsJson &&
    left.harmonyAgentBenchResultsJson === right.harmonyAgentBenchResultsJson;
}

function stableSortEntries(values: ArtifactRegistryEntry[]): ArtifactRegistryEntry[] {
  const result: ArtifactRegistryEntry[] = values.slice();
  for (let i: number = 0; i < result.length; i++) {
    for (let j: number = i + 1; j < result.length; j++) {
      if (result[j].manifest.artifactId < result[i].manifest.artifactId) {
        const temporary: ArtifactRegistryEntry = result[i];
        result[i] = result[j];
        result[j] = temporary;
      }
    }
  }
  return result;
}

function stableSortChannels(values: ArtifactRegistryChannel[]): ArtifactRegistryChannel[] {
  const result: ArtifactRegistryChannel[] = values.slice();
  for (let i: number = 0; i < result.length; i++) {
    for (let j: number = i + 1; j < result.length; j++) {
      if (result[j].artifactKind < result[i].artifactKind) {
        const temporary: ArtifactRegistryChannel = result[i];
        result[i] = result[j];
        result[j] = temporary;
      }
    }
  }
  return result;
}

export class ArtifactRegistry implements ArtifactReleaseRegistryViewPort {
  private readonly environment: ArtifactRuntimeEnvironment;
  private readonly verifier: ArtifactPackageVerifierPort;
  private readonly persistence: ArtifactRegistryPersistencePort;
  private readonly digest: ArtifactRegistryDigestPort;
  private current: ArtifactRegistrySnapshot;

  private constructor(environment: ArtifactRuntimeEnvironment, verifier: ArtifactPackageVerifierPort,
    persistence: ArtifactRegistryPersistencePort, digest: ArtifactRegistryDigestPort,
    current: ArtifactRegistrySnapshot) {
    this.environment = copyArtifactRuntimeEnvironment(environment);
    this.verifier = verifier;
    this.persistence = persistence;
    this.digest = digest;
    this.current = current;
  }

  static async open(environment: ArtifactRuntimeEnvironment, verifier: ArtifactPackageVerifierPort,
    persistence: ArtifactRegistryPersistencePort,
    digest: ArtifactRegistryDigestPort): Promise<ArtifactRegistryOpenResult> {
    const result: ArtifactRegistryOpenResult = new ArtifactRegistryOpenResult();
    try {
      const source: ArtifactRegistrySnapshotEnvelope | undefined = persistence.load();
      if (source === undefined) {
        result.accepted = true;
        result.code = ArtifactRegistryWriteCode.CREATED;
        result.registry = new ArtifactRegistry(
          environment, verifier, persistence, digest, new ArtifactRegistrySnapshot());
        return result;
      }
      const restored: ArtifactRegistrySnapshot | undefined = ArtifactRegistry.restore(
        source, environment, verifier, digest);
      if (restored === undefined) return result;
      result.accepted = true;
      result.code = ArtifactRegistryWriteCode.UPDATED;
      result.registry = new ArtifactRegistry(environment, verifier, persistence, digest, restored);
      return result;
    } catch (error) {
      return result;
    }
  }

  revision(): number {
    return this.current.revision;
  }

  snapshot(): ArtifactRegistrySnapshot {
    return copyArtifactRegistrySnapshot(this.current);
  }

  get(artifactId: string): ArtifactRegistryEntry | undefined {
    const index: number = this.findById(this.current.entries, artifactId);
    return index < 0 ? undefined : copyArtifactRegistryEntry(this.current.entries[index]);
  }

  entries(): ArtifactRegistryEntry[] {
    const values: ArtifactRegistryEntry[] = [];
    for (let i: number = 0; i < this.current.entries.length; i++) {
      values.push(copyArtifactRegistryEntry(this.current.entries[i]));
    }
    return values;
  }

  shadowArtifacts(kind: ArtifactKind): ArtifactRegistryEntry[] {
    const values: ArtifactRegistryEntry[] = [];
    for (let i: number = 0; i < this.current.entries.length; i++) {
      if (this.current.entries[i].manifest.artifactKind === kind &&
        this.current.entries[i].manifest.lifecycleStatus === ArtifactLifecycleStatus.SHADOW) {
        values.push(copyArtifactRegistryEntry(this.current.entries[i]));
      }
    }
    return values;
  }

  activeArtifact(kind: ArtifactKind): ArtifactRegistryEntry | undefined {
    const channel: ArtifactRegistryChannel | undefined = this.channel(this.current.channels, kind);
    if (channel === undefined || channel.activeArtifactDigest.length === 0) return undefined;
    const index: number = this.findByDigest(this.current.entries, channel.activeArtifactDigest);
    return index < 0 ? undefined : copyArtifactRegistryEntry(this.current.entries[index]);
  }

  canaryArtifact(kind: ArtifactKind): ArtifactRegistryEntry | undefined {
    const channel: ArtifactRegistryChannel | undefined = this.channel(this.current.channels, kind);
    if (channel === undefined || channel.canaryArtifactDigest.length === 0) return undefined;
    const index: number = this.findByDigest(this.current.entries, channel.canaryArtifactDigest);
    return index < 0 ? undefined : copyArtifactRegistryEntry(this.current.entries[index]);
  }

  async publish(packageDigest: string, manifest: ArtifactManifest,
    nowMs: number): Promise<ArtifactRegistryWriteResult> {
    let admission: ArtifactRegistryWriteCode | undefined;
    try {
      admission = this.admissionFailure(packageDigest, manifest, nowMs);
    } catch (error) {
      return writeResult(false, false, ArtifactRegistryWriteCode.INVALID_MANIFEST);
    }
    if (admission !== undefined) return writeResult(false, false, admission);

    const index: number = this.findById(this.current.entries, manifest.artifactId);
    if (index < 0) {
      if (manifest.lifecycleStatus !== ArtifactLifecycleStatus.DISABLED &&
        manifest.lifecycleStatus !== ArtifactLifecycleStatus.SHADOW) {
        return writeResult(false, false, ArtifactRegistryWriteCode.INVALID_TRANSITION);
      }
      const digestIndex: number = this.findByDigest(this.current.entries, manifest.artifactDigest);
      if (digestIndex >= 0) return writeResult(false, false, ArtifactRegistryWriteCode.IDENTITY_CONFLICT);
    } else {
      const previous: ArtifactRegistryEntry = this.current.entries[index];
      if (!sameArtifactIdentity(previous.manifest, manifest)) {
        return writeResult(false, false, ArtifactRegistryWriteCode.IDENTITY_CONFLICT);
      }
      if (previous.packageDigest === packageDigest &&
        ContractCodec.stringify(previous.manifest) === ContractCodec.stringify(manifest)) {
        const duplicate: ArtifactRegistryWriteResult = writeResult(
          true, true, ArtifactRegistryWriteCode.UNCHANGED);
        this.attachChannelDigests(duplicate, manifest.artifactKind, this.current.channels);
        return duplicate;
      }
      if (previous.manifest.lifecycleStatus === manifest.lifecycleStatus ||
        !ContractValidator.validateArtifactLifecycleTransition(
          previous.manifest.lifecycleStatus, manifest.lifecycleStatus).valid) {
        return writeResult(false, false, ArtifactRegistryWriteCode.INVALID_TRANSITION);
      }
    }

    const next: ArtifactRegistrySnapshot = copyArtifactRegistrySnapshot(this.current);
    const nextChannels: ArtifactRegistryChannel[] = next.channels;
    let nextChannel: ArtifactRegistryChannel = this.ensureChannel(nextChannels, manifest.artifactKind);
    const transitionFailure: ArtifactRegistryWriteCode | undefined = this.applyChannelTransition(
      next, nextChannel, index < 0 ? undefined : this.current.entries[index], manifest);
    if (transitionFailure !== undefined) return writeResult(false, false, transitionFailure);

    const entry: ArtifactRegistryEntry = new ArtifactRegistryEntry();
    entry.manifest = copyArtifactManifest(manifest);
    entry.packageDigest = packageDigest;
    entry.registeredAtMs = nowMs;
    if (index < 0) next.entries.push(entry); else next.entries[index] = entry;
    next.entries = stableSortEntries(next.entries);
    next.channels = stableSortChannels(nextChannels);
    next.revision = this.current.revision + 1;
    let saved: boolean = false;
    try {
      const envelope: ArtifactRegistrySnapshotEnvelope = this.envelope(next);
      saved = await this.persistence.compareAndSet(this.current.revision, envelope, nowMs);
    } catch (error) {
      saved = false;
    }
    if (!saved) return writeResult(false, false, ArtifactRegistryWriteCode.PERSISTENCE_CONFLICT);
    this.current = next;
    const result: ArtifactRegistryWriteResult = writeResult(
      true, false, index < 0 ? ArtifactRegistryWriteCode.CREATED : ArtifactRegistryWriteCode.UPDATED);
    this.attachChannelDigests(result, manifest.artifactKind, this.current.channels);
    return result;
  }

  private admissionFailure(packageDigest: string, manifest: ArtifactManifest,
    nowMs: number): ArtifactRegistryWriteCode | undefined {
    if (!validCount(nowMs) || !validDigest(packageDigest) || !validDigest(manifest.artifactDigest) ||
      (manifest.signedManifestDigest.length > 0 && !validDigest(manifest.signedManifestDigest)) ||
      (manifest.rollbackTargetDigest !== undefined && !validDigest(manifest.rollbackTargetDigest)) ||
      !ContractValidator.validateArtifactManifest(manifest).valid) {
      return ArtifactRegistryWriteCode.INVALID_MANIFEST;
    }
    if (!isSignedRelease(manifest.lifecycleStatus)) return undefined;
    let verified: boolean = false;
    try {
      verified = this.verifier.verify(packageDigest, copyArtifactManifest(manifest));
    } catch (error) {
      return ArtifactRegistryWriteCode.VERIFICATION_FAILED;
    }
    if (!verified) {
      return ArtifactRegistryWriteCode.VERIFICATION_FAILED;
    }
    if (!ArtifactRuntimeCompatibilityEvaluator.evaluate(manifest, this.environment).compatible) {
      return ArtifactRegistryWriteCode.INCOMPATIBLE_RUNTIME;
    }
    return undefined;
  }

  private applyChannelTransition(snapshot: ArtifactRegistrySnapshot, channel: ArtifactRegistryChannel,
    previous: ArtifactRegistryEntry | undefined,
    manifest: ArtifactManifest): ArtifactRegistryWriteCode | undefined {
    const status: ArtifactLifecycleStatus = manifest.lifecycleStatus;
    if (status === ArtifactLifecycleStatus.CANARY) {
      if (channel.canaryArtifactDigest.length > 0 &&
        channel.canaryArtifactDigest !== manifest.artifactDigest) {
        return ArtifactRegistryWriteCode.CANARY_CONFLICT;
      }
      channel.canaryArtifactDigest = manifest.artifactDigest;
      return undefined;
    }
    if (status === ArtifactLifecycleStatus.ACTIVE) {
      if (previous === undefined || channel.canaryArtifactDigest !== manifest.artifactDigest) {
        return ArtifactRegistryWriteCode.INVALID_TRANSITION;
      }
      channel.activeArtifactDigest = manifest.artifactDigest;
      channel.canaryArtifactDigest = '';
      return undefined;
    }
    if (status === ArtifactLifecycleStatus.SHADOW || status === ArtifactLifecycleStatus.DISABLED) {
      if (previous !== undefined && previous.manifest.lifecycleStatus === ArtifactLifecycleStatus.CANARY &&
        channel.canaryArtifactDigest === manifest.artifactDigest) {
        channel.canaryArtifactDigest = '';
      }
      return undefined;
    }
    if (status === ArtifactLifecycleStatus.ROLLED_BACK) {
      const targetDigest: string | undefined = manifest.rollbackTargetDigest;
      if (previous === undefined || targetDigest === undefined) {
        return ArtifactRegistryWriteCode.INVALID_TRANSITION;
      }
      const targetIndex: number = this.findByDigest(snapshot.entries, targetDigest);
      if (targetIndex < 0 || snapshot.entries[targetIndex].manifest.artifactKind !== manifest.artifactKind ||
        snapshot.entries[targetIndex].manifest.lifecycleStatus !== ArtifactLifecycleStatus.ACTIVE) {
        return ArtifactRegistryWriteCode.ROLLBACK_TARGET_NOT_FOUND;
      }
      if (previous.manifest.lifecycleStatus === ArtifactLifecycleStatus.CANARY) {
        if (channel.canaryArtifactDigest !== manifest.artifactDigest ||
          channel.activeArtifactDigest !== targetDigest) {
          return ArtifactRegistryWriteCode.INVALID_TRANSITION;
        }
        channel.canaryArtifactDigest = '';
      } else if (previous.manifest.lifecycleStatus === ArtifactLifecycleStatus.ACTIVE) {
        if (channel.activeArtifactDigest !== manifest.artifactDigest) {
          return ArtifactRegistryWriteCode.INVALID_TRANSITION;
        }
        channel.activeArtifactDigest = targetDigest;
      }
      return undefined;
    }
    return ArtifactRegistryWriteCode.INVALID_TRANSITION;
  }

  private envelope(snapshot: ArtifactRegistrySnapshot): ArtifactRegistrySnapshotEnvelope {
    const value: ArtifactRegistrySnapshotEnvelope = new ArtifactRegistrySnapshotEnvelope();
    value.revision = snapshot.revision;
    value.payloadJson = JSON.stringify(snapshot);
    value.payloadDigest = this.digest.digest(value.payloadJson);
    return value;
  }

  private attachChannelDigests(result: ArtifactRegistryWriteResult, kind: ArtifactKind,
    channels: ArtifactRegistryChannel[]): void {
    const channel: ArtifactRegistryChannel | undefined = this.channel(channels, kind);
    if (channel === undefined) return;
    result.activeArtifactDigest = channel.activeArtifactDigest;
    result.canaryArtifactDigest = channel.canaryArtifactDigest;
  }

  private ensureChannel(channels: ArtifactRegistryChannel[], kind: ArtifactKind): ArtifactRegistryChannel {
    const existing: ArtifactRegistryChannel | undefined = this.channel(channels, kind);
    if (existing !== undefined) return existing;
    const value: ArtifactRegistryChannel = new ArtifactRegistryChannel();
    value.artifactKind = kind;
    channels.push(value);
    return value;
  }

  private channel(channels: ArtifactRegistryChannel[], kind: ArtifactKind): ArtifactRegistryChannel | undefined {
    for (let i: number = 0; i < channels.length; i++) {
      if (channels[i].artifactKind === kind) return channels[i];
    }
    return undefined;
  }

  private findById(entries: ArtifactRegistryEntry[], artifactId: string): number {
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].manifest.artifactId === artifactId) return i;
    }
    return -1;
  }

  private findByDigest(entries: ArtifactRegistryEntry[], digest: string): number {
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].manifest.artifactDigest === digest) return i;
    }
    return -1;
  }

  private static restore(source: ArtifactRegistrySnapshotEnvelope, environment: ArtifactRuntimeEnvironment,
    verifier: ArtifactPackageVerifierPort,
    digest: ArtifactRegistryDigestPort): ArtifactRegistrySnapshot | undefined {
    if (source.schemaVersion !== ARTIFACT_REGISTRY_SCHEMA_VERSION || !validCount(source.revision) ||
      source.revision === 0 ||
      source.payloadJson.length === 0 || source.payloadDigest.length === 0 ||
      digest.digest(source.payloadJson) !== source.payloadDigest) return undefined;
    let parsed: ArtifactRegistrySnapshot;
    try {
      parsed = JSON.parse(source.payloadJson) as ArtifactRegistrySnapshot;
    } catch (error) {
      return undefined;
    }
    if (parsed.schemaVersion !== ARTIFACT_REGISTRY_SCHEMA_VERSION || parsed.revision !== source.revision ||
      !Array.isArray(parsed.entries) || !Array.isArray(parsed.channels)) return undefined;
    const artifactIds: string[] = [];
    const artifactDigests: string[] = [];
    for (let i: number = 0; i < parsed.entries.length; i++) {
      const entry: ArtifactRegistryEntry = parsed.entries[i];
      if (entry.manifest === undefined || !validDigest(entry.packageDigest) || !validCount(entry.registeredAtMs) ||
        !validDigest(entry.manifest.artifactDigest) ||
        (entry.manifest.signedManifestDigest.length > 0 && !validDigest(entry.manifest.signedManifestDigest)) ||
        !ContractValidator.validateArtifactManifest(entry.manifest).valid ||
        ArtifactRegistry.includes(artifactIds, entry.manifest.artifactId) ||
        ArtifactRegistry.includes(artifactDigests, entry.manifest.artifactDigest)) return undefined;
      if (isSignedRelease(entry.manifest.lifecycleStatus) &&
        (!verifier.verify(entry.packageDigest, copyArtifactManifest(entry.manifest)) ||
          !ArtifactRuntimeCompatibilityEvaluator.evaluate(entry.manifest, environment).compatible)) return undefined;
      artifactIds.push(entry.manifest.artifactId);
      artifactDigests.push(entry.manifest.artifactDigest);
    }
    const kinds: string[] = [];
    for (let i: number = 0; i < parsed.channels.length; i++) {
      const channel: ArtifactRegistryChannel = parsed.channels[i];
      const kindText: string = channel.artifactKind as string;
      if (!validArtifactKind(channel.artifactKind) || ArtifactRegistry.includes(kinds, kindText)) return undefined;
      kinds.push(kindText);
      if (channel.activeArtifactDigest.length > 0) {
        const activeIndex: number = ArtifactRegistry.findDigest(parsed.entries, channel.activeArtifactDigest);
        if (activeIndex < 0 || parsed.entries[activeIndex].manifest.artifactKind !== channel.artifactKind ||
          parsed.entries[activeIndex].manifest.lifecycleStatus !== ArtifactLifecycleStatus.ACTIVE) return undefined;
      }
      if (channel.canaryArtifactDigest.length > 0) {
        const canaryIndex: number = ArtifactRegistry.findDigest(parsed.entries, channel.canaryArtifactDigest);
        if (canaryIndex < 0 || parsed.entries[canaryIndex].manifest.artifactKind !== channel.artifactKind ||
          parsed.entries[canaryIndex].manifest.lifecycleStatus !== ArtifactLifecycleStatus.CANARY) return undefined;
      }
    }
    for (let i: number = 0; i < parsed.entries.length; i++) {
      if (parsed.entries[i].manifest.lifecycleStatus === ArtifactLifecycleStatus.CANARY) {
        const channel: ArtifactRegistryChannel | undefined = ArtifactRegistry.findChannel(
          parsed.channels, parsed.entries[i].manifest.artifactKind);
        if (channel === undefined || channel.canaryArtifactDigest !== parsed.entries[i].manifest.artifactDigest) {
          return undefined;
        }
      }
    }
    const result: ArtifactRegistrySnapshot = new ArtifactRegistrySnapshot();
    result.schemaVersion = parsed.schemaVersion;
    result.revision = parsed.revision;
    for (let i: number = 0; i < parsed.entries.length; i++) {
      result.entries.push(copyArtifactRegistryEntry(parsed.entries[i]));
    }
    for (let i: number = 0; i < parsed.channels.length; i++) {
      result.channels.push(copyArtifactRegistryChannel(parsed.channels[i]));
    }
    result.entries = stableSortEntries(result.entries);
    result.channels = stableSortChannels(result.channels);
    return result;
  }

  private static includes(values: string[], expected: string): boolean {
    for (let i: number = 0; i < values.length; i++) if (values[i] === expected) return true;
    return false;
  }

  private static findDigest(entries: ArtifactRegistryEntry[], digest: string): number {
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].manifest.artifactDigest === digest) return i;
    }
    return -1;
  }

  private static findChannel(channels: ArtifactRegistryChannel[],
    kind: ArtifactKind): ArtifactRegistryChannel | undefined {
    for (let i: number = 0; i < channels.length; i++) {
      if (channels[i].artifactKind === kind) return channels[i];
    }
    return undefined;
  }
}
