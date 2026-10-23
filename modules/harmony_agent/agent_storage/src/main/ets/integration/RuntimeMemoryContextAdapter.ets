import {
  PLANNING_MEMORY_CONTEXT_VERSION,
  PlanningMemoryContextItem,
  PlanningMemoryContextPort,
  PlanningMemoryContextRequest,
  PlanningMemoryContextResult
} from '@harmony_agent/agent-runtime';
import { RebuildableMemoryIndexPort } from '../memory/MemoryPorts';
import { MemoryHit, MemoryQuery } from '../memory/MemoryTypes';

const MAX_CONTEXT_ITEMS: number = 50;
const MAX_CONTEXT_CHARACTERS: number = 32768;

function validText(value: string): boolean {
  return value.trim().length > 0;
}

function copyStrings(source: string[]): string[] {
  const result: string[] = [];
  for (let index: number = 0; index < source.length; index++) result.push(source[index]);
  return result;
}

function contains(values: string[], value: string): boolean {
  for (let index: number = 0; index < values.length; index++) {
    if (values[index] === value) return true;
  }
  return false;
}

function validRequest(request: PlanningMemoryContextRequest): boolean {
  if (request.contextVersion !== PLANNING_MEMORY_CONTEXT_VERSION || !validText(request.taskId) ||
    !validText(request.ownerId) || request.queryTerms.length === 0 ||
    !Number.isSafeInteger(request.maxItems) || request.maxItems <= 0 ||
    request.maxItems > MAX_CONTEXT_ITEMS || !Number.isSafeInteger(request.maxCharacters) ||
    request.maxCharacters <= 0 || request.maxCharacters > MAX_CONTEXT_CHARACTERS) return false;
  for (let index: number = 0; index < request.queryTerms.length; index++) {
    if (!validText(request.queryTerms[index])) return false;
  }
  return true;
}

function validHit(hit: MemoryHit): boolean {
  if (!validText(hit.memoryId) || !validText(hit.chunkId) ||
    !Number.isSafeInteger(hit.memoryVersion) || hit.memoryVersion <= 0 || !validText(hit.content)) return false;
  for (let index: number = 0; index < hit.tags.length; index++) {
    if (!validText(hit.tags[index])) return false;
  }
  return true;
}

/**
 * Projects the rebuildable memory index into the Runtime contract. Sensitive
 * memories and raw personal traces are always excluded at this boundary.
 */
export class RuntimeMemoryContextAdapter implements PlanningMemoryContextPort {
  private readonly index: RebuildableMemoryIndexPort;

  constructor(index: RebuildableMemoryIndexPort) {
    this.index = index;
  }

  retrieve(request: PlanningMemoryContextRequest): PlanningMemoryContextResult {
    if (!validRequest(request)) throw new Error('invalid planning memory context request');
    const query: MemoryQuery = new MemoryQuery();
    query.ownerId = request.ownerId;
    query.terms = copyStrings(request.queryTerms);
    query.limit = request.maxItems + 1;
    query.includeSensitive = false;
    query.includeRawPersonalTrace = false;
    const hits: MemoryHit[] = this.index.searchMemory(query);
    const result: PlanningMemoryContextResult = new PlanningMemoryContextResult();
    result.taskId = request.taskId;
    result.ownerId = request.ownerId;
    const seenChunks: string[] = [];
    for (let index: number = 0; index < hits.length; index++) {
      if (result.items.length >= request.maxItems || result.totalCharacters >= request.maxCharacters) {
        result.truncated = true;
        break;
      }
      const hit: MemoryHit = hits[index];
      if (!validHit(hit) || contains(seenChunks, hit.chunkId)) {
        throw new Error('memory index returned an invalid or duplicate hit');
      }
      const remaining: number = request.maxCharacters - result.totalCharacters;
      const content: string = hit.content.length > remaining ? hit.content.substring(0, remaining) : hit.content;
      if (!validText(content)) {
        result.truncated = true;
        break;
      }
      const item: PlanningMemoryContextItem = new PlanningMemoryContextItem();
      item.memoryId = hit.memoryId;
      item.chunkId = hit.chunkId;
      item.memoryVersion = hit.memoryVersion;
      item.content = content;
      item.tags = copyStrings(hit.tags);
      result.items.push(item);
      seenChunks.push(hit.chunkId);
      result.totalCharacters += content.length;
      if (content.length < hit.content.length) {
        result.truncated = true;
        break;
      }
    }
    if (hits.length > result.items.length) result.truncated = true;
    return result;
  }
}
