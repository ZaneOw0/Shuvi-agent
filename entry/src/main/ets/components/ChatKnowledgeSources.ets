import { KnowledgeRuntimeCitation } from '../knowledge/domain/KnowledgeRuntimePorts';
import { ChatKnowledgeSource, ChatKnowledgeSnapshot, copyChatKnowledgeSnapshot } from '../model/ChatKnowledgeModels';

export class ChatKnowledgeReply {
  text: string = '';
  sources: ChatKnowledgeSource[] = [];
}

/** Rebuild cards from this message's saved bindings, independent of current retrieval results or message ids. */
export function chatKnowledgeStoredReply(text: string, saved: ChatKnowledgeSnapshot | undefined): ChatKnowledgeReply {
  const reply: ChatKnowledgeReply = new ChatKnowledgeReply(); reply.text = text;
  const snapshot: ChatKnowledgeSnapshot | undefined = copyChatKnowledgeSnapshot(saved);
  const footer: RegExpMatchArray | null = text.match(/\n\n个人知识库来源：((?:\[\d+\]\s*)+)(?=$|\n\n(?:网页来源：|本轮搜索到的网页（回答未直接引用）：))/);
  if (snapshot === undefined || footer === null) { return reply; }
  const numbers: number[] = (footer[1].match(/\d+/g) ?? []).map((id: string): number => Number(id));
  const storedIds: number[] = [];
  for (const source of snapshot.sources) {
    for (const id of source.citationIds) { storedIds.push(id); }
  }
  if (numbers.length !== storedIds.length || new Set<number>(numbers).size !== numbers.length ||
    numbers.some((id: number): boolean => !storedIds.includes(id))) { return reply; }
  reply.sources = snapshot.sources; reply.text = text.replace(footer[0], '');
  return reply;
}

function chatKnowledgeFileType(citation: KnowledgeRuntimeCitation): string {
  const extension: string = citation.title.trim().split('.').pop()?.toLowerCase() ?? '';
  if (['pdf', 'docx', 'doc', 'txt', 'md', 'markdown', 'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'heic'].includes(extension)) {
    return extension === 'markdown' ? 'MD' : extension.toUpperCase();
  }
  if (citation.kind === 'Image') { return '图片'; }
  if (citation.kind === 'Pdf') { return 'PDF'; }
  if (citation.kind === 'Docx') { return 'DOCX'; }
  return '文本';
}

export function chatKnowledgeReply(text: string, citations: KnowledgeRuntimeCitation[]): ChatKnowledgeReply {
  const reply: ChatKnowledgeReply = new ChatKnowledgeReply(); reply.text = text;
  const footer: RegExpMatchArray | null = text.match(/\n\n个人知识库来源：((?:\[\d+\]\s*)+)(?=$|\n\n(?:网页来源：|本轮搜索到的网页（回答未直接引用）：))/);
  if (footer === null) { return reply; }
  const numbers: string[] = footer[1].match(/\d+/g) ?? [];
  // Only replace the host's footer when every number has a real, bound source.
  for (const number of numbers) {
    const citation: KnowledgeRuntimeCitation | undefined = citations.find((item: KnowledgeRuntimeCitation): boolean => item.citationId === Number(number));
    if (citation === undefined || !citation.documentId || !citation.generation) { return reply; }
  }
  for (const number of numbers) {
    const citation: KnowledgeRuntimeCitation | undefined = citations.find((item: KnowledgeRuntimeCitation): boolean => item.citationId === Number(number));
    if (citation === undefined) { return reply; }
    const existing: ChatKnowledgeSource | undefined = reply.sources.find((source: ChatKnowledgeSource): boolean =>
      source.documentId === citation.documentId && source.generation === citation.generation);
    if (existing !== undefined) { existing.citationIds.push(citation.citationId); continue; }
    const source: ChatKnowledgeSource = new ChatKnowledgeSource();
    source.documentId = citation.documentId; source.generation = citation.generation;
    source.title = citation.title; source.fileType = chatKnowledgeFileType(citation); source.citationIds = [citation.citationId];
    reply.sources.push(source);
  }
  if (reply.sources.length > 0) { reply.text = text.replace(footer[0], ''); }
  return reply;
}

export function chatKnowledgeSourceNumbers(source: ChatKnowledgeSource): string {
  return source.citationIds.map((id: number): string => `[${id}]`).join(' ');
}
