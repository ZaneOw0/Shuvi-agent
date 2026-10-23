export const MEMORY_SCHEMA_VERSION: string = '1.0';

export enum MemoryKind {
  PREFERENCE = 'PREFERENCE',
  STRUCTURED = 'STRUCTURED',
  NOTE = 'NOTE'
}

export enum MemoryPrivacyClass {
  PRIVATE = 'PRIVATE',
  SENSITIVE = 'SENSITIVE',
  SHAREABLE = 'SHAREABLE'
}

export enum MemorySourceKind {
  USER_EXPLICIT = 'USER_EXPLICIT',
  STRUCTURED_IMPORT = 'STRUCTURED_IMPORT',
  DERIVED_SUMMARY = 'DERIVED_SUMMARY',
  RAW_PERSONAL_TRACE = 'RAW_PERSONAL_TRACE'
}

export enum MemoryWriteCode {
  CREATED = 'CREATED',
  UPDATED = 'UPDATED',
  UNCHANGED = 'UNCHANGED',
  DELETED = 'DELETED',
  NOT_FOUND = 'NOT_FOUND',
  INVALID_INPUT = 'INVALID_INPUT',
  VERSION_CONFLICT = 'VERSION_CONFLICT',
  OWNER_MISMATCH = 'OWNER_MISMATCH',
  POLICY_DENIED = 'POLICY_DENIED',
  CORRUPT_SNAPSHOT = 'CORRUPT_SNAPSHOT',
  UNSUPPORTED_SCHEMA = 'UNSUPPORTED_SCHEMA'
}

export class MemoryRecord {
  memoryId: string = '';
  ownerId: string = '';
  kind: MemoryKind = MemoryKind.NOTE;
  privacyClass: MemoryPrivacyClass = MemoryPrivacyClass.PRIVATE;
  sourceKind: MemorySourceKind = MemorySourceKind.USER_EXPLICIT;
  title: string = '';
  content: string = '';
  contentDigest: string = '';
  tags: string[] = [];
  version: number = 0;
  createdAtMs: number = 0;
  updatedAtMs: number = 0;
}

export class MemoryWriteResult {
  accepted: boolean = false;
  duplicate: boolean = false;
  code: MemoryWriteCode = MemoryWriteCode.INVALID_INPUT;
  record?: MemoryRecord;
  invalidatedChunks: number = 0;
  invalidatedArtifacts: number = 0;
}

export class MemoryChunk {
  chunkId: string = '';
  memoryId: string = '';
  ownerId: string = '';
  memoryVersion: number = 0;
  ordinal: number = 0;
  content: string = '';
  contentDigest: string = '';
  tags: string[] = [];
  privacyClass: MemoryPrivacyClass = MemoryPrivacyClass.PRIVATE;
  sourceKind: MemorySourceKind = MemorySourceKind.USER_EXPLICIT;
}

export class DerivedMemoryIndexEntry {
  entryId: string = '';
  memoryId: string = '';
  chunkId: string = '';
  ownerId: string = '';
  memoryVersion: number = 0;
  ordinal: number = 0;
  tokens: string[] = [];
  tags: string[] = [];
  privacyClass: MemoryPrivacyClass = MemoryPrivacyClass.PRIVATE;
  sourceKind: MemorySourceKind = MemorySourceKind.USER_EXPLICIT;
  sourceDigest: string = '';
}

export class DerivedMemoryArtifact {
  artifactId: string = '';
  memoryId: string = '';
  ownerId: string = '';
  memoryVersion: number = 0;
  artifactType: string = '';
  sourceDigest: string = '';
  payloadJson: string = '';
  createdAtMs: number = 0;
}

export class MemoryQuery {
  ownerId: string = '';
  terms: string[] = [];
  requiredTags: string[] = [];
  limit: number = 10;
  includeSensitive: boolean = false;
  includeRawPersonalTrace: boolean = false;
}

export class MemoryHit {
  memoryId: string = '';
  chunkId: string = '';
  memoryVersion: number = 0;
  score: number = 0;
  content: string = '';
  tags: string[] = [];
}

export class MemoryImportPolicy {
  ownerId: string = '';
  maxRecords: number = 100;
  allowSensitive: boolean = true;
  allowRawPersonalTrace: boolean = false;
}

export class MemoryImportResult {
  accepted: boolean = false;
  code: MemoryWriteCode = MemoryWriteCode.INVALID_INPUT;
  importedRecords: number = 0;
  duplicateRecords: number = 0;
}

export class MemoryExportPolicy {
  ownerId: string = '';
  includePrivate: boolean = false;
  includeSensitive: boolean = false;
  includeRawPersonalTrace: boolean = false;
  redactionVersion: string = '';
  secrets: string[] = [];
}

export class MemoryExportRecord {
  memoryId: string = '';
  kind: MemoryKind = MemoryKind.NOTE;
  privacyClass: MemoryPrivacyClass = MemoryPrivacyClass.PRIVATE;
  sourceKind: MemorySourceKind = MemorySourceKind.USER_EXPLICIT;
  title: string = '';
  content: string = '';
  tags: string[] = [];
  version: number = 0;
  redactionVersion: string = '';
}

export class MemoryDeleteResult {
  accepted: boolean = false;
  code: MemoryWriteCode = MemoryWriteCode.INVALID_INPUT;
  removedRecords: number = 0;
  removedChunks: number = 0;
  removedArtifacts: number = 0;
}

export class MemoryStoragePayload {
  records: MemoryRecord[] = [];
  artifacts: DerivedMemoryArtifact[] = [];
}

export class MemorySnapshotEnvelope {
  schemaVersion: string = MEMORY_SCHEMA_VERSION;
  revision: number = 0;
  payloadJson: string = '';
  payloadDigest: string = '';
}
