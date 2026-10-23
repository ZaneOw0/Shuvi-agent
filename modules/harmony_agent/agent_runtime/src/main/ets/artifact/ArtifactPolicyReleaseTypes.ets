import { ArtifactKind } from '@harmony_agent/agent-contracts';
import {
  ArtifactRegistryEntry,
  copyArtifactRegistryEntry
} from './ArtifactRegistryTypes';

export const ARTIFACT_POLICY_RELEASE_VERSION: string = '1.0';

export enum ArtifactPolicyRunCode {
  SUCCESS = 'SUCCESS',
  INVALID_REQUEST = 'INVALID_REQUEST',
  BASELINE_FAILED = 'BASELINE_FAILED',
  BASELINE_TIMED_OUT = 'BASELINE_TIMED_OUT',
  CANCELLED = 'CANCELLED'
}

export enum ArtifactPolicyExecutionMode {
  BASELINE = 'BASELINE',
  CANARY = 'CANARY',
  ACTIVE = 'ACTIVE'
}

export enum ArtifactPolicyFallbackCode {
  NONE = 'NONE',
  NO_RELEASE = 'NO_RELEASE',
  REGISTRY_FAILED = 'REGISTRY_FAILED',
  CANARY_NOT_ASSIGNED = 'CANARY_NOT_ASSIGNED',
  CANARY_ASSIGNMENT_FAILED = 'CANARY_ASSIGNMENT_FAILED',
  CANARY_REJECTED = 'CANARY_REJECTED',
  CANARY_FAILED = 'CANARY_FAILED',
  CANARY_TIMED_OUT = 'CANARY_TIMED_OUT',
  ACTIVE_REJECTED = 'ACTIVE_REJECTED',
  ACTIVE_FAILED = 'ACTIVE_FAILED',
  ACTIVE_TIMED_OUT = 'ACTIVE_TIMED_OUT'
}

export enum ArtifactShadowObservationCode {
  ACCEPTED = 'ACCEPTED',
  REJECTED = 'REJECTED',
  FAILED = 'FAILED',
  TIMED_OUT = 'TIMED_OUT',
  CANCELLED = 'CANCELLED'
}

export class ArtifactPolicyReleaseConfig {
  canaryTrafficBasisPoints: number = 0;
  maxShadowEvaluations: number = 0;
  attemptTimeoutMs: number = 5000;
}

export class ArtifactPolicyRequest {
  version: string = ARTIFACT_POLICY_RELEASE_VERSION;
  requestId: string = '';
  artifactKind: ArtifactKind = ArtifactKind.POLICY;
  candidateIds: string[] = [];
  inputJson: string = '{}';
}

export class ArtifactPolicyDecision {
  selectedId: string = '';
  evidenceJson: string = '{}';
}

export class ArtifactShadowObservation {
  artifactId: string = '';
  artifactDigest: string = '';
  code: ArtifactShadowObservationCode = ArtifactShadowObservationCode.FAILED;
  selectedId: string = '';
}

export class ArtifactPolicyRunResult {
  accepted: boolean = false;
  code: ArtifactPolicyRunCode = ArtifactPolicyRunCode.INVALID_REQUEST;
  executionMode: ArtifactPolicyExecutionMode = ArtifactPolicyExecutionMode.BASELINE;
  fallbackCode: ArtifactPolicyFallbackCode = ArtifactPolicyFallbackCode.NONE;
  selectedArtifactDigest: string = '';
  decision?: ArtifactPolicyDecision;
  baselineDecision?: ArtifactPolicyDecision;
  shadowObservations: ArtifactShadowObservation[] = [];
}

export interface ArtifactBaselinePolicyPort {
  decide(request: ArtifactPolicyRequest,
    cancellation?: ArtifactPolicyCancellationSignalPort): Promise<ArtifactPolicyDecision>;
}

export interface ArtifactReleasedPolicyPort {
  decide(artifact: ArtifactRegistryEntry, request: ArtifactPolicyRequest,
    cancellation?: ArtifactPolicyCancellationSignalPort): Promise<ArtifactPolicyDecision>;
}

export interface ArtifactPolicyCancellationSubscriptionPort {
  dispose(): void;
}

export interface ArtifactPolicyCancellationSignalPort {
  isCancellationRequested(): boolean;
  subscribe(listener: () => void): ArtifactPolicyCancellationSubscriptionPort;
}

export interface ArtifactPolicyTimerHandlePort {
  cancel(): void;
}

export interface ArtifactPolicyTimerPort {
  schedule(delayMs: number, action: () => void): ArtifactPolicyTimerHandlePort;
}

export interface ArtifactCanaryAssignmentPort {
  assigned(requestId: string, artifactDigest: string, trafficBasisPoints: number): boolean;
}

export interface ArtifactCanaryBucketPort {
  bucket(requestId: string, artifactDigest: string): number;
}

export interface ArtifactReleaseRegistryViewPort {
  shadowArtifacts(kind: ArtifactKind): ArtifactRegistryEntry[];
  canaryArtifact(kind: ArtifactKind): ArtifactRegistryEntry | undefined;
  activeArtifact(kind: ArtifactKind): ArtifactRegistryEntry | undefined;
}

export function copyArtifactPolicyRequest(source: ArtifactPolicyRequest): ArtifactPolicyRequest {
  const value: ArtifactPolicyRequest = new ArtifactPolicyRequest();
  value.version = source.version;
  value.requestId = source.requestId;
  value.artifactKind = source.artifactKind;
  value.candidateIds = source.candidateIds.slice();
  value.inputJson = source.inputJson;
  return value;
}

export function copyArtifactPolicyDecision(source: ArtifactPolicyDecision): ArtifactPolicyDecision {
  const value: ArtifactPolicyDecision = new ArtifactPolicyDecision();
  value.selectedId = source.selectedId;
  value.evidenceJson = source.evidenceJson;
  return value;
}

export function copyArtifactShadowObservation(source: ArtifactShadowObservation): ArtifactShadowObservation {
  const value: ArtifactShadowObservation = new ArtifactShadowObservation();
  value.artifactId = source.artifactId;
  value.artifactDigest = source.artifactDigest;
  value.code = source.code;
  value.selectedId = source.selectedId;
  return value;
}

export function copyArtifactForRelease(source: ArtifactRegistryEntry): ArtifactRegistryEntry {
  return copyArtifactRegistryEntry(source);
}
