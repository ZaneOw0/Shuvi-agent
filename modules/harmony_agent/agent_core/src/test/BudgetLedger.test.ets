import { describe, expect, it } from '@ohos/hypium';
import { ExecutionBudget } from '@harmony_agent/agent-contracts';
import {
  BudgetAmount,
  BudgetLedger,
  BudgetReservationRequest,
  BudgetReservationSnapshot,
  BudgetReservationState,
  BudgetScopeKind,
  BudgetScopeSnapshot
} from '../../Index';

function limit(toolCalls: number, cost: number = 1000): ExecutionBudget {
  const value: ExecutionBudget = new ExecutionBudget();
  value.maxWallTimeMs = 10000;
  value.maxInputTokens = 10000;
  value.maxOutputTokens = 10000;
  value.maxMonetaryCostMicros = cost;
  value.maxToolCalls = toolCalls;
  value.maxAgentActivations = 10;
  value.maxRetries = 10;
  value.maxReplans = 10;
  return value;
}

function reservation(id: string, calls: number, cost: number = 0): BudgetReservationRequest {
  const value: BudgetReservationRequest = new BudgetReservationRequest();
  value.reservationId = id;
  value.taskId = 'task-1';
  value.stepId = 'step-1';
  value.providerId = 'provider-1';
  value.amount.toolCalls = calls;
  value.amount.monetaryCostMicros = cost;
  return value;
}

function ledger(taskCalls: number = 2): BudgetLedger {
  const value: BudgetLedger = new BudgetLedger();
  value.registerTask('task-1', limit(taskCalls));
  value.registerStep('task-1', 'step-1', limit(taskCalls));
  value.registerProvider('task-1', 'provider-1', limit(taskCalls));
  return value;
}

