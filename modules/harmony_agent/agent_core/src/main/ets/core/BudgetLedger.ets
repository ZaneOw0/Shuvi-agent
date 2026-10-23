import { ExecutionBudget } from '@harmony_agent/agent-contracts';
import { BudgetReservationState, BudgetScopeKind } from './CoreEnums';
import {
  BudgetAmount,
  BudgetReservationRequest,
  BudgetReservationResult,
  BudgetReservationSnapshot,
  BudgetScopeSnapshot,
  BudgetSettlementResult
} from './BudgetTypes';
import { BudgetLedgerError } from './BudgetLedgerError';

function copyAmount(source: BudgetAmount): BudgetAmount {
  const value: BudgetAmount = new BudgetAmount();
  value.wallTimeMs = source.wallTimeMs;
  value.inputTokens = source.inputTokens;
  value.outputTokens = source.outputTokens;
  value.monetaryCostMicros = source.monetaryCostMicros;
  value.toolCalls = source.toolCalls;
  value.agentActivations = source.agentActivations;
  value.retries = source.retries;
  value.replans = source.replans;
  return value;
}

function copyBudget(source: ExecutionBudget): ExecutionBudget {
  const value: ExecutionBudget = new ExecutionBudget();
  value.maxWallTimeMs = source.maxWallTimeMs;
  value.maxInputTokens = source.maxInputTokens;
  value.maxOutputTokens = source.maxOutputTokens;
  value.maxMonetaryCostMicros = source.maxMonetaryCostMicros;
  value.maxToolCalls = source.maxToolCalls;
  value.maxAgentActivations = source.maxAgentActivations;
  value.maxRetries = source.maxRetries;
  value.maxReplans = source.maxReplans;
  value.deadlineAt = source.deadlineAt;
  return value;
}

