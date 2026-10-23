import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
export async function knowledgeWithin<T>(operation: Promise<T>, cancel: KnowledgeCancellation): Promise<T> {
  cancel.check(); let timer: number = -1;
  const expired = new Promise<T>((_resolve: (item: T) => void,reject: (error: Object) => void): void => { timer = setTimeout((): void => { reject(new KnowledgeFailure('Timeout','query-deadline')); },Math.max(1,cancel.deadline-cancel.now())); });
  try { const result: T = await Promise.race<T>([operation,expired]); cancel.check(); return result; }
  finally { clearTimeout(timer); }
}