export default function budgetLedgerTest(): void {
  describe('BudgetLedger', () => {
    it('preventsConcurrentReservationsFromOversubscribingTask', 0, () => {
      const value: BudgetLedger = ledger(1);
      expect(value.reserve(reservation('r1', 1)).accepted).assertTrue();
      expect(value.reserve(reservation('r2', 1)).code).assertEqual('BUDGET_EXCEEDED');
      expect(value.getScope(BudgetScopeKind.TASK, 'task-1', 'task-1').reserved.toolCalls).assertEqual(1);
    });

    it('enforcesStepAndProviderScopesAtomically', 0, () => {
      const value: BudgetLedger = new BudgetLedger();
      value.registerTask('task-1', limit(5));
      value.registerStep('task-1', 'step-1', limit(1));
      value.registerProvider('task-1', 'provider-1', limit(5));
      expect(value.reserve(reservation('r1', 2)).accepted).assertFalse();
      expect(value.getScope(BudgetScopeKind.TASK, 'task-1', 'task-1').reserved.toolCalls).assertEqual(0);
      expect(value.getScope(BudgetScopeKind.PROVIDER, 'task-1', 'provider-1').reserved.toolCalls)
        .assertEqual(0);
    });

    it('holdsUnknownReservationUntilReconciled', 0, () => {
      const value: BudgetLedger = ledger(1);
      value.reserve(reservation('r1', 1));
      value.markUnknown('r1');
      expect(value.getReservation('r1').state).assertEqual(BudgetReservationState.UNKNOWN);
      expect(value.reserve(reservation('r2', 1)).accepted).assertFalse();
      value.resolveUnknown('r1', false);
      expect(value.reserve(reservation('r2', 1)).accepted).assertTrue();
    });

    it('recordsSettlementOverageAndBlocksFutureReservations', 0, () => {
      const value: BudgetLedger = ledger(2);
      value.reserve(reservation('r1', 1));
      const actual: BudgetAmount = new BudgetAmount();
      actual.toolCalls = 3;
      expect(value.settle('r1', actual).overLimit).assertTrue();
      expect(value.getScope(BudgetScopeKind.TASK, 'task-1', 'task-1').consumed.toolCalls).assertEqual(3);
      expect(value.reserve(reservation('r2', 0)).accepted).assertFalse();
    });

    it('rejectsDuplicateReservationIdentifiers', 0, () => {
      const value: BudgetLedger = ledger();
      expect(value.reserve(reservation('r1', 1)).accepted).assertTrue();
      expect(value.reserve(reservation('r1', 0)).code).assertEqual('DUPLICATE_RESERVATION');
    });

    it('copiesLimitsAndRejectsFractionalAmounts', 0, () => {
      const source: ExecutionBudget = limit(1);
      const value: BudgetLedger = new BudgetLedger();
      value.registerTask('task-1', source);
      source.maxToolCalls = 99;
      expect(value.getScope(BudgetScopeKind.TASK, 'task-1', 'task-1').limit.maxToolCalls).assertEqual(1);

      value.registerStep('task-1', 'step-1', limit(1));
      value.registerProvider('task-1', 'provider-1', limit(1));
      const fractional: BudgetReservationRequest = reservation('fractional', 0.5);
      expect(value.reserve(fractional).code).assertEqual('INVALID_RESERVATION');
    });

    it('hydratesCompleteTaskLedgerAtomically', 0, () => {
      const source: BudgetLedger = ledger(2);
      source.reserve(reservation('r1', 1, 7));
      source.markUnknown('r1');
      const scopes: BudgetScopeSnapshot[] = [
        source.getScope(BudgetScopeKind.TASK, 'task-1', 'task-1'),
        source.getScope(BudgetScopeKind.STEP, 'task-1', 'step-1'),
        source.getScope(BudgetScopeKind.PROVIDER, 'task-1', 'provider-1')
      ];
      const reservations: BudgetReservationSnapshot[] = [source.getReservation('r1')];
      const restored: BudgetLedger = ledger(2);
      expect(restored.hydrateTask('task-1', scopes, reservations)).assertTrue();
      expect(restored.getReservation('r1').state).assertEqual(BudgetReservationState.UNKNOWN);
      expect(restored.reserve(reservation('r2', 2)).code).assertEqual('BUDGET_EXCEEDED');

      const collision: BudgetLedger = new BudgetLedger();
      collision.registerTask('task-2', limit(2));
      collision.registerStep('task-2', 'step-2', limit(2));
      collision.registerProvider('task-2', 'provider-2', limit(2));
      const other: BudgetReservationRequest = new BudgetReservationRequest();
      other.reservationId = 'r1';
      other.taskId = 'task-2';
      other.stepId = 'step-2';
      other.providerId = 'provider-2';
      other.amount.toolCalls = 1;
      expect(collision.reserve(other).accepted).assertTrue();
      collision.registerTask('task-1', limit(2));
      collision.registerStep('task-1', 'step-1', limit(2));
      collision.registerProvider('task-1', 'provider-1', limit(2));
      expect(collision.hydrateTask('task-1', scopes, reservations)).assertFalse();

      const corrupt: BudgetLedger = ledger(2);
      scopes[0].reserved.toolCalls = 0;
      expect(corrupt.hydrateTask('task-1', scopes, reservations)).assertFalse();
      expect(corrupt.getScope(BudgetScopeKind.TASK, 'task-1', 'task-1').reserved.toolCalls).assertEqual(0);
      expect(corrupt.reserve(reservation('r2', 2)).accepted).assertTrue();
    });

    it('returnsDefensiveTaskScopedAuthorityImages', 0, () => {
      const value: BudgetLedger = ledger(2);
      expect(value.reserve(reservation('r1', 1, 7)).accepted).assertTrue();
      value.registerTask('task-2', limit(2));
      value.registerStep('task-2', 'step-2', limit(2));
      value.registerProvider('task-2', 'provider-2', limit(2));
      const other: BudgetReservationRequest = new BudgetReservationRequest();
      other.reservationId = 'r2';
      other.taskId = 'task-2';
      other.stepId = 'step-2';
      other.providerId = 'provider-2';
      other.amount.toolCalls = 1;
      expect(value.reserve(other).accepted).assertTrue();

      const scopes: BudgetScopeSnapshot[] = value.getTaskScopes('task-1');
      const reservations: BudgetReservationSnapshot[] = value.getTaskReservations('task-1');
      expect(scopes.length).assertEqual(3);
      expect(reservations.length).assertEqual(1);
      expect(reservations[0].reservationId).assertEqual('r1');
      scopes[0].reserved.toolCalls = 99;
      reservations[0].requested.toolCalls = 99;
      expect(value.getScope(BudgetScopeKind.TASK, 'task-1', 'task-1').reserved.toolCalls).assertEqual(1);
      expect(value.getReservation('r1').requested.toolCalls).assertEqual(1);
      expect(value.getTaskReservations('task-2')[0].reservationId).assertEqual('r2');
    });
  });
}
