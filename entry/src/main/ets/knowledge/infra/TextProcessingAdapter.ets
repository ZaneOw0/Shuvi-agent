import { taskpool } from '@kit.ArkTS';
import { TextProcessingPort } from '../domain/TextKnowledgePorts';
import { TextCancellation, TextDocument, TextProcessed, TextSnapshot, TextFailure, TextNormalized, TextQueryInput, TextBudget } from '../domain/TextKnowledgeModels';
import { processText, structuredChunks, validateProcessedBounded, encodeSnapshot, decodeSnapshot, verifyTextTransferBudget } from '../pipeline/StructuredChunker';
import { normalizeText, encodeTextUtf8 } from '../pipeline/TextNormalizer';
import { prepareTextQuery } from '../pipeline/QueryPreparation';

@Concurrent
function textQueryWorker(question: string): TextQueryInput { return prepareTextQuery(question); }

@Concurrent
function textDecodeWorker(bytes: Uint8Array): TextNormalized { return normalizeText(bytes); }
@Concurrent
function textSnapshotEncodeWorker(snapshot: TextSnapshot): Uint8Array { return encodeTextUtf8(encodeSnapshot(snapshot)); }
@Concurrent
function textSnapshotDecodeWorker(bytes: Uint8Array): TextSnapshot {
  const parts: string[] = [];
  for (const byte of bytes) {
    if (byte > 127) { throw new TextFailure('SCHEMA', 'snapshot', '快照 wire 编码非法'); }
    parts.push(String.fromCharCode(byte));
  }
  const snapshot: TextSnapshot = decodeSnapshot(parts.join(''));
  const output: TextProcessed = new TextProcessed(); output.snapshot = snapshot;
  verifyTextTransferBudget(output); return snapshot;
}
export async function textEncodeSnapshotTask(snapshot: TextSnapshot): Promise<Uint8Array> {
  return taskpool.execute<[TextSnapshot], Uint8Array>(textSnapshotEncodeWorker, snapshot);
}
export async function textDecodeSnapshotTask(bytes: Uint8Array): Promise<TextSnapshot> {
  return taskpool.execute<[Uint8Array], TextSnapshot>(textSnapshotDecodeWorker, bytes);
}

@Concurrent
function textProcessWorker(bytes: Uint8Array, document: TextDocument, generation: string): TextProcessed {
  return processText(bytes, document, generation);
}
@Concurrent
function textRebuildWorker(snapshot: TextSnapshot, generation: string): TextProcessed {
  const result: TextProcessed = new TextProcessed(); result.snapshot = snapshot;
  // New immutable snapshot identity; do not mutate the published copy on the UI thread.
  result.snapshot.id = `${generation}-snapshot`;
  result.chunks = structuredChunks(result.snapshot, generation); verifyTextTransferBudget(result); return result;
}
export class TextProcessingAdapter implements TextProcessingPort {
  private running: boolean = false;
  async prepareQuery(question: string, cancel: TextCancellation): Promise<TextQueryInput> {
    cancel.check();
    if (question.length * 2 > TextBudget.transferEstimateBytes) { throw new TextFailure('BUDGET', 'query transfer', '完整问题超出线程传输保护预算，未截断，请缩短后重试'); }
    const query: TextQueryInput = await taskpool.execute<[string], TextQueryInput>(textQueryWorker, question);
    cancel.check();
    if (query.fullQuestion !== question || query.actualInput.length === 0 || Array.from(query.actualInput).length > 512 || encodeTextUtf8(query.actualInput).length > 1000) {
      throw new TextFailure('SCHEMA', 'query transfer', '检索输入载荷校验失败');
    }
    return query;
  }
  async decode(bytes: Uint8Array, cancel: TextCancellation): Promise<TextNormalized> {
    cancel.check();
    const normalized: TextNormalized = await taskpool.execute<[Uint8Array], TextNormalized>(textDecodeWorker, bytes);
    cancel.check(); return normalized;
  }
  async process(bytes: Uint8Array, document: TextDocument, generation: string, cancel: TextCancellation): Promise<TextProcessed> {
    if (this.running) { throw new TextFailure('BUSY', 'CPU', '仍有一个处理任务待结束'); }
    cancel.check(); this.running = true;
    try {
      const result: TextProcessed = await taskpool.execute<[Uint8Array, TextDocument, string], TextProcessed>(textProcessWorker, bytes, document, generation);
      cancel.check(); await validateProcessedBounded(result, document, generation); return result;
    } finally { this.running = false; }
  }
  async rebuild(snapshot: TextSnapshot, generation: string, cancel: TextCancellation): Promise<TextProcessed> {
    if (this.running) { throw new TextFailure('BUSY', 'CPU', '仍有一个处理任务待结束'); }
    cancel.check(); this.running = true;
    try {
      const result: TextProcessed = await taskpool.execute<[TextSnapshot, string], TextProcessed>(textRebuildWorker, snapshot, generation);
      cancel.check();
      const document: TextDocument = new TextDocument(); document.id = snapshot.documentId;
      document.version = snapshot.documentVersion; document.original.hash = snapshot.originalHash;
      await validateProcessedBounded(result, document, generation); return result;
    } finally { this.running = false; }
  }
}