function validCount(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function validBudget(value: ExecutionBudget): boolean {
  return validCount(value.maxWallTimeMs) && validCount(value.maxInputTokens) &&
    validCount(value.maxOutputTokens) && validCount(value.maxMonetaryCostMicros) &&
    validCount(value.maxToolCalls) && validCount(value.maxAgentActivations) &&
    validCount(value.maxRetries) && validCount(value.maxReplans);
}

function add(target: BudgetAmount, value: BudgetAmount): void {
  target.wallTimeMs += value.wallTimeMs;
  target.inputTokens += value.inputTokens;
  target.outputTokens += value.outputTokens;
  target.monetaryCostMicros += value.monetaryCostMicros;
  target.toolCalls += value.toolCalls;
  target.agentActivations += value.agentActivations;
  target.retries += value.retries;
  target.replans += value.replans;
}

function subtract(target: BudgetAmount, value: BudgetAmount): void {
  target.wallTimeMs -= value.wallTimeMs;
  target.inputTokens -= value.inputTokens;
  target.outputTokens -= value.outputTokens;
  target.monetaryCostMicros -= value.monetaryCostMicros;
  target.toolCalls -= value.toolCalls;
  target.agentActivations -= value.agentActivations;
  target.retries -= value.retries;
  target.replans -= value.replans;
}

function nonNegative(value: BudgetAmount): boolean {
  return validCount(value.wallTimeMs) && validCount(value.inputTokens) && validCount(value.outputTokens) &&
    validCount(value.monetaryCostMicros) && validCount(value.toolCalls) &&
    validCount(value.agentActivations) && validCount(value.retries) && validCount(value.replans);
}

function sameAmount(left: BudgetAmount, right: BudgetAmount): boolean {
  return left.wallTimeMs === right.wallTimeMs && left.inputTokens === right.inputTokens &&
    left.outputTokens === right.outputTokens && left.monetaryCostMicros === right.monetaryCostMicros &&
    left.toolCalls === right.toolCalls && left.agentActivations === right.agentActivations &&
    left.retries === right.retries && left.replans === right.replans;
}

function sameBudget(left: ExecutionBudget, right: ExecutionBudget): boolean {
  return left.maxWallTimeMs === right.maxWallTimeMs && left.maxInputTokens === right.maxInputTokens &&
    left.maxOutputTokens === right.maxOutputTokens &&
    left.maxMonetaryCostMicros === right.maxMonetaryCostMicros &&
    left.maxToolCalls === right.maxToolCalls && left.maxAgentActivations === right.maxAgentActivations &&
    left.maxRetries === right.maxRetries && left.maxReplans === right.maxReplans &&
    left.deadlineAt === right.deadlineAt;
}

function copyReservation(source: BudgetReservationSnapshot): BudgetReservationSnapshot {
  const value: BudgetReservationSnapshot = new BudgetReservationSnapshot();
  value.reservationId = source.reservationId;
  value.taskId = source.taskId;
  value.stepId = source.stepId;
  value.providerId = source.providerId;
  value.requested = copyAmount(source.requested);
  value.actual = copyAmount(source.actual);
  value.state = source.state;
  return value;
}

function exceeds(limit: ExecutionBudget, consumed: BudgetAmount, reserved: BudgetAmount,
  requested: BudgetAmount): boolean {
  return consumed.wallTimeMs + reserved.wallTimeMs + requested.wallTimeMs > limit.maxWallTimeMs ||
    consumed.inputTokens + reserved.inputTokens + requested.inputTokens > limit.maxInputTokens ||
    consumed.outputTokens + reserved.outputTokens + requested.outputTokens > limit.maxOutputTokens ||
    consumed.monetaryCostMicros + reserved.monetaryCostMicros + requested.monetaryCostMicros >
      limit.maxMonetaryCostMicros ||
    consumed.toolCalls + reserved.toolCalls + requested.toolCalls > limit.maxToolCalls ||
    consumed.agentActivations + reserved.agentActivations + requested.agentActivations >
      limit.maxAgentActivations ||
    consumed.retries + reserved.retries + requested.retries > limit.maxRetries ||
    consumed.replans + reserved.replans + requested.replans > limit.maxReplans;
}

export class BudgetLedger {
  private scopes: BudgetScopeSnapshot[] = [];
  private reservations: BudgetReservationSnapshot[] = [];

  registerTask(taskId: string, limit: ExecutionBudget): void {
    this.registerScope(BudgetScopeKind.TASK, taskId, taskId, limit);
  }

  registerStep(taskId: string, stepId: string, limit: ExecutionBudget): void {
    this.requireScope(BudgetScopeKind.TASK, taskId, taskId);
    this.registerScope(BudgetScopeKind.STEP, taskId, stepId, limit);
  }

  registerProvider(taskId: string, providerId: string, limit: ExecutionBudget): void {
    this.requireScope(BudgetScopeKind.TASK, taskId, taskId);
    this.registerScope(BudgetScopeKind.PROVIDER, taskId, providerId, limit);
  }

  reserve(request: BudgetReservationRequest): BudgetReservationResult {
    const result: BudgetReservationResult = new BudgetReservationResult();
    if (request.reservationId.length === 0 || request.taskId.length === 0 || !nonNegative(request.amount)) {
      result.code = 'INVALID_RESERVATION';
      return result;
    }
    if (this.findReservation(request.reservationId) >= 0) {
      result.code = 'DUPLICATE_RESERVATION';
      return result;
    }
    const indexes: number[] = this.resolveScopeIndexes(request);
    for (let i: number = 0; i < indexes.length; i++) {
      const scope: BudgetScopeSnapshot = this.scopes[indexes[i]];
      if (exceeds(scope.limit, scope.consumed, scope.reserved, request.amount)) {
        result.code = 'BUDGET_EXCEEDED';
        return result;
      }
    }
    for (let i: number = 0; i < indexes.length; i++) {
      add(this.scopes[indexes[i]].reserved, request.amount);
    }
    const reservation: BudgetReservationSnapshot = new BudgetReservationSnapshot();
    reservation.reservationId = request.reservationId;
    reservation.taskId = request.taskId;
    reservation.stepId = request.stepId;
    reservation.providerId = request.providerId;
    reservation.requested = copyAmount(request.amount);
    this.reservations.push(reservation);
    result.accepted = true;
    result.code = 'RESERVED';
    return result;
  }

  settle(reservationId: string, actual: BudgetAmount): BudgetSettlementResult {
    const result: BudgetSettlementResult = new BudgetSettlementResult();
    if (!nonNegative(actual)) {
      result.code = 'INVALID_ACTUAL';
      return result;
    }
    const reservation: BudgetReservationSnapshot = this.requireActiveReservation(reservationId);
    const indexes: number[] = this.resolveReservationScopeIndexes(reservation);
    for (let i: number = 0; i < indexes.length; i++) {
      const scope: BudgetScopeSnapshot = this.scopes[indexes[i]];
      subtract(scope.reserved, reservation.requested);
      add(scope.consumed, actual);
      if (exceeds(scope.limit, scope.consumed, new BudgetAmount(), new BudgetAmount())) {
        result.overLimit = true;
      }
    }
    reservation.actual = copyAmount(actual);
    reservation.state = BudgetReservationState.SETTLED;
    result.accepted = true;
    result.code = result.overLimit ? 'SETTLED_OVER_LIMIT' : 'SETTLED';
    return result;
  }

  release(reservationId: string): void {
    const reservation: BudgetReservationSnapshot = this.requireActiveReservation(reservationId);
    const indexes: number[] = this.resolveReservationScopeIndexes(reservation);
    for (let i: number = 0; i < indexes.length; i++) {
      subtract(this.scopes[indexes[i]].reserved, reservation.requested);
    }
    reservation.state = BudgetReservationState.RELEASED;
  }

  markUnknown(reservationId: string): void {
    const reservation: BudgetReservationSnapshot = this.requireActiveReservation(reservationId);
    reservation.state = BudgetReservationState.UNKNOWN;
  }

  resolveUnknown(reservationId: string, charged: boolean, actual: BudgetAmount = new BudgetAmount()): void {
    const index: number = this.findReservation(reservationId);
    if (index < 0 || this.reservations[index].state !== BudgetReservationState.UNKNOWN) {
      throw new BudgetLedgerError('reservation is not unknown: ' + reservationId);
    }
    this.reservations[index].state = BudgetReservationState.RESERVED;
    if (charged) {
      this.settle(reservationId, actual);
    } else {
      this.release(reservationId);
    }
  }

  getScope(kind: BudgetScopeKind, taskId: string, scopeId: string): BudgetScopeSnapshot {
    return this.copyScope(this.requireScope(kind, taskId, scopeId));
  }

  getReservation(reservationId: string): BudgetReservationSnapshot {
    const index: number = this.findReservation(reservationId);
    if (index < 0) {
      throw new BudgetLedgerError('unknown reservation: ' + reservationId);
    }
    const source: BudgetReservationSnapshot = this.reservations[index];
    const value: BudgetReservationSnapshot = new BudgetReservationSnapshot();
    value.reservationId = source.reservationId;
    value.taskId = source.taskId;
    value.stepId = source.stepId;
    value.providerId = source.providerId;
    value.requested = copyAmount(source.requested);
    value.actual = copyAmount(source.actual);
    value.state = source.state;
    return value;
  }

  /** Returns a defensive, task-scoped image suitable for durable persistence. */
  getTaskScopes(taskId: string): BudgetScopeSnapshot[] {
    const values: BudgetScopeSnapshot[] = [];
    for (let i: number = 0; i < this.scopes.length; i++) {
      if (this.scopes[i].taskId === taskId) values.push(this.copyScope(this.scopes[i]));
    }
    return values;
  }

  /** Returns a defensive, task-scoped image suitable for durable persistence. */
  getTaskReservations(taskId: string): BudgetReservationSnapshot[] {
    const values: BudgetReservationSnapshot[] = [];
    for (let i: number = 0; i < this.reservations.length; i++) {
      if (this.reservations[i].taskId === taskId) values.push(copyReservation(this.reservations[i]));
    }
    return values;
  }

  /**
   * Replaces the empty scopes registered for one reconstructed task with a
   * complete, internally consistent durable ledger image. The operation is
   * atomic: invalid or partial input leaves the current ledger unchanged.
   */
  hydrateTask(taskId: string, scopes: BudgetScopeSnapshot[],
    reservations: BudgetReservationSnapshot[]): boolean {
    if (taskId.trim().length === 0 || scopes.length === 0) return false;
    const currentIndexes: number[] = [];
    for (let i: number = 0; i < this.scopes.length; i++) {
      if (this.scopes[i].taskId === taskId) currentIndexes.push(i);
    }
    if (currentIndexes.length !== scopes.length) return false;
    for (let i: number = 0; i < this.reservations.length; i++) {
      if (this.reservations[i].taskId === taskId) return false;
    }

    const copies: BudgetScopeSnapshot[] = [];
    const consumed: BudgetAmount[] = [];
    const reserved: BudgetAmount[] = [];
    for (let i: number = 0; i < scopes.length; i++) {
      const source: BudgetScopeSnapshot = scopes[i];
      if (source.taskId !== taskId || source.scopeId.trim().length === 0 || !validBudget(source.limit) ||
        !nonNegative(source.consumed) || !nonNegative(source.reserved)) return false;
      for (let j: number = 0; j < i; j++) {
        if (scopes[j].kind === source.kind && scopes[j].scopeId === source.scopeId) return false;
      }
      let matched: boolean = false;
      for (let j: number = 0; j < currentIndexes.length; j++) {
        const current: BudgetScopeSnapshot = this.scopes[currentIndexes[j]];
        if (current.kind === source.kind && current.scopeId === source.scopeId &&
          sameBudget(current.limit, source.limit) && sameAmount(current.consumed, new BudgetAmount()) &&
          sameAmount(current.reserved, new BudgetAmount())) {
          matched = true;
          break;
        }
      }
      if (!matched) return false;
      copies.push(this.copyScope(source));
      consumed.push(new BudgetAmount());
      reserved.push(new BudgetAmount());
    }

    const reservationCopies: BudgetReservationSnapshot[] = [];
    for (let i: number = 0; i < reservations.length; i++) {
      const source: BudgetReservationSnapshot = reservations[i];
      if (source.taskId !== taskId || source.reservationId.trim().length === 0 ||
        !nonNegative(source.requested) || !nonNegative(source.actual) ||
        this.findReservation(source.reservationId) >= 0) return false;
      for (let j: number = 0; j < i; j++) {
        if (reservations[j].reservationId === source.reservationId) return false;
      }
      const indexes: number[] = [];
      for (let j: number = 0; j < copies.length; j++) {
        const scope: BudgetScopeSnapshot = copies[j];
        if ((scope.kind === BudgetScopeKind.TASK && scope.scopeId === taskId) ||
          (scope.kind === BudgetScopeKind.STEP && scope.scopeId === source.stepId && source.stepId.length > 0) ||
          (scope.kind === BudgetScopeKind.PROVIDER && scope.scopeId === source.providerId &&
          source.providerId.length > 0)) indexes.push(j);
      }
      let hasTaskScope: boolean = false;
      for (let j: number = 0; j < indexes.length; j++) {
        if (copies[indexes[j]].kind === BudgetScopeKind.TASK) hasTaskScope = true;
      }
      if (!hasTaskScope || (source.stepId.length > 0 && !this.hasScopeKind(copies, indexes,
        BudgetScopeKind.STEP)) || (source.providerId.length > 0 && !this.hasScopeKind(copies, indexes,
        BudgetScopeKind.PROVIDER))) return false;
      if (source.state === BudgetReservationState.SETTLED) {
        for (let j: number = 0; j < indexes.length; j++) add(consumed[indexes[j]], source.actual);
      } else if (source.state === BudgetReservationState.RESERVED ||
        source.state === BudgetReservationState.UNKNOWN) {
        if (!sameAmount(source.actual, new BudgetAmount())) return false;
        for (let j: number = 0; j < indexes.length; j++) add(reserved[indexes[j]], source.requested);
      } else if (source.state === BudgetReservationState.RELEASED) {
        if (!sameAmount(source.actual, new BudgetAmount())) return false;
      } else {
        return false;
      }
      reservationCopies.push(copyReservation(source));
    }
    for (let i: number = 0; i < copies.length; i++) {
      if (!sameAmount(copies[i].consumed, consumed[i]) || !sameAmount(copies[i].reserved, reserved[i])) {
        return false;
      }
    }

    const retained: BudgetScopeSnapshot[] = [];
    for (let i: number = 0; i < this.scopes.length; i++) {
      if (this.scopes[i].taskId !== taskId) retained.push(this.scopes[i]);
    }
    for (let i: number = 0; i < copies.length; i++) retained.push(copies[i]);
    this.scopes = retained;
    for (let i: number = 0; i < reservationCopies.length; i++) this.reservations.push(reservationCopies[i]);
    return true;
  }

  private registerScope(kind: BudgetScopeKind, taskId: string, scopeId: string, limit: ExecutionBudget): void {
    if (taskId.length === 0 || scopeId.length === 0 || !validBudget(limit) ||
      this.findScope(kind, taskId, scopeId) >= 0) {
      throw new BudgetLedgerError('invalid or duplicate budget scope');
    }
    const scope: BudgetScopeSnapshot = new BudgetScopeSnapshot();
    scope.kind = kind;
    scope.taskId = taskId;
    scope.scopeId = scopeId;
    scope.limit = copyBudget(limit);
    this.scopes.push(scope);
  }

  private resolveScopeIndexes(request: BudgetReservationRequest): number[] {
    const indexes: number[] = [this.indexOfScope(BudgetScopeKind.TASK, request.taskId, request.taskId)];
    if (request.stepId.length > 0) {
      indexes.push(this.indexOfScope(BudgetScopeKind.STEP, request.taskId, request.stepId));
    }
    if (request.providerId.length > 0) {
      indexes.push(this.indexOfScope(BudgetScopeKind.PROVIDER, request.taskId, request.providerId));
    }
    return indexes;
  }

  private resolveReservationScopeIndexes(reservation: BudgetReservationSnapshot): number[] {
    const request: BudgetReservationRequest = new BudgetReservationRequest();
    request.taskId = reservation.taskId;
    request.stepId = reservation.stepId;
    request.providerId = reservation.providerId;
    return this.resolveScopeIndexes(request);
  }

  private requireActiveReservation(reservationId: string): BudgetReservationSnapshot {
    const index: number = this.findReservation(reservationId);
    if (index < 0 || this.reservations[index].state !== BudgetReservationState.RESERVED) {
      throw new BudgetLedgerError('reservation is not active: ' + reservationId);
    }
    return this.reservations[index];
  }

  private findReservation(reservationId: string): number {
    for (let i: number = 0; i < this.reservations.length; i++) {
      if (this.reservations[i].reservationId === reservationId) {
        return i;
      }
    }
    return -1;
  }

  private findScope(kind: BudgetScopeKind, taskId: string, scopeId: string): number {
    for (let i: number = 0; i < this.scopes.length; i++) {
      const scope: BudgetScopeSnapshot = this.scopes[i];
      if (scope.kind === kind && scope.taskId === taskId && scope.scopeId === scopeId) {
        return i;
      }
    }
    return -1;
  }

  private indexOfScope(kind: BudgetScopeKind, taskId: string, scopeId: string): number {
    const index: number = this.findScope(kind, taskId, scopeId);
    if (index < 0) {
      throw new BudgetLedgerError('missing budget scope: ' + taskId + '/' + scopeId);
    }
    return index;
  }

  private requireScope(kind: BudgetScopeKind, taskId: string, scopeId: string): BudgetScopeSnapshot {
    return this.scopes[this.indexOfScope(kind, taskId, scopeId)];
  }

  private copyScope(source: BudgetScopeSnapshot): BudgetScopeSnapshot {
    const value: BudgetScopeSnapshot = new BudgetScopeSnapshot();
    value.kind = source.kind;
    value.taskId = source.taskId;
    value.scopeId = source.scopeId;
    value.limit = copyBudget(source.limit);
    value.consumed = copyAmount(source.consumed);
    value.reserved = copyAmount(source.reserved);
    return value;
  }

  private hasScopeKind(scopes: BudgetScopeSnapshot[], indexes: number[], kind: BudgetScopeKind): boolean {
    for (let i: number = 0; i < indexes.length; i++) {
      if (scopes[indexes[i]].kind === kind) return true;
    }
    return false;
  }
}
