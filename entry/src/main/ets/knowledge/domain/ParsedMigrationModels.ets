import { ParsedSourceAsset, ParsedProducerPort } from './ParsedDocumentPorts';
import { ParsedCancellation, ParsedLegacyLink, ParsedDocument, ParsedDocumentRecord, ParsedTextChunk } from './ParsedDocumentModels';

export class ParsedMigrationInput {
  key: string = ''; namespace: string = ''; legacyId: string = ''; active: string = ''; epoch: number = 0;
  sourceHash: string = ''; sourceVersion: number = 1; title: string = ''; archived: boolean = false;
  snapshotAsset: string = ''; snapshotHash: string = ''; snapshotFamily: string = ''; sources: ParsedSourceAsset[] = [];
  originalAsset: string = ''; originalBytes: number = 0; resultAsset: string = ''; resultHash: string = ''; resultBytes: number = 0;
  inputHash: string = '';
}
export class ParsedMigrationBatch {
  wire: string = 'UNIFIED-LOCAL-MIGRATION-1'; id: string = ''; inputSetHash: string = ''; inputs: ParsedMigrationInput[] = [];
}
export class ParsedMigrationReceipt {
  batchId: string = ''; inputKey: string = ''; inputHash: string = ''; documentKey: string = ''; generation: string = '';
  phase: string = 'Frozen'; state: string = 'Pending'; failure: string = ''; warnings: string[] = [];
  legacyWire: string = ''; legacyHash: string = ''; wireByteHash: string = ''; contentHash: string = ''; expected: number = 0;
}
export class ParsedLegacyProjection {
  producer: ParsedProducerPort; legacyWire: string = ''; legacyHash: string = ''; wireByteHash: string = ''; warnings: string[] = [];
  constructor(producer: ParsedProducerPort) { this.producer = producer; }
}
export interface ParsedLegacyReadPort {
  catalog(): Promise<ParsedMigrationInput[]>;
  project(input: ParsedMigrationInput, cancel: ParsedCancellation): Promise<ParsedLegacyProjection>;
}
export interface ParsedMigrationStorePort {
  get(id: string): Promise<ParsedDocumentRecord | undefined>; register(record: ParsedDocumentRecord): Promise<void>;
  migrationHold(input: ParsedMigrationInput, holder: string, document: string, generation: string): Promise<void>;
  migrationLink(input: ParsedMigrationInput): Promise<ParsedLegacyLink | undefined>;
  publish(document: ParsedDocument, chunks: ParsedTextChunk[], manifest: string, hash: string, epoch: number, old: string, legacy?: ParsedLegacyLink): Promise<boolean>;
  saveMigrationBatch(batch: ParsedMigrationBatch): Promise<void>; migrationBatch(id: string): Promise<ParsedMigrationBatch | undefined>;
  migrationBatchIds(): Promise<string[]>;
  saveMigrationReceipt(receipt: ParsedMigrationReceipt): Promise<void>; migrationReceipts(batch: string): Promise<ParsedMigrationReceipt[]>;
}
export class ParsedUpgradeTarget {
  documentKey: string = ''; generation: string = ''; epoch: number = 0; manifestHash: string = '';
  images: string[] = []; annotations: string[] = []; bodyInputHash: string = '';
}
export class ParsedUpgradeBatch {
  wire: string = 'UNIFIED-EXPLICIT-UPGRADE-1'; id: string = ''; inputSetHash: string = ''; targets: ParsedUpgradeTarget[] = [];
  visionRevision: number = 0; visionCostRevision: number = 0; embeddingRevision: number = 0; embeddingCostRevision: number = 0;
  approved: boolean = false; paused: boolean = false;
}
export class ParsedUpgradeCoverage {
  documentKey: string = ''; body: string = 'NotUpgraded'; images: number = 0; imageReady: number = 0; failed: number = 0; running: number = 0;
}
