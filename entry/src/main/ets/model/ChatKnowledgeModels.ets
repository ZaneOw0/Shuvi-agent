/** Display-only source metadata. It never grants access or becomes model memory. */
export class ChatKnowledgeSource {
  documentId: string = '';
  generation: string = '';
  title: string = '';
  fileType: string = '';
  citationIds: number[] = [];
}

/** Optional v1 extension of stored display messages; older messages have no snapshot. */
export class ChatKnowledgeSnapshot {
  schemaVersion: number = 1;
  sources: ChatKnowledgeSource[] = [];
}

/** Validate persisted data and copy only the allowed display fields. Unknown versions are ignored. */
export function copyChatKnowledgeSnapshot(snapshot: ChatKnowledgeSnapshot | undefined): ChatKnowledgeSnapshot | undefined {
  if (snapshot === undefined || snapshot === null || typeof snapshot !== 'object' || Array.isArray(snapshot) ||
    snapshot.schemaVersion !== 1 || !Array.isArray(snapshot.sources) || snapshot.sources.length < 1 || snapshot.sources.length > 5) {
    return undefined;
  }
  const copied: ChatKnowledgeSnapshot = new ChatKnowledgeSnapshot();
  const numbers: Set<number> = new Set<number>();
  for (const source of snapshot.sources) {
    if (source === undefined || source === null || typeof source !== 'object' || Array.isArray(source) ||
      typeof source.documentId !== 'string' || !source.documentId || source.documentId.length > 256 ||
      typeof source.generation !== 'string' || !source.generation || source.generation.length > 256 ||
      typeof source.title !== 'string' || source.title.length > 256 ||
      typeof source.fileType !== 'string' || !source.fileType || source.fileType.length > 16 ||
      !Array.isArray(source.citationIds) || source.citationIds.length < 1 || source.citationIds.length > 5 ||
      copied.sources.some((item: ChatKnowledgeSource): boolean => item.documentId === source.documentId && item.generation === source.generation)) {
      return undefined;
    }
    const item: ChatKnowledgeSource = new ChatKnowledgeSource();
    item.documentId = source.documentId; item.generation = source.generation; item.title = source.title; item.fileType = source.fileType;
    for (const id of source.citationIds) {
      if (typeof id !== 'number' || !Number.isSafeInteger(id) || id < 1 || id > 5 || numbers.has(id)) { return undefined; }
      numbers.add(id); item.citationIds.push(id);
    }
    copied.sources.push(item);
  }
  return copied;
}
