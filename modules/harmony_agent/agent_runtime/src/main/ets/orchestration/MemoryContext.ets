export const PLANNING_MEMORY_CONTEXT_VERSION: string = '1.0';

/** Storage-neutral request for bounded, owner-scoped planning context. */
export class PlanningMemoryContextRequest {
  contextVersion: string = PLANNING_MEMORY_CONTEXT_VERSION;
  taskId: string = '';
  ownerId: string = '';
  queryTerms: string[] = [];
  maxItems: number = 0;
  maxCharacters: number = 0;
}

/** Minimal memory projection allowed to enter a Provider planning prompt. */
export class PlanningMemoryContextItem {
  memoryId: string = '';
  chunkId: string = '';
  memoryVersion: number = 0;
  content: string = '';
  tags: string[] = [];
}

/** Result remains bound to the task and owner that issued the request. */
export class PlanningMemoryContextResult {
  contextVersion: string = PLANNING_MEMORY_CONTEXT_VERSION;
  taskId: string = '';
  ownerId: string = '';
  items: PlanningMemoryContextItem[] = [];
  totalCharacters: number = 0;
  truncated: boolean = false;
}

/**
 * Implemented by a host or storage adapter. The operation is synchronous so
 * Provider planning cannot remain blocked on an unbounded memory request.
 */
export interface PlanningMemoryContextPort {
  retrieve(request: PlanningMemoryContextRequest): PlanningMemoryContextResult;
}
