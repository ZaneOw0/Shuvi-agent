export const UNIFIED_TEXT_POLICY: string = 'UNIFIED-KNOWLEDGE-TEXT-1';
export const UNIFIED_QUERY_POLICY: string = 'UNIFIED-KNOWLEDGE-QUERY-1';
export const UNIFIED_HISTORY_WIRE: string = 'UNIFIED-KNOWLEDGE-HISTORY-1';
export enum UnifiedJobOrigin { Import = 'Import', LocalMigration = 'LocalMigration', ExplicitUpgrade = 'ExplicitUpgrade' }
export enum UnifiedJobState { AwaitingConfig = 'AwaitingConfig', Pending = 'Pending', Running = 'Running', Paused = 'Paused', Unknown = 'Unknown', Complete = 'Complete', Failed = 'Failed', Canceled = 'Canceled' }
export enum UnifiedInputKind { Body = 'Body', Ocr = 'Ocr', ImageProxy = 'ImageProxy' }
export enum UnifiedBindingState { Pending = 'Pending', Synced = 'Synced', Partial = 'Partial', Invalid = 'Invalid' }
export class UnifiedProcessingSettings {
  purpose: string = ''; enabled: boolean = false; paused: boolean = false; automatic: boolean = false;
  recipient: string = ''; model: string = ''; credentialRevision: number = 0; revision: number = 0;
  costAcknowledged: boolean = false; costRevision: number = 0; policy: string = ''; inputKinds: UnifiedInputKind[] = [];
  imageScope: string = '';
  configBinding: string = ''; baselineAccepted: boolean = false;
}
export class UnifiedProcessingGrant {
  id: string = ''; settingsPurpose: string = ''; settingsRevision: number = 0; costRevision: number = 0;
  credentialRevision: number = 0; inputSetHash: string = ''; batchId: string = ''; queryEpoch: number = 0;
  policy: string = ''; revoked: boolean = false; consumed: boolean = false;
}
export class UnifiedTextInput {
  id: string = ''; documentKey: string = ''; ownerNamespace: string = 'upd-body'; ownerId: string = '';
  version: string = ''; kind: UnifiedInputKind = UnifiedInputKind.Body; ordinal: number = 0;
  actualText: string = ''; inputHash: string = ''; blockId: string = ''; occurrenceId: string = ''; start: number = 0; end: number = 0;
  policy: string = UNIFIED_TEXT_POLICY;
}
export class UnifiedIndexBinding {
  ownerNamespace: string = ''; ownerId: string = ''; version: string = ''; epoch: number = 0;
  expected: number = 0; inputSetHash: string = ''; space: string = UNIFIED_TEXT_POLICY;
  vectorGeneration: string = ''; readbackHash: string = ''; state: UnifiedBindingState = UnifiedBindingState.Pending;
}
export class UnifiedProcessingBatch {
  id: string = ''; origin: UnifiedJobOrigin = UnifiedJobOrigin.LocalMigration; inputIds: string[] = []; inputSetHash: string = '';
  settingsRevision: number = 0; costRevision: number = 0; state: UnifiedJobState = UnifiedJobState.Pending;
}
export class UnifiedProcessingJob {
  id: string = ''; dedupKey: string = ''; documentKey: string = ''; ownerId: string = ''; version: string = ''; inputHash: string = '';
  origin: UnifiedJobOrigin = UnifiedJobOrigin.LocalMigration; batchId: string = ''; stage: string = '';
  settingsPurpose: string = ''; settingsRevision: number = 0; costRevision: number = 0; credentialRevision: number = 0;
  epoch: number = 0; expected: number = 0; completed: number = 0; checkpoint: string = ''; failure: string = '';
  state: UnifiedJobState = UnifiedJobState.AwaitingConfig;
  inputs: UnifiedTextInput[] = []; assetId: string = ''; occurrenceId: string = ''; annotationId: string = '';
  configBinding: string = '';
  resourcePhase: string = 'NotHeld';
}
export class UnifiedProcessingAttempt {
  id: string = ''; jobId: string = ''; inputHash: string = ''; settingsRevision: number = 0; costRevision: number = 0;
  launched: boolean = false; outcome: string = 'Prepared'; receipt: string = ''; usageState: string = 'NotReported';
}
export class UnifiedAnnotationAuto {
  id: string = ''; cacheKey: string = ''; imageHash: string = ''; description: string = ''; tags: string[] = [];
  recipient: string = ''; model: string = ''; promptVersion: string = ''; schemaVersion: string = ''; parametersVersion: string = ''; receipt: string = '';
}
export class UnifiedAnnotationOverlay {
  lineage: string = ''; revision: number = 0; description?: string; tags?: string[]; suppressedTags: string[] = []; deleted: boolean = false;
}
export class UnifiedEffectiveAnnotation {
  id: string = 'None'; lineage: string = ''; revision: number = 0; autoId: string = ''; imageHash: string = '';
  description: string = ''; tags: string[] = []; textHash: string = ''; overlay: UnifiedAnnotationOverlay = new UnifiedAnnotationOverlay();
  kind: string = 'Effective'; automatic: UnifiedAnnotationAuto = new UnifiedAnnotationAuto();
}
export class UnifiedImageRecord {
  occurrenceId: string = ''; documentKey: string = ''; generation: string = ''; assetId: string = ''; imageHash: string = '';
  lineage: string = ''; effectiveId: string = 'None'; ocr: string = ''; caption: string = ''; provenance: string = ''; title: string = '';
}
export class UnifiedVectorInputReceipt {
  id: string = ''; jobId: string = ''; input: UnifiedTextInput = new UnifiedTextInput(); state: string = 'Pending';
  vectorHash: string = ''; spaceId: string = ''; model: string = ''; dimension: number = 0;
}
export class UnifiedQueryReason {
  id: string = ''; kind: string = ''; text: string = ''; version: string = ''; start: number = 0; end: number = 0; distance?: number;
}
export class UnifiedQueryParent {
  documentKey: string = ''; generation: string = ''; occurrenceId: string = ''; title: string = ''; precision: string = 'Unknown';
}
export class UnifiedQueryCard {
  key: string = ''; kind: string = ''; imageHash: string = ''; effectiveAnnotationId: string = 'None';
  reasons: UnifiedQueryReason[] = []; parents: UnifiedQueryParent[] = []; current: boolean = true;
}
export class UnifiedQueryGroup {
  id: string = ''; busy: boolean = false; error: string = ''; cursor: string = ''; exhausted: boolean = false;
  pageRevision: number = 0; cards: UnifiedQueryCard[] = [];
}
export class UnifiedQueryState {
  session: string = ''; question: string = ''; epoch: number = 0; space: string = UNIFIED_TEXT_POLICY;
  direct: UnifiedQueryGroup = new UnifiedQueryGroup(); related: UnifiedQueryGroup = new UnifiedQueryGroup();
  semanticState: string = 'NotRequested'; unupgraded: number = 0;
}
export class UnifiedHistoryRevision {
  recordId: string = ''; eventId: string = ''; revision: number = 0; wire: string = UNIFIED_HISTORY_WIRE;
  snapshotAsset: string = ''; snapshotHash: string = ''; createdAt: number = 0;
}
