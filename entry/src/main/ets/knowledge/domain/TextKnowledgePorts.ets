import {
  TextCancellation, TextSelection, TextSelectedFile, TextOriginal, TextDocument, TextJob,
  TextProcessed, TextSnapshot, TextChunk, TextUsage, TextCleanup, TextQueryInput,
  TextSearchResult, TextHistory, TextChannel, TextNormalized
} from './TextKnowledgeModels';

export interface TextSelectionPort { select(): Promise<TextSelection>; }
export interface TextAssetPort {
  saveOriginal(file: TextSelectedFile, assetId: string, cancel: TextCancellation): Promise<TextOriginal>;
  readOriginal(original: TextOriginal, cancel: TextCancellation): Promise<Uint8Array>;
  saveSnapshot(snapshot: TextSnapshot): Promise<void>;
  readSnapshot(snapshotId: string): Promise<TextSnapshot>;
  remove(assetIds: string[]): Promise<void>;
  reconcile(keepIds: string[]): Promise<void>;
}
export interface TextProcessingPort {
  prepareQuery(question: string, cancel: TextCancellation): Promise<TextQueryInput>;
  decode(bytes: Uint8Array, cancel: TextCancellation): Promise<TextNormalized>;
  process(bytes: Uint8Array, document: TextDocument, generation: string, cancel: TextCancellation): Promise<TextProcessed>;
  rebuild(snapshot: TextSnapshot, generation: string, cancel: TextCancellation): Promise<TextProcessed>;
}
export interface TextRepositoryPort {
  open(): Promise<void>;
  close(): Promise<void>;
  channel(): TextChannel;
  list(): Promise<TextDocument[]>;
  usage(): Promise<TextUsage>;
  findHash(hash: string): Promise<TextDocument | undefined>;
  get(id: string): Promise<TextDocument | undefined>;
  add(document: TextDocument, job: TextJob): Promise<void>;
  start(job: TextJob): Promise<void>;
  checkpoint(job: TextJob): Promise<void>;
  jobs(): Promise<TextJob[]>;
  prepare(document: TextDocument, job: TextJob, chunks: TextChunk[]): Promise<void>;
  publish(document: TextDocument, job: TextJob, chunks: number): Promise<boolean>;
  rename(id: string, title: string): Promise<void>;
  archive(id: string, archived: boolean): Promise<void>;
  deleteDocuments(ids: string[]): Promise<void>;
  cleanups(): Promise<TextCleanup[]>;
  finishCleanup(id: string, failure: string): Promise<void>;
  reconcile(pauseJobs?: boolean): Promise<void>;
  assetIds(): Promise<string[]>;
  search(input: TextQueryInput, includeArchived: boolean, cancel: TextCancellation): Promise<TextSearchResult>;
  saveHistory(history: TextHistory): Promise<void>;
  history(offset: number, limit: number): Promise<TextHistory[]>;
}
export interface TextStateListener { changed(): void; }

// No history side effects. The original repository search contract stays top five.
export interface TextCandidatePort extends TextRepositoryPort {
  candidates(input: TextQueryInput, includeArchived: boolean, cancel: TextCancellation): Promise<TextSearchResult>;
  directCandidates?(input: TextQueryInput, includeArchived: boolean, cancel: TextCancellation): Promise<TextSearchResult>;
}

export interface TextDirectCandidatePort extends TextCandidatePort {
  directCandidates(input: TextQueryInput, includeArchived: boolean, cancel: TextCancellation): Promise<TextSearchResult>;
}
