import { ParsedDocumentRecord } from './ParsedDocumentModels';
import { UnifiedProcessingJob } from './UnifiedKnowledgeModels';
export interface ParsedLifecycleRepositoryPort {
  get(id: string): Promise<ParsedDocumentRecord | undefined>;
  setUnifiedArchived(id: string, archived: boolean): Promise<void>;
  deleteUnified(id: string): Promise<void>;
  reconcileUnifiedOwners(): Promise<void>;
  unifiedCleanupAssets(): Promise<string[]>;
  retryReadReleases(): Promise<void>;
  retryProcessingReleases(): Promise<void>;
  jobs(): Promise<UnifiedProcessingJob[]>;
  acknowledgeUnknownRelease(id: string): Promise<void>;
  recoverReadLeases(session: string): Promise<void>;
  retiredGenerationIds(document: string): Promise<string[]>;
  retireUnifiedGeneration(document: string, generation: string): Promise<void>;
}
export interface ParsedLifecycleAssetsPort { cleanup(id: string): Promise<boolean>; }
export interface ParsedLifecycleMirrorPort { reconcileCurrentOwners(): Promise<void>; }
export interface ParsedLifecycleQueuePort { stop(): Promise<void>; kick(): void; }
