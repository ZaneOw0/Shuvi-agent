import {
  ArtifactRepository,
  MemoryDigestPort,
  MemoryRepository,
  MemorySnapshotIntegrityPort,
  MemorySnapshotMigrationPort,
  MemoryTransferPort,
  RebuildableMemoryIndexPort
} from './MemoryPorts';
import {
  DerivedMemoryArtifact,
  DerivedMemoryIndexEntry,
  MEMORY_SCHEMA_VERSION,
  MemoryChunk,
  MemoryDeleteResult,
  MemoryExportPolicy,
  MemoryExportRecord,
  MemoryHit,
  MemoryImportPolicy,
  MemoryImportResult,
  MemoryPrivacyClass,
  MemoryQuery,
  MemoryRecord,
  MemorySnapshotEnvelope,
  MemorySourceKind,
  MemoryStoragePayload,
  MemoryWriteCode,
  MemoryWriteResult
} from './MemoryTypes';

class InvalidationCounts {
  chunks: number = 0;
  artifacts: number = 0;
}

class IndexArtifactPayload {
  tokens: string[] = [];
  tags: string[] = [];
}

export class MemoryStoreRestoreResult {
  accepted: boolean = false;
  code: MemoryWriteCode = MemoryWriteCode.CORRUPT_SNAPSHOT;
  store?: DeterministicMemoryStore;
}

function copyStrings(source: string[]): string[] {
  const result: string[] = [];
  for (let index: number = 0; index < source.length; index++) {
    result.push(source[index]);
  }
  return result;
}

function copyRecord(source: MemoryRecord): MemoryRecord {
  const result: MemoryRecord = new MemoryRecord();
  result.memoryId = source.memoryId;
  result.ownerId = source.ownerId;
  result.kind = source.kind;
  result.privacyClass = source.privacyClass;
  result.sourceKind = source.sourceKind;
  result.title = source.title;
  result.content = source.content;
  result.contentDigest = source.contentDigest;
  result.tags = copyStrings(source.tags);
  result.version = source.version;
  result.createdAtMs = source.createdAtMs;
  result.updatedAtMs = source.updatedAtMs;
  return result;
}

function copyChunk(source: MemoryChunk): MemoryChunk {
  const result: MemoryChunk = new MemoryChunk();
  result.chunkId = source.chunkId;
  result.memoryId = source.memoryId;
  result.ownerId = source.ownerId;
  result.memoryVersion = source.memoryVersion;
  result.ordinal = source.ordinal;
  result.content = source.content;
  result.contentDigest = source.contentDigest;
  result.tags = copyStrings(source.tags);
  result.privacyClass = source.privacyClass;
  result.sourceKind = source.sourceKind;
  return result;
}

function copyIndexEntry(source: DerivedMemoryIndexEntry): DerivedMemoryIndexEntry {
  const result: DerivedMemoryIndexEntry = new DerivedMemoryIndexEntry();
  result.entryId = source.entryId;
  result.memoryId = source.memoryId;
  result.chunkId = source.chunkId;
  result.ownerId = source.ownerId;
  result.memoryVersion = source.memoryVersion;
  result.ordinal = source.ordinal;
  result.tokens = copyStrings(source.tokens);
  result.tags = copyStrings(source.tags);
  result.privacyClass = source.privacyClass;
  result.sourceKind = source.sourceKind;
  result.sourceDigest = source.sourceDigest;
  return result;
}

function copyArtifact(source: DerivedMemoryArtifact): DerivedMemoryArtifact {
  const result: DerivedMemoryArtifact = new DerivedMemoryArtifact();
  result.artifactId = source.artifactId;
  result.memoryId = source.memoryId;
  result.ownerId = source.ownerId;
  result.memoryVersion = source.memoryVersion;
  result.artifactType = source.artifactType;
  result.sourceDigest = source.sourceDigest;
  result.payloadJson = source.payloadJson;
  result.createdAtMs = source.createdAtMs;
  return result;
}

function copyHit(source: MemoryHit): MemoryHit {
  const result: MemoryHit = new MemoryHit();
  result.memoryId = source.memoryId;
  result.chunkId = source.chunkId;
  result.memoryVersion = source.memoryVersion;
  result.score = source.score;
  result.content = source.content;
  result.tags = copyStrings(source.tags);
  return result;
}

function sameStrings(left: string[], right: string[]): boolean {
  if (left.length !== right.length) return false;
  for (let index: number = 0; index < left.length; index++) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}

