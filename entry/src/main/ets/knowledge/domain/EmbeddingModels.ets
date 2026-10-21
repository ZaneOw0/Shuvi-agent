import { EmbeddingBaselineAcceptance } from './EmbeddingBasisModels';
export enum EmbeddingProvider { SiliconFlow = 'SiliconFlow', Bailian = 'Bailian', Gemini = 'Gemini', OpenAI = 'OpenAI' }
export enum EmbeddingRegion { Unselected = 'Unselected', Beijing = 'Beijing', Singapore = 'Singapore' }
export enum EmbeddingAccess { Public = 'Public', Workspace = 'Workspace' }
export enum EmbeddingModelSource { Manual = 'Manual', Remote = 'RemoteCurrentCredential' }
export enum EmbeddingCapability { VerifiedContract = 'VerifiedContract', ContractUnverified = 'ContractUnverified', ManualOnly = 'ManualOnly' }
export enum EmbeddingCredentialStatus { Missing = 'Missing', Configured = 'Configured', Unavailable = 'Unavailable' }
export enum EmbeddingPurpose { Models = 'ModelList', Probe = 'Probe', Corpus = 'PdfCorpus', Query = 'Query', ImageCorpus = 'ImageCorpus', DocxCorpus = 'DocxCorpus' }
export enum EmbeddingFreeEligibility { Unknown = 'Unknown', Confirmed = 'UserConfirmedForThisAction', Ineligible = 'Ineligible' }
export enum EmbeddingDetectionStatus { Untested = 'Untested', Running = 'Running', Passed = 'Passed', Failed = 'Failed', Stale = 'Stale' }
export enum EmbeddingJobStage {
  Off = 'Off', Config = 'AwaitingConfig', Detection = 'AwaitingDetection', Consent = 'AwaitingConsent',
  Input = 'InputLimitUnverified', Preparing = 'Preparing', Partial = 'PartialStaged', Readback = 'ValidatingReadback',
  Ready = 'SemanticReady', Paused = 'Paused', Failed = 'Failed', Rebuild = 'NeedsRebuild',
  Retained = 'Retained', Retiring = 'Retiring', Claimed = 'CleanupClaimed'
}
export class EmbeddingBudget {
  static readonly responseBytes: number = 2097152; static readonly dimension: number = 4096;
  static readonly models: number = 4096; static readonly modelBytes: number = 512;
  static readonly requestMs: number = 120000; static readonly windowMs: number = 900000;
  static readonly probe: string = '这是一条用于检测嵌入服务的非敏感短句。';
}
export class EmbeddingConfig {
  provider: EmbeddingProvider = EmbeddingProvider.SiliconFlow; region: EmbeddingRegion = EmbeddingRegion.Unselected;
  access: EmbeddingAccess = EmbeddingAccess.Public; workspaceId: string = ''; modelId: string = '';
  modelSource: EmbeddingModelSource = EmbeddingModelSource.Manual; revision: number = 0; credentialRevision: number = 0;
  mutationPending: boolean = false; contractVersion: string = 'EMBED-PROVIDERS-2026-10-16';
}
export class QueryConsentSnapshot {
  actual: string = ''; inputHash: string = ''; bindingHash: string = ''; role: string = 'query';
  purpose: string = ''; space: string = ''; trial: string = ''; scopeHash: string = ''; config: string = ''; epoch: number = 0;
  approved: boolean = false; free: boolean = false;
}
export class EmbeddingModelInfo {
  id: string = ''; source: EmbeddingModelSource = EmbeddingModelSource.Manual; configFingerprint: string = '';
  observedAt: number = 0; capability: EmbeddingCapability = EmbeddingCapability.ContractUnverified;
}
export class TokenEligibilityEvidence {
  verified: boolean = false; evidenceVersion: string = ''; modelId: string = ''; role: string = '';
  textHash: string = ''; upperBound: number = -1; contextLimit: number = -1; applicableScope: string = '';
  localState: string = 'NotCounted'; profileBoundProven: boolean = false; bindingHash: string = '';
  profileId: string = ''; profileRevision: string = ''; tokenizerSha256: string = ''; policyVersion: string = '';
  providerRevision: string = 'NotReported'; providerConsistency: string = 'UnverifiedRevisionAndHiddenProcessing';
  provenance: string = ''; baseline: EmbeddingBaselineAcceptance = new EmbeddingBaselineAcceptance();
}
export class EmbeddingProfile {
  id: string = ''; modelId: string = ''; contextLimit: number = -1; documentPolicy: string = 'PDF-EMBED-TEXT-1';
  queryPolicy: string = 'PDF-EMBED-TEXT-1'; rolePair: string = 'SingleStringNoInventedPrefix';
  normalization: string = 'PreserveFloat32'; metric: string = 'Cosine'; tokenEvidence: TokenEligibilityEvidence = new TokenEligibilityEvidence();
  limitation: string = 'InputLimitUnverified';
}
export class EmbeddingUsage { totalTokens: number | undefined = undefined; promptTokens: number | undefined = undefined; }
export class EmbeddingDetection {
  status: EmbeddingDetectionStatus = EmbeddingDetectionStatus.Untested; configFingerprint: string = '';
  credentialRevision: number = 0; probeHash: string = ''; requestedModel: string = ''; returnedModel: string = '';
  dimension: number = 0; elapsedMs: number = 0; observedAt: number = 0; usage: EmbeddingUsage = new EmbeddingUsage();
  failure: string = ''; providerRevision: string = 'NotReported';
}
export class EmbeddingGrant {
  id: string = ''; purpose: EmbeddingPurpose = EmbeddingPurpose.Probe; provider: EmbeddingProvider = EmbeddingProvider.SiliconFlow;
  configFingerprint: string = ''; credentialRevision: number = 0; documentId: string = ''; generation: string = '';
  snapshotHash: string = ''; inputHashes: string[] = []; spaceId: string = ''; sessionId: string = '';
  free: EmbeddingFreeEligibility = EmbeddingFreeEligibility.Unknown; issuedAt: number = 0; expiresAt: number = 0; revoked: boolean = false;
  inputEvidence: TokenEligibilityEvidence[] = [];
  queryApproval: QueryConsentSnapshot | undefined = undefined;
  trialId: string = ''; trialSetHash: string = ''; inputChunkIds: string[] = []; scopeChunkIds: string[] = []; scopeInputHashes: string[] = [];
}
export class EmbeddingVectorResponse {
  model: string = ''; index: number = -1; vector: Float32Array = new Float32Array(0); usage: EmbeddingUsage = new EmbeddingUsage();
}
export class EmbeddingSpace {
  id: string = ''; fingerprint: string = ''; configFingerprint: string = ''; provider: EmbeddingProvider = EmbeddingProvider.SiliconFlow;
  region: EmbeddingRegion = EmbeddingRegion.Unselected; access: EmbeddingAccess = EmbeddingAccess.Public; workspaceId: string = '';
  requestedModel: string = ''; returnedModel: string = ''; providerRevision: string = 'NotReported';
  dimension: number = 0; profileId: string = ''; preprocessing: string = 'PDF-EMBED-TEXT-1';
  rolePair: string = ''; normalization: string = 'PreserveFloat32'; metric: string = 'Cosine'; detectionFingerprint: string = '';
  profileRevision: string = ''; tokenizerSha256: string = ''; profileParameters: string = '';
  providerConsistency: string = 'UnverifiedRevisionAndHiddenProcessing';
}
export class EmbeddingJob {
  id: string = ''; documentId: string = ''; contentGeneration: string = ''; vectorGeneration: string = ''; spaceId: string = '';
  grantId: string = ''; configFingerprint: string = ''; epoch: number = 0; expectedHashes: string[] = [];
  completedHashes: string[] = []; windowStart: number = 0; stage: EmbeddingJobStage = EmbeddingJobStage.Off; failure: string = '';
  snapshotHash: string = ''; oldVectorGeneration: string = ''; sessionId: string = '';
}
export class KnowledgeVectorRow {
  chunkId: string = ''; documentId: string = ''; contentGeneration: string = ''; vectorGeneration: string = '';
  spaceId: string = ''; inputHash: string = ''; epoch: number = 0; eligible: boolean = false;
  values: Float32Array = new Float32Array(0);
}
export class KnowledgeVectorCandidate { row: KnowledgeVectorRow = new KnowledgeVectorRow(); distance: number = 0; }
export class EmbeddingViewState {
  config: EmbeddingConfig = new EmbeddingConfig(); models: EmbeddingModelInfo[] = [];
  credential: EmbeddingCredentialStatus = EmbeddingCredentialStatus.Missing; detection: EmbeddingDetection = new EmbeddingDetection();
  busy: boolean = false; message: string = ''; inputEpoch: number = 0;
  inputGate: string = 'InputLimitUnverified'; corpusEnabled: boolean = false; queryEnabled: boolean = false;
}
// New settings-level cost approval is not an EmbeddingFreeEligibility value.
export class UnifiedEmbeddingCostReceipt {
  policy: string = 'UNIFIED-KNOWLEDGE-TEXT-1'; settingsRevision: number = 0; costRevision: number = 0;
  configBinding: string = ''; inputHash: string = ''; attemptId: string = ''; possibleCost: boolean = true;
}
