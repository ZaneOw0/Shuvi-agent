import { UnifiedProcessingSettings, UnifiedProcessingJob, UnifiedProcessingAttempt, UnifiedEffectiveAnnotation, UnifiedImageRecord, UnifiedIndexBinding, UnifiedTextInput } from './UnifiedKnowledgeModels';
import { ParsedDocumentRecord } from './ParsedDocumentModels';
import { ParsedUpgradeBatch } from './ParsedMigrationModels';
export interface UnifiedProcessingRepositoryPort {
  settings(purpose: string): Promise<UnifiedProcessingSettings>; saveSettings(settings: UnifiedProcessingSettings): Promise<void>;
  jobs(): Promise<UnifiedProcessingJob[]>; saveJob(job: UnifiedProcessingJob): Promise<void>;
  saveAttempt(attempt: UnifiedProcessingAttempt): Promise<void>; attempts(job: string): Promise<UnifiedProcessingAttempt[]>;
  retryUnknown(id: string): Promise<void>;
  imageRecords(document?: string): Promise<UnifiedImageRecord[]>;
  annotation(id: string): Promise<UnifiedEffectiveAnnotation | undefined>;
  saveAnnotation(annotation: UnifiedEffectiveAnnotation): Promise<void>;
  applyAnnotation(record: UnifiedImageRecord, annotation: UnifiedEffectiveAnnotation, proxyJob: UnifiedProcessingJob | undefined): Promise<boolean>;
  get(id: string): Promise<ParsedDocumentRecord | undefined>;
  saveBinding(binding: UnifiedIndexBinding): Promise<void>; binding(namespace: string, owner: string): Promise<UnifiedIndexBinding | undefined>;
  admitAttempt(job: UnifiedProcessingJob, attempt: UnifiedProcessingAttempt, launch: () => void): Promise<void>;
  meta(id: string): Promise<string>; putMeta(id: string, value: string): Promise<void>;
  reserveProxyInputs(owner: string, version: string, inputs: UnifiedTextInput[]): Promise<void>;
  ensureCapacity(bytes: number): Promise<void>;
  saveUpgradeBatch(batch: ParsedUpgradeBatch): Promise<void>; upgradeBatch(id: string): Promise<ParsedUpgradeBatch | undefined>;
  upgradeBatchIds(): Promise<string[]>;
  holdProcessingJob(job: UnifiedProcessingJob): Promise<void>;
  releaseProcessingJob(job: UnifiedProcessingJob, pending: boolean): Promise<void>;
  reconcileUnifiedOwners(): Promise<void>;
}
