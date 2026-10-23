import { OperationJournalState } from './CoreEnums';
import { OperationJournalEntry } from './CoreTypes';
import { WorkflowKernelError } from './WorkflowKernelError';

export class OperationJournal {
  private entries: OperationJournalEntry[] = [];

  prepare(operationId: string, stepId: string, idempotencyKey: string, nowMs: number): void {
    if (operationId.trim().length === 0 || stepId.trim().length === 0) {
      throw new WorkflowKernelError('Operation and step identifiers must not be empty');
    }
    if (this.findIndex(operationId) >= 0) {
      throw new WorkflowKernelError('Operation already exists: ' + operationId);
    }
    const entry: OperationJournalEntry = new OperationJournalEntry();
    entry.operationId = operationId;
    entry.stepId = stepId;
    entry.idempotencyKey = idempotencyKey;
    entry.state = OperationJournalState.PREPARED;
    entry.updatedAtMs = nowMs;
    this.entries.push(entry);
  }

  markInFlight(operationId: string, nowMs: number): void {
    const entry: OperationJournalEntry = this.requireEntry(operationId);
    if (entry.state !== OperationJournalState.PREPARED) {
      throw new WorkflowKernelError('Only a prepared operation can be dispatched');
    }
    entry.state = OperationJournalState.IN_FLIGHT;
    entry.updatedAtMs = nowMs;
  }

  commit(operationId: string, nowMs: number): void {
    const entry: OperationJournalEntry = this.requireEntry(operationId);
    if (entry.state !== OperationJournalState.IN_FLIGHT) {
      throw new WorkflowKernelError('Only an in-flight operation can be committed');
    }
    entry.state = OperationJournalState.COMMITTED;
    entry.updatedAtMs = nowMs;
  }

  markUnknownOutcome(operationId: string, nowMs: number): void {
    const entry: OperationJournalEntry = this.requireEntry(operationId);
    if (entry.state !== OperationJournalState.IN_FLIGHT) {
      throw new WorkflowKernelError('Only an in-flight operation can have an unknown outcome');
    }
    entry.state = OperationJournalState.UNKNOWN_OUTCOME;
    entry.updatedAtMs = nowMs;
  }

  reconcileUnknownOutcome(operationId: string, committed: boolean, nowMs: number): void {
    const entry: OperationJournalEntry = this.requireEntry(operationId);
    if (entry.state !== OperationJournalState.UNKNOWN_OUTCOME) {
      throw new WorkflowKernelError('Only an unknown operation outcome can be reconciled');
    }
    entry.state = committed ? OperationJournalState.COMMITTED : OperationJournalState.PREPARED;
    entry.updatedAtMs = nowMs;
  }

  canDispatch(operationId: string): boolean {
    const index: number = this.findIndex(operationId);
    return index >= 0 && this.entries[index].state === OperationJournalState.PREPARED;
  }

  get(operationId: string): OperationJournalEntry {
    return OperationJournal.copyEntry(this.requireEntry(operationId));
  }

  snapshot(): OperationJournalEntry[] {
    const snapshot: OperationJournalEntry[] = [];
    for (let i: number = 0; i < this.entries.length; i++) {
      snapshot.push(OperationJournal.copyEntry(this.entries[i]));
    }
    return snapshot;
  }

  static restore(snapshot: OperationJournalEntry[]): OperationJournal {
    const journal: OperationJournal = new OperationJournal();
    for (let i: number = 0; i < snapshot.length; i++) {
      if (journal.findIndex(snapshot[i].operationId) >= 0) {
        throw new WorkflowKernelError('Duplicate operation in journal snapshot: ' + snapshot[i].operationId);
      }
      const entry: OperationJournalEntry = OperationJournal.copyEntry(snapshot[i]);
      if (entry.state === OperationJournalState.IN_FLIGHT) {
        entry.state = OperationJournalState.UNKNOWN_OUTCOME;
      }
      journal.entries.push(entry);
    }
    return journal;
  }

  private requireEntry(operationId: string): OperationJournalEntry {
    const index: number = this.findIndex(operationId);
    if (index < 0) {
      throw new WorkflowKernelError('Unknown operation ' + operationId);
    }
    return this.entries[index];
  }

  private findIndex(operationId: string): number {
    for (let i: number = 0; i < this.entries.length; i++) {
      if (this.entries[i].operationId === operationId) {
        return i;
      }
    }
    return -1;
  }

  private static copyEntry(source: OperationJournalEntry): OperationJournalEntry {
    const copy: OperationJournalEntry = new OperationJournalEntry();
    copy.operationId = source.operationId;
    copy.stepId = source.stepId;
    copy.idempotencyKey = source.idempotencyKey;
    copy.state = source.state;
    copy.updatedAtMs = source.updatedAtMs;
    return copy;
  }
}
