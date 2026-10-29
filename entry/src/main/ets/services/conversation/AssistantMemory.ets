import { ToolChatMessage } from '../model/DeepSeekToolTransport';

/** Longest compacted summary kept for one conversation. */
export const ASSISTANT_MEMORY_SUMMARY_MAX: number = 4000;

/** Serializable model memory of one assistant conversation (text only; images are never stored). */
export class AssistantMemoryState {
  turns: ToolChatMessage[][] = [];
  /** Model-written summary of turns that were compacted away. */
  summary: string = '';
  /** Host record of how the last calendar proposal ended; sent once with the next turn. */
  outcome: string = '';
}

function copyTurns(turns: ToolChatMessage[][]): ToolChatMessage[][] {
  return JSON.parse(JSON.stringify(turns)) as ToolChatMessage[][];
}

function validTurns(value: Object): boolean {
  if (!Array.isArray(value)) return false;
  for (const turn of value as Object[]) {
    if (!Array.isArray(turn) || (turn as Object[]).length === 0) return false;
    for (const message of turn as Object[]) {
      if (message === null || typeof message !== 'object' || Array.isArray(message)) return false;
      const record: Record<string, Object> = message as Record<string, Object>;
      const content: Object = record['content'];
      if (['user', 'assistant', 'tool'].indexOf(record['role'] as string) < 0 ||
        (content !== null && typeof content !== 'string')) return false;
    }
  }
  return true;
}

/** Parses stored memory; anything malformed becomes an empty memory instead of breaking the conversation. */
export function parseAssistantMemory(json: string): AssistantMemoryState {
  const empty: AssistantMemoryState = new AssistantMemoryState();
  try {
    if (typeof json !== 'string' || json.length === 0) return empty;
    const value: AssistantMemoryState = JSON.parse(json) as AssistantMemoryState;
    if (value === null || typeof value !== 'object' || !validTurns(value.turns as Object) ||
      typeof value.summary !== 'string' || typeof value.outcome !== 'string') return empty;
    const state: AssistantMemoryState = new AssistantMemoryState();
    state.turns = copyTurns(value.turns); state.summary = value.summary.slice(0, ASSISTANT_MEMORY_SUMMARY_MAX);
    state.outcome = value.outcome.slice(0, 300);
    return state;
  } catch {
    return empty;
  }
}

/**
 * The model's memory of the current assistant conversation. It outlives model sessions (switching pages, going to
 * the background or toggling search restarts the session, not the conversation); the conversation store persists it.
 */
export class AssistantMemory {
  private state: AssistantMemoryState = new AssistantMemoryState();
  private listener?: () => void;

  /** One listener (the conversation store) is told about every change. */
  onChange(listener?: () => void): void { this.listener = listener; }
  private changed(): void { this.listener?.(); }

  turns(): ToolChatMessage[][] { return copyTurns(this.state.turns); }
  summary(): string { return this.state.summary; }
  remember(turn: ToolChatMessage[]): void {
    if (turn.length === 0) return;
    this.state.turns.push(JSON.parse(JSON.stringify(turn)) as ToolChatMessage[]); this.changed();
  }
  /** Replaces the oldest `count` turns with a new summary of everything before the remaining turns. */
  compact(summary: string, count: number): void {
    if (!Number.isSafeInteger(count) || count < 1 || count > this.state.turns.length) return;
    this.state.turns.splice(0, count);
    this.state.summary = summary.trim().slice(0, ASSISTANT_MEMORY_SUMMARY_MAX);
    this.changed();
  }
  setOutcome(text: string): void { this.state.outcome = text.trim().slice(0, 300); this.changed(); }
  /** Returns the pending outcome once and clears it. */
  takeOutcome(): string {
    const value: string = this.state.outcome;
    if (value.length > 0) { this.state.outcome = ''; this.changed(); }
    return value;
  }
  clear(): void { this.state = new AssistantMemoryState(); this.changed(); }
  snapshot(): AssistantMemoryState { return parseAssistantMemory(JSON.stringify(this.state)); }
  /** Loads another conversation's memory without reporting a change (nothing new to save). */
  restore(state: AssistantMemoryState): void { this.state = parseAssistantMemory(JSON.stringify(state)); }
}
