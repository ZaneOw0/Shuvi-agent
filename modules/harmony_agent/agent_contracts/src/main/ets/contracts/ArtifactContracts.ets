import { AGENT_CONTRACT_SCHEMA_VERSION, CONTRACT_TYPE_ARTIFACT_MANIFEST } from './Constants';
import { ContractId, Digest, IsoTimestamp, JsonText } from './Common';
import { ArtifactApprovalStatus, ArtifactKind, ArtifactLifecycleStatus } from './Enums';

export class ArtifactManifest {
  schemaVersion: string = AGENT_CONTRACT_SCHEMA_VERSION;
  contractType: string = CONTRACT_TYPE_ARTIFACT_MANIFEST;
  artifactId: ContractId = '';
  artifactKind: ArtifactKind = ArtifactKind.CHECKPOINT;
  algorithm: string = '';
  artifactVersion: string = '';
  sourceCommit: string = '';
  sourceLicense: string = '';
  trainingDataLineage: string[] = [];
  modelAndProviderSnapshotJson: JsonText = '{}';
  featureSchemaVersion: string = '';
  runtimeCompatibility: string[] = [];
  artifactDigest: Digest = '';
  // Compatibility alias for manifests produced before the generic artifact digest was introduced.
  checkpointDigest: Digest = '';
  paperReproductionResultsJson: JsonText = '{}';
  portParityResultsJson: JsonText = '{}';
  harmonyAgentBenchResultsJson: JsonText = '{}';
  lifecycleStatus: ArtifactLifecycleStatus = ArtifactLifecycleStatus.DISABLED;
  approvalStatus: ArtifactApprovalStatus = ArtifactApprovalStatus.UNREVIEWED;
  approvedBy: string = '';
  approvedAt?: IsoTimestamp;
  signedManifestDigest: Digest = '';
  signatureAlgorithm: string = '';
  signingKeyId: string = '';
  signatureBase64: string = '';
  signedAt?: IsoTimestamp;
  rollbackTargetDigest?: Digest;
}