function sameRecord(left: MemoryRecord, right: MemoryRecord): boolean {
  return left.memoryId === right.memoryId && left.ownerId === right.ownerId && left.kind === right.kind &&
    left.privacyClass === right.privacyClass && left.sourceKind === right.sourceKind && left.title === right.title &&
    left.content === right.content && left.contentDigest === right.contentDigest && sameStrings(left.tags, right.tags) &&
    left.version === right.version && left.createdAtMs === right.createdAtMs && left.updatedAtMs === right.updatedAtMs;
}

function sameArtifact(left: DerivedMemoryArtifact, right: DerivedMemoryArtifact): boolean {
  return left.artifactId === right.artifactId && left.memoryId === right.memoryId && left.ownerId === right.ownerId &&
    left.memoryVersion === right.memoryVersion && left.artifactType === right.artifactType &&
    left.sourceDigest === right.sourceDigest && left.payloadJson === right.payloadJson &&
    left.createdAtMs === right.createdAtMs;
}

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function validCount(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function validPositiveCount(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function hasText(values: string[], value: string): boolean {
  for (let index: number = 0; index < values.length; index++) {
    if (values[index] === value) return true;
  }
  return false;
}

function normalizeToken(value: string): string {
  let result: string = value.toLowerCase().trim();
  const punctuation: string[] = [',', '.', ';', ':', '!', '?', '(', ')', '[', ']', '{', '}', '"', '\'', '\n', '\r', '\t', '-', '_', '/'];
  for (let index: number = 0; index < punctuation.length; index++) {
    result = result.split(punctuation[index]).join(' ');
  }
  return result.trim();
}

function tokenize(value: string): string[] {
  const cleaned: string = normalizeToken(value);
  if (cleaned.length === 0) return [];
  const parts: string[] = cleaned.split(' ');
  const result: string[] = [];
  for (let index: number = 0; index < parts.length; index++) {
    const token: string = parts[index].trim();
    if (token.length > 0 && !hasText(result, token)) result.push(token);
  }
  return result;
}

function tagsValid(tags: string[]): boolean {
  const normalized: string[] = [];
  for (let index: number = 0; index < tags.length; index++) {
    if (!validText(tags[index])) return false;
    const tag: string = tags[index].toLowerCase().trim();
    if (hasText(normalized, tag)) return false;
    normalized.push(tag);
  }
  return true;
}

function hasTag(tags: string[], requested: string): boolean {
  const target: string = requested.toLowerCase().trim();
  for (let index: number = 0; index < tags.length; index++) {
    if (tags[index].toLowerCase().trim() === target) return true;
  }
  return false;
}

function resultWith(code: MemoryWriteCode, accepted: boolean = false): MemoryWriteResult {
  const result: MemoryWriteResult = new MemoryWriteResult();
  result.code = code;
  result.accepted = accepted;
  return result;
}

export class DeterministicMemoryStore implements MemoryRepository, ArtifactRepository,
  RebuildableMemoryIndexPort, MemoryTransferPort {
  private readonly digestPort: MemoryDigestPort;
  private readonly maxChunkChars: number;
  private records: MemoryRecord[] = [];
  private chunks: MemoryChunk[] = [];
  private indexEntries: DerivedMemoryIndexEntry[] = [];
  private artifacts: DerivedMemoryArtifact[] = [];

  constructor(digestPort: MemoryDigestPort, maxChunkChars: number = 512) {
    if (!validPositiveCount(maxChunkChars)) throw new Error('maxChunkChars must be a positive integer');
    this.digestPort = digestPort;
    this.maxChunkChars = maxChunkChars;
  }

  saveMemory(record: MemoryRecord, expectedPreviousVersion: number): MemoryWriteResult {
    if (!this.recordValid(record) || !validCount(expectedPreviousVersion)) {
      return resultWith(MemoryWriteCode.INVALID_INPUT);
    }
    const recordIndex: number = this.findRecord(record.ownerId, record.memoryId);
    if (recordIndex < 0) {
      if (this.findRecordForAnotherOwner(record.ownerId, record.memoryId) >= 0) {
        return resultWith(MemoryWriteCode.OWNER_MISMATCH);
      }
      if (expectedPreviousVersion !== 0 || record.version !== 1) {
        return resultWith(MemoryWriteCode.VERSION_CONFLICT);
      }
      this.records.push(copyRecord(record));
      const created: MemoryWriteResult = resultWith(MemoryWriteCode.CREATED, true);
      created.record = copyRecord(record);
      return created;
    }

    const current: MemoryRecord = this.records[recordIndex];
    if (sameRecord(current, record)) {
      const unchanged: MemoryWriteResult = resultWith(MemoryWriteCode.UNCHANGED, true);
      unchanged.duplicate = true;
      unchanged.record = copyRecord(current);
      return unchanged;
    }
    if (expectedPreviousVersion !== current.version || record.version !== current.version + 1 ||
      record.createdAtMs !== current.createdAtMs || record.updatedAtMs < current.updatedAtMs) {
      return resultWith(MemoryWriteCode.VERSION_CONFLICT);
    }

    const invalidated: InvalidationCounts = this.removeDerived(record.ownerId, record.memoryId);
    this.records[recordIndex] = copyRecord(record);
    const updated: MemoryWriteResult = resultWith(MemoryWriteCode.UPDATED, true);
    updated.record = copyRecord(record);
    updated.invalidatedChunks = invalidated.chunks;
    updated.invalidatedArtifacts = invalidated.artifacts;
    return updated;
  }

  getMemory(ownerId: string, memoryId: string): MemoryRecord | undefined {
    const index: number = this.findRecord(ownerId, memoryId);
    return index < 0 ? undefined : copyRecord(this.records[index]);
  }

  listMemories(ownerId: string): MemoryRecord[] {
    const result: MemoryRecord[] = [];
    for (let index: number = 0; index < this.records.length; index++) {
      if (this.records[index].ownerId === ownerId) result.push(copyRecord(this.records[index]));
    }
    this.sortRecords(result);
    return result;
  }

  deleteMemory(ownerId: string, memoryId: string): MemoryDeleteResult {
    const result: MemoryDeleteResult = new MemoryDeleteResult();
    if (!validText(ownerId) || !validText(memoryId)) {
      result.code = MemoryWriteCode.INVALID_INPUT;
      return result;
    }
    const recordIndex: number = this.findRecord(ownerId, memoryId);
    if (recordIndex < 0) {
      result.code = this.findRecordForAnotherOwner(ownerId, memoryId) >= 0 ?
        MemoryWriteCode.OWNER_MISMATCH : MemoryWriteCode.NOT_FOUND;
      return result;
    }
    const invalidated: InvalidationCounts = this.removeDerived(ownerId, memoryId);
    this.records.splice(recordIndex, 1);
    result.accepted = true;
    result.code = MemoryWriteCode.DELETED;
    result.removedRecords = 1;
    result.removedChunks = invalidated.chunks;
    result.removedArtifacts = invalidated.artifacts;
    return result;
  }

  saveArtifact(artifact: DerivedMemoryArtifact): MemoryWriteResult {
    if (!this.artifactValid(artifact)) return resultWith(MemoryWriteCode.INVALID_INPUT);
    const recordIndex: number = this.findRecord(artifact.ownerId, artifact.memoryId);
    if (recordIndex < 0) {
      return resultWith(this.findRecordForAnotherOwner(artifact.ownerId, artifact.memoryId) >= 0 ?
        MemoryWriteCode.OWNER_MISMATCH : MemoryWriteCode.NOT_FOUND);
    }
    if (this.records[recordIndex].version !== artifact.memoryVersion) {
      return resultWith(MemoryWriteCode.VERSION_CONFLICT);
    }
    const artifactIndex: number = this.findArtifact(artifact.ownerId, artifact.artifactId);
    if (artifactIndex >= 0) {
      if (sameArtifact(this.artifacts[artifactIndex], artifact)) {
        const unchanged: MemoryWriteResult = resultWith(MemoryWriteCode.UNCHANGED, true);
        unchanged.duplicate = true;
        return unchanged;
      }
      return resultWith(MemoryWriteCode.VERSION_CONFLICT);
    }
    this.artifacts.push(copyArtifact(artifact));
    return resultWith(MemoryWriteCode.CREATED, true);
  }

  listArtifacts(ownerId: string, memoryId: string): DerivedMemoryArtifact[] {
    const result: DerivedMemoryArtifact[] = [];
    for (let index: number = 0; index < this.artifacts.length; index++) {
      const artifact: DerivedMemoryArtifact = this.artifacts[index];
      if (artifact.ownerId === ownerId && artifact.memoryId === memoryId) result.push(copyArtifact(artifact));
    }
    this.sortArtifacts(result);
    return result;
  }

  rebuildIndex(ownerId: string): number {
    if (!validText(ownerId)) return 0;
    this.removeIndexForOwner(ownerId);
    const ownerRecords: MemoryRecord[] = this.listMemories(ownerId);
    for (let recordIndex: number = 0; recordIndex < ownerRecords.length; recordIndex++) {
      const record: MemoryRecord = ownerRecords[recordIndex];
      const recordChunks: MemoryChunk[] = this.buildChunks(record);
      for (let chunkIndex: number = 0; chunkIndex < recordChunks.length; chunkIndex++) {
        const chunk: MemoryChunk = recordChunks[chunkIndex];
        this.chunks.push(copyChunk(chunk));
        const entry: DerivedMemoryIndexEntry = this.buildIndexEntry(record, chunk);
        this.indexEntries.push(copyIndexEntry(entry));
        this.artifacts.push(this.indexArtifact(entry, record.updatedAtMs));
      }
    }
    return this.countIndexEntries(ownerId);
  }

  searchMemory(query: MemoryQuery): MemoryHit[] {
    if (!this.queryValid(query)) return [];
    const normalizedTerms: string[] = [];
    for (let termIndex: number = 0; termIndex < query.terms.length; termIndex++) {
      const termTokens: string[] = tokenize(query.terms[termIndex]);
      for (let tokenIndex: number = 0; tokenIndex < termTokens.length; tokenIndex++) {
        if (!hasText(normalizedTerms, termTokens[tokenIndex])) normalizedTerms.push(termTokens[tokenIndex]);
      }
    }
    const hits: MemoryHit[] = [];
    for (let index: number = 0; index < this.indexEntries.length; index++) {
      const entry: DerivedMemoryIndexEntry = this.indexEntries[index];
      if (entry.ownerId !== query.ownerId ||
        (entry.privacyClass === MemoryPrivacyClass.SENSITIVE && !query.includeSensitive) ||
        (entry.sourceKind === MemorySourceKind.RAW_PERSONAL_TRACE && !query.includeRawPersonalTrace) ||
        !this.requiredTagsMatch(entry.tags, query.requiredTags)) continue;

      let score: number = query.requiredTags.length * 5;
      let matchedTerms: number = 0;
      for (let termIndex: number = 0; termIndex < normalizedTerms.length; termIndex++) {
        if (hasText(entry.tokens, normalizedTerms[termIndex])) {
          score += 10;
          matchedTerms++;
        }
        if (hasTag(entry.tags, normalizedTerms[termIndex])) score += 3;
      }
      if (normalizedTerms.length > 0 && matchedTerms === 0 && score === query.requiredTags.length * 5) continue;
      const chunkIndex: number = this.findChunk(entry.ownerId, entry.chunkId);
      if (chunkIndex < 0) continue;
      const hit: MemoryHit = new MemoryHit();
      hit.memoryId = entry.memoryId;
      hit.chunkId = entry.chunkId;
      hit.memoryVersion = entry.memoryVersion;
      hit.score = score;
      hit.content = this.chunks[chunkIndex].content;
      hit.tags = copyStrings(entry.tags);
      this.insertHit(hits, hit);
    }
    const result: MemoryHit[] = [];
    const count: number = hits.length < query.limit ? hits.length : query.limit;
    for (let index: number = 0; index < count; index++) result.push(copyHit(hits[index]));
    return result;
  }

  invalidateMemory(ownerId: string, memoryId: string): number {
    const result: InvalidationCounts = this.removeDerived(ownerId, memoryId);
    return result.chunks + result.artifacts;
  }

  importMemories(records: MemoryRecord[], policy: MemoryImportPolicy): MemoryImportResult {
    const rejected: MemoryImportResult = new MemoryImportResult();
    if (!validText(policy.ownerId) || !validPositiveCount(policy.maxRecords) || records.length > policy.maxRecords) {
      rejected.code = MemoryWriteCode.INVALID_INPUT;
      return rejected;
    }
    const seenIds: string[] = [];
    for (let index: number = 0; index < records.length; index++) {
      const record: MemoryRecord = records[index];
      if (record.ownerId !== policy.ownerId) {
        rejected.code = MemoryWriteCode.OWNER_MISMATCH;
        return rejected;
      }
      if (hasText(seenIds, record.memoryId) || !this.recordValid(record)) {
        rejected.code = MemoryWriteCode.INVALID_INPUT;
        return rejected;
      }
      seenIds.push(record.memoryId);
      if ((!policy.allowSensitive && record.privacyClass === MemoryPrivacyClass.SENSITIVE) ||
        (!policy.allowRawPersonalTrace && record.sourceKind === MemorySourceKind.RAW_PERSONAL_TRACE)) {
        rejected.code = MemoryWriteCode.POLICY_DENIED;
        return rejected;
      }
    }

    const candidate: DeterministicMemoryStore = this.forkForTransaction();
    let duplicates: number = 0;
    for (let index: number = 0; index < records.length; index++) {
      const current: MemoryRecord | undefined = candidate.getMemory(policy.ownerId, records[index].memoryId);
      const expectedVersion: number = current === undefined ? 0 : current.version;
      const write: MemoryWriteResult = candidate.saveMemory(records[index], expectedVersion);
      if (!write.accepted) {
        rejected.code = write.code;
        return rejected;
      }
      if (write.duplicate) duplicates++;
    }
    this.records = candidate.records;
    this.chunks = candidate.chunks;
    this.indexEntries = candidate.indexEntries;
    this.artifacts = candidate.artifacts;
    const accepted: MemoryImportResult = new MemoryImportResult();
    accepted.accepted = true;
    accepted.code = duplicates === records.length ? MemoryWriteCode.UNCHANGED : MemoryWriteCode.UPDATED;
    accepted.importedRecords = records.length - duplicates;
    accepted.duplicateRecords = duplicates;
    return accepted;
  }

  exportMemories(policy: MemoryExportPolicy): MemoryExportRecord[] {
    if (!validText(policy.ownerId) || !validText(policy.redactionVersion)) return [];
    const result: MemoryExportRecord[] = [];
    const records: MemoryRecord[] = this.listMemories(policy.ownerId);
    for (let index: number = 0; index < records.length; index++) {
      const record: MemoryRecord = records[index];
      if ((record.privacyClass === MemoryPrivacyClass.PRIVATE && !policy.includePrivate) ||
        (record.privacyClass === MemoryPrivacyClass.SENSITIVE && !policy.includeSensitive) ||
        (record.sourceKind === MemorySourceKind.RAW_PERSONAL_TRACE && !policy.includeRawPersonalTrace)) continue;
      const exported: MemoryExportRecord = new MemoryExportRecord();
      exported.memoryId = record.memoryId;
      exported.kind = record.kind;
      exported.privacyClass = record.privacyClass;
      exported.sourceKind = record.sourceKind;
      exported.title = this.redact(record.title, policy.secrets);
      exported.content = this.redact(record.content, policy.secrets);
      exported.tags = this.redactStrings(record.tags, policy.secrets);
      exported.version = record.version;
      exported.redactionVersion = policy.redactionVersion;
      result.push(exported);
    }
    return result;
  }

  listChunks(ownerId: string, memoryId: string): MemoryChunk[] {
    const result: MemoryChunk[] = [];
    for (let index: number = 0; index < this.chunks.length; index++) {
      const chunk: MemoryChunk = this.chunks[index];
      if (chunk.ownerId === ownerId && chunk.memoryId === memoryId) result.push(copyChunk(chunk));
    }
    this.sortChunks(result);
    return result;
  }

  rebuildAllIndexes(): number {
    const owners: string[] = [];
    for (let index: number = 0; index < this.records.length; index++) {
      if (!hasText(owners, this.records[index].ownerId)) owners.push(this.records[index].ownerId);
    }
    let rebuilt: number = 0;
    for (let index: number = 0; index < owners.length; index++) rebuilt += this.rebuildIndex(owners[index]);
    return rebuilt;
  }

  checkpoint(integrity: MemorySnapshotIntegrityPort, revision: number): MemorySnapshotEnvelope {
    if (!validPositiveCount(revision)) throw new Error('revision must be a positive integer');
    const payload: MemoryStoragePayload = new MemoryStoragePayload();
    for (let index: number = 0; index < this.records.length; index++) payload.records.push(copyRecord(this.records[index]));
    this.sortSnapshotRecords(payload.records);
    for (let index: number = 0; index < this.artifacts.length; index++) {
      if (this.artifacts[index].artifactType !== 'LEXICAL_INDEX') {
        payload.artifacts.push(copyArtifact(this.artifacts[index]));
      }
    }
    this.sortSnapshotArtifacts(payload.artifacts);
    const result: MemorySnapshotEnvelope = new MemorySnapshotEnvelope();
    result.revision = revision;
    result.payloadJson = JSON.stringify(payload);
    result.payloadDigest = integrity.digest(result.payloadJson);
    return result;
  }

  static restore(source: MemorySnapshotEnvelope, digestPort: MemoryDigestPort,
    integrity: MemorySnapshotIntegrityPort, maxChunkChars: number = 512,
    migration?: MemorySnapshotMigrationPort): MemoryStoreRestoreResult {
    const result: MemoryStoreRestoreResult = new MemoryStoreRestoreResult();
    let envelope: MemorySnapshotEnvelope = source;
    if (envelope.schemaVersion !== MEMORY_SCHEMA_VERSION) {
      if (migration === undefined) {
        result.code = MemoryWriteCode.UNSUPPORTED_SCHEMA;
        return result;
      }
      envelope = migration.migrate(source);
    }
    if (envelope.schemaVersion !== MEMORY_SCHEMA_VERSION || !validPositiveCount(envelope.revision) ||
      !validText(envelope.payloadJson) || !validText(envelope.payloadDigest) ||
      integrity.digest(envelope.payloadJson) !== envelope.payloadDigest) {
      result.code = MemoryWriteCode.CORRUPT_SNAPSHOT;
      return result;
    }
    try {
      const payload: MemoryStoragePayload = JSON.parse(envelope.payloadJson) as MemoryStoragePayload;
      if (!Array.isArray(payload.records) || !Array.isArray(payload.artifacts)) {
        result.code = MemoryWriteCode.CORRUPT_SNAPSHOT;
        return result;
      }
      const store: DeterministicMemoryStore = new DeterministicMemoryStore(digestPort, maxChunkChars);
      for (let index: number = 0; index < payload.records.length; index++) {
        const record: MemoryRecord = payload.records[index];
        if (!store.recordValid(record) || store.findRecord(record.ownerId, record.memoryId) >= 0 ||
          store.findRecordForAnotherOwner(record.ownerId, record.memoryId) >= 0) {
          result.code = MemoryWriteCode.CORRUPT_SNAPSHOT;
          return result;
        }
        store.records.push(copyRecord(record));
      }
      for (let index: number = 0; index < payload.artifacts.length; index++) {
        const artifact: DerivedMemoryArtifact = payload.artifacts[index];
        const recordIndex: number = store.findRecord(artifact.ownerId, artifact.memoryId);
        if (!store.artifactValid(artifact) || artifact.artifactType === 'LEXICAL_INDEX' || recordIndex < 0 ||
          store.records[recordIndex].version !== artifact.memoryVersion ||
          store.findArtifact(artifact.ownerId, artifact.artifactId) >= 0) {
          result.code = MemoryWriteCode.CORRUPT_SNAPSHOT;
          return result;
        }
        store.artifacts.push(copyArtifact(artifact));
      }
      result.accepted = true;
      result.code = MemoryWriteCode.UPDATED;
      result.store = store;
      return result;
    } catch (error) {
      result.code = MemoryWriteCode.CORRUPT_SNAPSHOT;
      return result;
    }
  }

  forkForTransaction(): DeterministicMemoryStore {
    const result: DeterministicMemoryStore = new DeterministicMemoryStore(this.digestPort, this.maxChunkChars);
    for (let index: number = 0; index < this.records.length; index++) result.records.push(copyRecord(this.records[index]));
    for (let index: number = 0; index < this.chunks.length; index++) result.chunks.push(copyChunk(this.chunks[index]));
    for (let index: number = 0; index < this.indexEntries.length; index++) {
      result.indexEntries.push(copyIndexEntry(this.indexEntries[index]));
    }
    for (let index: number = 0; index < this.artifacts.length; index++) {
      result.artifacts.push(copyArtifact(this.artifacts[index]));
    }
    return result;
  }

  private recordValid(record: MemoryRecord): boolean {
    return validText(record.memoryId) && validText(record.ownerId) && validText(record.content) &&
      validText(record.contentDigest) && record.contentDigest === this.digestPort.digest(record.content) &&
      validPositiveCount(record.version) && validCount(record.createdAtMs) && validCount(record.updatedAtMs) &&
      record.updatedAtMs >= record.createdAtMs && tagsValid(record.tags);
  }

  private artifactValid(artifact: DerivedMemoryArtifact): boolean {
    return validText(artifact.artifactId) && validText(artifact.memoryId) && validText(artifact.ownerId) &&
      validPositiveCount(artifact.memoryVersion) && validText(artifact.artifactType) &&
      validText(artifact.sourceDigest) && validText(artifact.payloadJson) && validCount(artifact.createdAtMs);
  }

  private queryValid(query: MemoryQuery): boolean {
    if (!validText(query.ownerId) || !validPositiveCount(query.limit) || query.limit > 100 ||
      !tagsValid(query.requiredTags)) return false;
    for (let index: number = 0; index < query.terms.length; index++) {
      if (!validText(query.terms[index])) return false;
    }
    return true;
  }

  private buildChunks(record: MemoryRecord): MemoryChunk[] {
    const result: MemoryChunk[] = [];
    let ordinal: number = 0;
    for (let offset: number = 0; offset < record.content.length; offset += this.maxChunkChars) {
      const end: number = offset + this.maxChunkChars < record.content.length ?
        offset + this.maxChunkChars : record.content.length;
      const chunk: MemoryChunk = new MemoryChunk();
      chunk.chunkId = record.memoryId + ':v' + record.version + ':c' + ordinal;
      chunk.memoryId = record.memoryId;
      chunk.ownerId = record.ownerId;
      chunk.memoryVersion = record.version;
      chunk.ordinal = ordinal;
      chunk.content = record.content.substring(offset, end);
      chunk.contentDigest = this.digestPort.digest(chunk.content);
      chunk.tags = copyStrings(record.tags);
      chunk.privacyClass = record.privacyClass;
      chunk.sourceKind = record.sourceKind;
      result.push(chunk);
      ordinal++;
    }
    return result;
  }

  private buildIndexEntry(record: MemoryRecord, chunk: MemoryChunk): DerivedMemoryIndexEntry {
    const entry: DerivedMemoryIndexEntry = new DerivedMemoryIndexEntry();
    entry.entryId = 'lexical:' + chunk.chunkId;
    entry.memoryId = record.memoryId;
    entry.chunkId = chunk.chunkId;
    entry.ownerId = record.ownerId;
    entry.memoryVersion = record.version;
    entry.ordinal = chunk.ordinal;
    entry.tokens = tokenize(record.title + ' ' + chunk.content + ' ' + record.tags.join(' '));
    entry.tags = copyStrings(record.tags);
    entry.privacyClass = record.privacyClass;
    entry.sourceKind = record.sourceKind;
    entry.sourceDigest = chunk.contentDigest;
    return entry;
  }

  private indexArtifact(entry: DerivedMemoryIndexEntry, createdAtMs: number): DerivedMemoryArtifact {
    const payload: IndexArtifactPayload = new IndexArtifactPayload();
    payload.tokens = copyStrings(entry.tokens);
    payload.tags = copyStrings(entry.tags);
    const artifact: DerivedMemoryArtifact = new DerivedMemoryArtifact();
    artifact.artifactId = entry.entryId;
    artifact.memoryId = entry.memoryId;
    artifact.ownerId = entry.ownerId;
    artifact.memoryVersion = entry.memoryVersion;
    artifact.artifactType = 'LEXICAL_INDEX';
    artifact.sourceDigest = entry.sourceDigest;
    artifact.payloadJson = JSON.stringify(payload);
    artifact.createdAtMs = createdAtMs;
    return artifact;
  }

  private removeDerived(ownerId: string, memoryId: string): InvalidationCounts {
    const result: InvalidationCounts = new InvalidationCounts();
    for (let index: number = this.chunks.length - 1; index >= 0; index--) {
      if (this.chunks[index].ownerId === ownerId && this.chunks[index].memoryId === memoryId) {
        this.chunks.splice(index, 1);
        result.chunks++;
      }
    }
    for (let index: number = this.indexEntries.length - 1; index >= 0; index--) {
      if (this.indexEntries[index].ownerId === ownerId && this.indexEntries[index].memoryId === memoryId) {
        this.indexEntries.splice(index, 1);
        result.artifacts++;
      }
    }
    for (let index: number = this.artifacts.length - 1; index >= 0; index--) {
      if (this.artifacts[index].ownerId === ownerId && this.artifacts[index].memoryId === memoryId) {
        this.artifacts.splice(index, 1);
        result.artifacts++;
      }
    }
    return result;
  }

  private removeIndexForOwner(ownerId: string): void {
    for (let index: number = this.chunks.length - 1; index >= 0; index--) {
      if (this.chunks[index].ownerId === ownerId) this.chunks.splice(index, 1);
    }
    for (let index: number = this.indexEntries.length - 1; index >= 0; index--) {
      if (this.indexEntries[index].ownerId === ownerId) this.indexEntries.splice(index, 1);
    }
    for (let index: number = this.artifacts.length - 1; index >= 0; index--) {
      if (this.artifacts[index].ownerId === ownerId && this.artifacts[index].artifactType === 'LEXICAL_INDEX') {
        this.artifacts.splice(index, 1);
      }
    }
  }

  private requiredTagsMatch(tags: string[], required: string[]): boolean {
    for (let index: number = 0; index < required.length; index++) {
      if (!hasTag(tags, required[index])) return false;
    }
    return true;
  }

  private redact(value: string, secrets: string[]): string {
    let result: string = value;
    for (let index: number = 0; index < secrets.length; index++) {
      if (secrets[index].length > 0) result = result.split(secrets[index]).join('[REDACTED]');
    }
    return result;
  }

  private redactStrings(values: string[], secrets: string[]): string[] {
    const result: string[] = [];
    for (let index: number = 0; index < values.length; index++) {
      result.push(this.redact(values[index], secrets));
    }
    return result;
  }

  private findRecord(ownerId: string, memoryId: string): number {
    for (let index: number = 0; index < this.records.length; index++) {
      if (this.records[index].ownerId === ownerId && this.records[index].memoryId === memoryId) return index;
    }
    return -1;
  }

  private findRecordForAnotherOwner(ownerId: string, memoryId: string): number {
    for (let index: number = 0; index < this.records.length; index++) {
      if (this.records[index].ownerId !== ownerId && this.records[index].memoryId === memoryId) return index;
    }
    return -1;
  }

  private findChunk(ownerId: string, chunkId: string): number {
    for (let index: number = 0; index < this.chunks.length; index++) {
      if (this.chunks[index].ownerId === ownerId && this.chunks[index].chunkId === chunkId) return index;
    }
    return -1;
  }

  private findArtifact(ownerId: string, artifactId: string): number {
    for (let index: number = 0; index < this.artifacts.length; index++) {
      if (this.artifacts[index].ownerId === ownerId && this.artifacts[index].artifactId === artifactId) return index;
    }
    return -1;
  }

  private countIndexEntries(ownerId: string): number {
    let count: number = 0;
    for (let index: number = 0; index < this.indexEntries.length; index++) {
      if (this.indexEntries[index].ownerId === ownerId) count++;
    }
    return count;
  }

  private insertHit(values: MemoryHit[], value: MemoryHit): void {
    let insertion: number = values.length;
    for (let index: number = 0; index < values.length; index++) {
      if (value.score > values[index].score ||
        (value.score === values[index].score && value.memoryId < values[index].memoryId) ||
        (value.score === values[index].score && value.memoryId === values[index].memoryId &&
          value.chunkId < values[index].chunkId)) {
        insertion = index;
        break;
      }
    }
    values.splice(insertion, 0, copyHit(value));
  }

  private sortRecords(values: MemoryRecord[]): void {
    for (let index: number = 1; index < values.length; index++) {
      const value: MemoryRecord = values[index];
      let insertion: number = index;
      while (insertion > 0 && value.memoryId < values[insertion - 1].memoryId) {
        values[insertion] = values[insertion - 1];
        insertion--;
      }
      values[insertion] = value;
    }
  }

  private sortChunks(values: MemoryChunk[]): void {
    for (let index: number = 1; index < values.length; index++) {
      const value: MemoryChunk = values[index];
      let insertion: number = index;
      while (insertion > 0 && value.ordinal < values[insertion - 1].ordinal) {
        values[insertion] = values[insertion - 1];
        insertion--;
      }
      values[insertion] = value;
    }
  }

  private sortArtifacts(values: DerivedMemoryArtifact[]): void {
    for (let index: number = 1; index < values.length; index++) {
      const value: DerivedMemoryArtifact = values[index];
      let insertion: number = index;
      while (insertion > 0 && value.artifactId < values[insertion - 1].artifactId) {
        values[insertion] = values[insertion - 1];
        insertion--;
      }
      values[insertion] = value;
    }
  }

  private sortSnapshotRecords(values: MemoryRecord[]): void {
    for (let index: number = 1; index < values.length; index++) {
      const value: MemoryRecord = values[index];
      let insertion: number = index;
      while (insertion > 0 && (value.ownerId < values[insertion - 1].ownerId ||
        (value.ownerId === values[insertion - 1].ownerId && value.memoryId < values[insertion - 1].memoryId))) {
        values[insertion] = values[insertion - 1];
        insertion--;
      }
      values[insertion] = value;
    }
  }

  private sortSnapshotArtifacts(values: DerivedMemoryArtifact[]): void {
    for (let index: number = 1; index < values.length; index++) {
      const value: DerivedMemoryArtifact = values[index];
      let insertion: number = index;
      while (insertion > 0 && (value.ownerId < values[insertion - 1].ownerId ||
        (value.ownerId === values[insertion - 1].ownerId && value.artifactId < values[insertion - 1].artifactId))) {
        values[insertion] = values[insertion - 1];
        insertion--;
      }
      values[insertion] = value;
    }
  }
}
