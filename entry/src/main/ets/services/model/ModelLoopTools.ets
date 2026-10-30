/**
 * The personal knowledge tool. Only its use switches a turn to the bounded knowledge mode (fewer rounds, session-only
 * history); other loop tools such as web search run under the normal assistant limits.
 */
export const KNOWLEDGE_SEARCH_TOOL: string = 'knowledge_search';

/** Optional tool families composed with document tools; execution stays behind their Runtime adapters. */
export interface ModelLoopToolsPort {
  names(): string[];
  definitions(): Object[];
  policy(): string;
  revision(): number;
  begin(question: string, turnId: string, deadline: number): void;
  invoke(name: string, argumentsJson: string, callId: string): Promise<string>;
  finish(text: string): Promise<string>;
  cancel(): Promise<void>;
  close(): Promise<void>;
}

/**
 * Several loop tool families in one model loop (personal knowledge and web search). Each family keeps its own
 * authorization; the combined revision changes whenever any of them changes, so the loop cancels a stale turn.
 */
export class CombinedLoopTools implements ModelLoopToolsPort {
  private readonly parts: ModelLoopToolsPort[];
  constructor(parts: ModelLoopToolsPort[]) { this.parts = parts.slice(); }
  names(): string[] {
    const names: string[] = [];
    for (const part of this.parts) { for (const name of part.names()) { names.push(name); } }
    return names;
  }
  definitions(): Object[] {
    const definitions: Object[] = [];
    for (const part of this.parts) { for (const definition of part.definitions()) { definitions.push(definition); } }
    return definitions;
  }
  policy(): string {
    const lines: string[] = [];
    for (const part of this.parts) { const line: string = part.policy(); if (line) { lines.push(line); } }
    return lines.join('\n');
  }
  revision(): number {
    let total: number = 0;
    for (const part of this.parts) { total += part.revision(); }
    return total;
  }
  begin(question: string, turnId: string, deadline: number): void {
    for (const part of this.parts) { part.begin(question, turnId, deadline); }
  }
  invoke(name: string, argumentsJson: string, callId: string): Promise<string> {
    for (const part of this.parts) {
      if (part.names().includes(name)) { return part.invoke(name, argumentsJson, callId); }
    }
    return Promise.reject(new Error('LOOP_TOOL_DENIED'));
  }
  async finish(text: string): Promise<string> {
    let value: string = text;
    for (const part of this.parts) { value = await part.finish(value); }
    return value;
  }
  async cancel(): Promise<void> { await this.each((part: ModelLoopToolsPort): Promise<void> => part.cancel()); }
  async close(): Promise<void> { await this.each((part: ModelLoopToolsPort): Promise<void> => part.close()); }
  /** Runs on every family even if one fails, then reports the first failure. */
  private async each(action: (part: ModelLoopToolsPort) => Promise<void>): Promise<void> {
    let failure: Error | undefined = undefined;
    for (const part of this.parts) {
      try { await action(part); } catch (error) { if (failure === undefined) { failure = error as Error; } }
    }
    if (failure !== undefined) { throw failure; }
  }
}
